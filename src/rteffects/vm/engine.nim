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
    parentFrameId*: int      ## -1 = root frame; >= 0 = spawned for bvProgram
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

proc newFrame*(engine: Engine, program: EffProgram, entry: ContId,
               parentFrameId: int = -1): int =
  let id = engine.frames.len
  engine.frames.add(Frame(
    id: FrameId(id),
    pc: entry,
    program: program,
    state: fsReady,
    hasResult: false,
    failed: false,
    parentFrameId: parentFrameId,
  ))
  # Inherit handlers from parent frame
  if parentFrameId >= 0 and parentFrameId < engine.frames.len:
    engine.frames[id].handlers = engine.frames[parentFrameId].handlers
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

proc resolveBvPrograms(engine: Engine) =
  ## Resolve bvProgram results in done frames by spawning child frames.
  ## Child inherits parent's handlers. Parent waits in fsSuspended.
  for i in 0 ..< engine.frames.len:
    if engine.frames[i].state != fsDone: continue
    if not engine.frames[i].hasResult: continue
    if engine.frames[i].result.kind != bvProgram: continue
    if engine.frames[i].failed: continue
    let innerProg = engine.frames[i].result.innerProgram
    # Spawn child — this may grow engine.frames
    let childId = engine.newFrame(innerProg, innerProg.entry, i)
    # Modify parent after spawn (safe: no var-ref aliasing)
    engine.frames[i].hasResult = false
    engine.frames[i].transition(fsSuspended)
    return  # Process one at a time to avoid iteration invalidation

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
        # Resolve nested program via child frame (inherits handlers)
        let innerProg = frame.result.innerProgram
        let innerEntry = innerProg.entry.int
        # Fast-resolve trivial inner programs inline (no frame needed)
        if innerEntry >= 0 and innerEntry < innerProg.ops.len:
          let innerOp = innerProg.ops[innerEntry]
          case innerOp.kind
          of opPure:
            frame.result = innerOp.pureValue
            frame.transition(fsReady)
            engine.enqueue(frameId)
          of opFail:
            frame.error = innerOp.failError
            frame.failed = true
            frame.hasResult = false
            completeOrReturn(engine, frame, frameId)
          else:
            # Complex inner program — mark as done with bvProgram result.
            # spawnChildForBvProgram (called after step) will spawn child frame.
            completeOrReturn(engine, frame, frameId)
        else:
          frame.hasResult = false
          completeOrReturn(engine, frame, frameId)
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

proc propagateChildResults(engine: Engine) =
  ## Check for done child frames and propagate results to suspended parents.
  ## Parent goes directly to fsDone (not re-enqueued for stepping).
  for i in 0 ..< engine.frames.len:
    let child = engine.frames[i]
    if child.state != fsDone: continue
    if child.parentFrameId < 0: continue
    let pid = child.parentFrameId
    if pid >= engine.frames.len: continue
    if engine.frames[pid].state != fsSuspended: continue
    # Propagate child result directly to parent as final result
    if child.failed:
      engine.frames[pid].error = child.error
      engine.frames[pid].failed = true
    elif child.hasResult:
      engine.frames[pid].result = child.result
      engine.frames[pid].hasResult = true
    # Parent is done (not re-enqueued — child resolved its bvProgram)
    engine.frames[pid].transition(fsDone)
    # Mark child as consumed
    engine.frames[i].parentFrameId = -1
    # Check if parent's result is another bvProgram (chain of andThen)
    # This will be picked up by resolveBvPrograms in the next iteration

proc hasWorkToDo(engine: Engine): bool =
  ## Check if there's pending work (queued frames, bvProgram to resolve, or child→parent to propagate).
  if engine.queueLen > 0: return true
  for f in engine.frames:
    if f.state == fsDone and f.hasResult and f.result.kind == bvProgram and not f.failed:
      return true  # bvProgram needs resolution
    if f.state == fsDone and f.parentFrameId >= 0:
      return true  # child result needs propagation
  false

proc runLoop*(engine: Engine) =
  ## Execute until no more work or budget exhausted.
  ## Automatically resolves bvProgram chains and propagates child results.
  var steps = 0
  while steps < engine.budget and engine.hasWorkToDo():
    if engine.queueLen > 0:
      if not engine.step():
        discard
      steps += 1
    # Resolve bvProgram results via child frames
    engine.resolveBvPrograms()
    # Propagate child→parent results
    engine.propagateChildResults()

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
  ## Uses Engine with runLoop for automatic bvProgram resolution.
  # Fast path for trivial programs
  let (handled, fastResult) = tryFastInterpret[T](eff)
  if handled:
    return fastResult

  # Full Engine path with runLoop (resolves bvProgram chains automatically)
  let engine = newEngine(budget)
  let frameId = engine.newFrame(eff.program, eff.program.entry)
  engine.runLoop()

  if frameId < engine.frames.len:
    let frame = engine.frames[frameId]
    if frame.failed:
      return evalFalse[T](frame.error)
    elif frame.hasResult:
      return evalTrue(eff.unboxer(frame.result))
  evalNeither[T]()

proc run*[T](eff: Eff[T], budget = 10000): Result[T] {.raises: [].} =
  ## The runner ACL: interpret Eff[T] and collapse to Result[T].
  try:
    let ev = interpret[T](eff, budget)
    toResult(ev)
  except Exception as e:
    err[T](RtError(kind: ExceptionRaised, msg: e.msg))

# ---------------------------------------------------------------------------
# Async resume API: for handlers that defer resume to a later callback
# ---------------------------------------------------------------------------

proc resumeFrame*(engine: Engine, frameId: int, value: BoxedValue) =
  ## Resume a suspended frame with a value (called from async I/O callback).
  ## Sets result and returns control to the continuation stack.
  if frameId >= engine.frames.len: return
  if engine.frames[frameId].state != fsSuspended: return
  engine.frames[frameId].result = value
  engine.frames[frameId].hasResult = true
  completeOrReturn(engine, engine.frames[frameId], frameId)

proc abortFrame*(engine: Engine, frameId: int, error: RtError) =
  ## Abort a suspended frame with an error (called from async I/O callback).
  if frameId >= engine.frames.len: return
  if engine.frames[frameId].state != fsSuspended: return
  engine.frames[frameId].error = error
  engine.frames[frameId].failed = true
  completeOrReturn(engine, engine.frames[frameId], frameId)

proc hasSuspended*(engine: Engine): bool =
  ## Check if any frames are suspended (waiting for async I/O).
  for f in engine.frames:
    if f.state == fsSuspended: return true
  false

proc allDone*(engine: Engine): bool =
  ## Check if all frames are done (no work remaining).
  engine.queueLen == 0 and not engine.hasSuspended()
