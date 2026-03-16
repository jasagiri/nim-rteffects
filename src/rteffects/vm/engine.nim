## VM Engine: interprets EffProgram via a stepping loop.
##
## The engine walks the continuation table, executing operations
## and producing Eval[T] results. This is the bridge between
## the Effect Algebra (Eff[T]) and the Evaluation Semantics (Eval[T]).
##
## Key mechanism: Frame.contStack tracks return addresses. When a compound
## op (opMap, opBind, opHandle) dispatches to a sub-expression, it pushes
## its own ContId onto contStack. Terminal ops (opPure, opFail) and
## completed compound ops pop contStack to return to the parent.
##
## Frame state is a lightweight enum (fsReady, fsRunning, fsSuspended, fsDone).
## Compile with -d:rteffectsDebug for transition history tracking.

import std/deques
import ../core
import ../semantics
import ./types

type
  FrameId* = distinct int

  FrameState* = enum
    fsReady, fsRunning, fsSuspended, fsDone

  HandlerEntry* = object
    tag*: EffectTag
    impl*: proc(payload: BoxedValue,
                resume: proc(v: BoxedValue) {.gcsafe.},
                abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}

when defined(rteffectsDebug):
  type TransitionRecord* = object
    fromState*, toState*: FrameState

type
  Frame* = object
    id*: FrameId
    pc*: ContId
    program*: EffProgram
    state*: FrameState
    result*: BoxedValue
    hasResult*: bool
    failed*: bool
    error*: RtError
    handlers*: seq[HandlerEntry]
    contStack*: seq[ContId]  ## Return address stack
    when defined(rteffectsDebug):
      transitions*: seq[TransitionRecord]

  Engine* = ref object
    frames*: seq[Frame]
    readyQ*: seq[int]       ## Simple queue (append + index scan)
    readyHead*: int         ## Index of next item to dequeue
    budget*: int

proc `==`*(a, b: FrameId): bool {.borrow.}

proc transition(frame: var Frame, to: FrameState) {.inline.} =
  when defined(rteffectsDebug):
    frame.transitions.add(TransitionRecord(
      fromState: frame.state, toState: to))
  frame.state = to

proc newEngine*(budget = 1000): Engine =
  Engine(
    frames: @[],
    readyQ: @[],
    readyHead: 0,
    budget: budget,
  )

proc nextId*(engine: Engine): int {.inline.} =
  engine.frames.len

proc newFrame*(engine: Engine, program: EffProgram, entry: ContId): int =
  let id = engine.frames.len
  engine.frames.add(Frame(
    id: FrameId(id),
    pc: entry,
    program: program,
    state: fsReady,
    hasResult: false,
    failed: false,
  ))
  engine.readyQ.add(id)
  id

proc enqueue(engine: Engine, frameId: int) {.inline.} =
  engine.readyQ.add(frameId)

proc dequeue(engine: Engine): int {.inline.} =
  result = engine.readyQ[engine.readyHead]
  engine.readyHead += 1

proc queueLen(engine: Engine): int {.inline.} =
  engine.readyQ.len - engine.readyHead

proc findHandler(frame: Frame, tag: EffectTag): int =
  ## Find handler index for tag (last matching = innermost).
  for i in countdown(frame.handlers.high, 0):
    if frame.handlers[i].tag == tag:
      return i
  return -1

proc completeOrReturn(engine: Engine, frame: var Frame, frameId: int) =
  ## After producing a result (or error), return to parent op or mark done.
  if frame.contStack.len > 0:
    frame.pc = frame.contStack.pop()
    frame.transition(fsReady)
    engine.enqueue(frameId)
  else:
    frame.transition(fsDone)

# Forward declaration for mutual recursion
proc interpretStep(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError]

proc step(engine: Engine): bool =
  ## Execute one frame step. Returns true if work was done.
  if engine.queueLen == 0:
    return false

  let frameId = engine.dequeue()
  if frameId >= engine.frames.len:
    return true

  # Work directly on frame in place (avoid ~200 byte copy/writeback per step)
  template frame: untyped = engine.frames[frameId]
  frame.transition(fsRunning)

  let op = frame.program.ops[frame.pc.int]

  case op.kind
  of opPure:
    frame.result = op.pureValue
    frame.hasResult = true
    completeOrReturn(engine, frame, frameId)

  of opFail:
    frame.error = op.failError
    frame.failed = true
    completeOrReturn(engine, frame, frameId)

  of opBind:
    if frame.hasResult:
      # Source completed. Check for bvProgram (from andThen).
      if frame.result.kind == bvProgram:
        # Fast-resolve trivial inner programs without creating a new frame
        let innerProg = frame.result.innerProgram
        let innerEntry = innerProg.entry.int
        if innerEntry >= 0 and innerEntry < innerProg.ops.len:
          let innerOp = innerProg.ops[innerEntry]
          case innerOp.kind
          of opPure:
            frame.result = innerOp.pureValue
            # Re-visit this opBind with the resolved value
            frame.transition(fsReady)
            engine.enqueue(frameId)
          of opFail:
            frame.error = innerOp.failError
            frame.failed = true
            frame.hasResult = false
            completeOrReturn(engine, frame, frameId)
          else:
            # Complex inner program — full interpretation
            let inner = engine.interpretStep(innerProg, innerProg.entry)
            # Note: interpretStep may grow engine.frames, but template
            # re-evaluates engine.frames[frameId] each access, so this is safe.
            if inner.failed:
              frame.error = inner.error
              frame.failed = true
              frame.hasResult = false
              completeOrReturn(engine, frame, frameId)
            elif inner.hasResult:
              frame.result = inner.result
              frame.transition(fsReady)
              engine.enqueue(frameId)
            else:
              frame.transition(fsSuspended)
        else:
          frame.transition(fsSuspended)
      else:
        # Plain value — move to next phase (tail position, no push)
        frame.pc = op.bindNext
        frame.transition(fsReady)
        engine.enqueue(frameId)
    elif frame.failed:
      # Source failed, short-circuit
      completeOrReturn(engine, frame, frameId)
    else:
      # First visit: evaluate source, remember to come back
      frame.contStack.add(frame.pc)
      frame.pc = op.bindSource
      frame.transition(fsReady)
      engine.enqueue(frameId)

  of opMap:
    if frame.hasResult:
      # Value available, apply transform
      frame.result = op.mapFn(frame.result)
      completeOrReturn(engine, frame, frameId)
    elif frame.failed:
      completeOrReturn(engine, frame, frameId)
    else:
      # Evaluate target first, remember to come back
      frame.contStack.add(frame.pc)
      frame.pc = op.mapTarget
      frame.transition(fsReady)
      engine.enqueue(frameId)

  of opPerform:
    let idx = findHandler(frame, op.performTag)
    if idx < 0:
      # No handler found
      frame.error = RtError(kind: ForeignError,
        msg: "unhandled effect: " & $op.performTag)
      frame.failed = true
      completeOrReturn(engine, frame, frameId)
    else:
      # Call handler with resume/abort callbacks
      var resumed = false
      var resumeValue: BoxedValue
      var aborted = false
      var abortError: RtError

      frame.handlers[idx].impl(
        op.performPayload,
        proc(v: BoxedValue) {.gcsafe.} =
          resumed = true
          resumeValue = v,
        proc(e: RtError) {.gcsafe.} =
          aborted = true
          abortError = e,
      )

      if resumed:
        frame.result = resumeValue
        frame.hasResult = true
        completeOrReturn(engine, frame, frameId)
      elif aborted:
        frame.error = abortError
        frame.failed = true
        completeOrReturn(engine, frame, frameId)
      else:
        # Suspended (neither resume nor abort called)
        frame.transition(fsSuspended)

  of opHandle:
    if frame.hasResult or frame.failed:
      # Body completed, pass through
      completeOrReturn(engine, frame, frameId)
    else:
      # Install handler and evaluate body
      frame.handlers.add(HandlerEntry(
        tag: op.handleTag,
        impl: op.handleImpl,
      ))
      frame.contStack.add(frame.pc)
      frame.pc = op.handleBody
      frame.transition(fsReady)
      engine.enqueue(frameId)

  return true

proc runLoop*(engine: Engine) =
  ## Execute until no more work or budget exhausted.
  var steps = 0
  while engine.queueLen > 0 and steps < engine.budget:
    if not engine.step():
      break
    steps += 1

proc interpretProgram*(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError] =
  let frameId = engine.newFrame(program, entry)
  engine.runLoop()

  if frameId < engine.frames.len:
    let frame = engine.frames[frameId]
    result.hasResult = frame.hasResult
    result.result = frame.result
    result.failed = frame.failed
    result.error = frame.error

proc interpretStep(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError] =
  ## Interpret a program, resolving any bvProgram results recursively.
  ## Fast-resolve trivial programs (opPure/opFail) without frame creation.
  var prog = program
  var ent = entry
  while true:
    let entIdx = ent.int
    if entIdx >= 0 and entIdx < prog.ops.len:
      let op = prog.ops[entIdx]
      case op.kind
      of opPure:
        result.hasResult = true
        result.result = op.pureValue
        return
      of opFail:
        result.failed = true
        result.error = op.failError
        return
      else:
        discard

    let raw = engine.interpretProgram(prog, ent)
    if raw.hasResult and raw.result.kind == bvProgram:
      prog = raw.result.innerProgram
      ent = prog.entry
      continue
    return raw

import ../algebra

# ---------------------------------------------------------------------------
# Fast path: interpret trivial programs without Engine overhead
# ---------------------------------------------------------------------------

proc tryFastInterpret[T](eff: Eff[T]): (bool, Eval[T]) =
  ## Try to evaluate simple programs (opPure, opFail) without Engine.
  ## Returns (handled, result). If handled=false, fall back to full Engine.
  let entry = eff.program.entry.int
  if entry < 0 or entry >= eff.program.ops.len:
    return (true, evalNeither[T]())

  let op = eff.program.ops[entry]
  case op.kind
  of opPure:
    return (true, evalTrue(eff.unboxer(op.pureValue)))
  of opFail:
    return (true, evalFalse[T](op.failError))
  else:
    return (false, evalNeither[T]())

proc interpret*[T](eff: Eff[T], budget = 10000): Eval[T] =
  ## Interpret an Eff[T] and produce an Eval[T].
  # Fast path for trivial programs
  let (handled, fastResult) = tryFastInterpret[T](eff)
  if handled:
    return fastResult

  # Full Engine path
  let engine = newEngine(budget)
  let res = engine.interpretStep(eff.program, eff.program.entry)

  if res.failed:
    evalFalse[T](res.error)
  elif res.hasResult:
    evalTrue(eff.unboxer(res.result))
  else:
    evalNeither[T]()

proc run*[T](eff: Eff[T], budget = 10000): Result[T] {.raises: [].} =
  ## The runner ACL: interpret Eff[T] and collapse to Result[T].
  try:
    let ev = interpret[T](eff, budget)
    toResult(ev)
  except Exception as e:
    err[T](RtError(kind: ExceptionRaised, msg: e.msg))
