## VM Engine: interprets EffProgram as a state machine.
##
## The engine walks the continuation table, executing operations
## and producing Eval[T] results. This is the bridge between
## the Effect Algebra (Eff[T]) and the Evaluation Semantics (Eval[T]).
##
## Key mechanism: Frame.contStack tracks return addresses. When a compound
## op (opMap, opBind, opHandle) dispatches to a sub-expression, it pushes
## its own ContId onto contStack. Terminal ops (opPure, opFail) and
## completed compound ops pop contStack to return to the parent.

import std/[tables, deques]
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

  Engine* = ref object
    frames*: Table[int, Frame]
    readyQ*: Deque[int]
    nextId*: int
    budget*: int

proc `==`*(a, b: FrameId): bool {.borrow.}

proc newEngine*(budget = 1000): Engine =
  Engine(
    frames: initTable[int, Frame](),
    readyQ: initDeque[int](),
    nextId: 0,
    budget: budget,
  )

proc newFrame(engine: Engine, program: EffProgram, entry: ContId): int =
  let id = engine.nextId
  engine.nextId += 1
  engine.frames[id] = Frame(
    id: FrameId(id),
    pc: entry,
    program: program,
    state: fsReady,
    hasResult: false,
    failed: false,
  )
  engine.readyQ.addLast(id)
  id

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
    frame.state = fsReady
    engine.readyQ.addLast(frameId)
  else:
    frame.state = fsDone

# Forward declaration for mutual recursion
proc interpretStep(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError]

proc step(engine: Engine): bool =
  ## Execute one frame step. Returns true if work was done.
  if engine.readyQ.len == 0:
    return false

  let frameId = engine.readyQ.popFirst()
  if frameId notin engine.frames:
    return true

  var frame = engine.frames[frameId]
  frame.state = fsRunning

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
        # Resolve inner program before passing to bindNext
        let inner = engine.interpretStep(
          frame.result.innerProgram, frame.result.innerProgram.entry)
        if inner.failed:
          frame.error = inner.error
          frame.failed = true
          frame.hasResult = false
          completeOrReturn(engine, frame, frameId)
        elif inner.hasResult:
          frame.result = inner.result
          # Re-visit this opBind with the resolved value
          frame.state = fsReady
          engine.readyQ.addLast(frameId)
        else:
          frame.state = fsSuspended
      else:
        # Plain value — move to next phase (tail position, no push)
        frame.pc = op.bindNext
        frame.state = fsReady
        engine.readyQ.addLast(frameId)
    elif frame.failed:
      # Source failed, short-circuit
      completeOrReturn(engine, frame, frameId)
    else:
      # First visit: evaluate source, remember to come back
      frame.contStack.add(frame.pc)
      frame.pc = op.bindSource
      frame.state = fsReady
      engine.readyQ.addLast(frameId)

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
      frame.state = fsReady
      engine.readyQ.addLast(frameId)

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
        frame.state = fsSuspended

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
      frame.state = fsReady
      engine.readyQ.addLast(frameId)

  engine.frames[frameId] = frame
  return true

proc runLoop(engine: Engine) =
  ## Execute until no more work or budget exhausted.
  var steps = 0
  while engine.readyQ.len > 0 and steps < engine.budget:
    if not engine.step():
      break
    steps += 1

proc interpretProgram(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError] =
  let frameId = engine.newFrame(program, entry)
  engine.runLoop()

  if frameId in engine.frames:
    let frame = engine.frames[frameId]
    result.hasResult = frame.hasResult
    result.result = frame.result
    result.failed = frame.failed
    result.error = frame.error

proc interpretStep(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError] =
  ## Interpret a program, resolving any bvProgram results recursively.
  let raw = engine.interpretProgram(program, entry)

  if raw.hasResult and raw.result.kind == bvProgram:
    return engine.interpretStep(
      raw.result.innerProgram, raw.result.innerProgram.entry)

  return raw

import ../algebra

proc interpret*[T](eff: Eff[T], budget = 10000): Eval[T] =
  ## Interpret an Eff[T] and produce an Eval[T].
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
