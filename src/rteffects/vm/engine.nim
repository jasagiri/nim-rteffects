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

import std/[deques, options]
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

  FrameRef* = ref Frame
    ## Heap-allocated frame. seq[FrameRef] realloc does not invalidate
    ## frame data addresses — only the pointer array moves, not the frames.

  Engine* = ref object
    frames*: seq[FrameRef]
    readyQ*: Deque[int]
    pendingBvResolve*: Deque[int]   ## Frames in fsDone with bvProgram result
    pendingPropagation*: Deque[int] ## Child frames in fsDone needing propagation to parent
    budget*: int

proc `==`*(a, b: FrameId): bool {.borrow.}

proc transition(frame: Frame | FrameRef, to: FrameState) {.inline.} =
  when defined(rteffectsDebug):
    frame.transitions.add(TransitionRecord(
      fromState: frame.state, toState: to))
  frame.state = to

proc newEngine*(budget = 1000): Engine =
  Engine(
    frames: @[],
    readyQ: initDeque[int](),
    pendingBvResolve: initDeque[int](),
    pendingPropagation: initDeque[int](),
    budget: budget,
  )

proc nextId*(engine: Engine): int {.inline.} =
  engine.frames.len

proc newFrame*(engine: Engine, program: EffProgram, entry: ContId,
               parentFrameId: int = -1): int =
  let id = engine.frames.len
  let fr = FrameRef(
    id: FrameId(id),
    pc: entry,
    program: program,
    state: fsReady,
    hasResult: false,
    failed: false,
    parentFrameId: parentFrameId,
  )
  engine.frames.add(fr)
  # Inherit handlers from parent frame
  if parentFrameId >= 0 and parentFrameId < engine.frames.len:
    fr.handlers = engine.frames[parentFrameId].handlers
  engine.readyQ.addLast(id)
  id

proc enqueue(engine: Engine, frameId: int) {.inline.} =
  engine.readyQ.addLast(frameId)

proc dequeue(engine: Engine): int {.inline.} =
  result = engine.readyQ.popFirst()

proc queueLen(engine: Engine): int {.inline.} =
  engine.readyQ.len

proc findHandler(frame: Frame | FrameRef, tag: EffectTag): int =
  ## Find handler index for tag (last matching = innermost).
  for i in countdown(frame.handlers.high, 0):
    if frame.handlers[i].tag == tag:
      return i
  return -1

proc completeOrReturn(engine: Engine, frame: FrameRef, frameId: int) =
  ## After producing a result (or error), return to parent op or mark done.
  if frame.contStack.len > 0:
    frame.pc = frame.contStack.pop()
    frame.transition(fsReady)
    engine.enqueue(frameId)
  else:
    frame.transition(fsDone)
    if frame.hasResult and frame.result.kind == bvProgram and not frame.failed:
      engine.pendingBvResolve.addLast(frameId)
    if frame.parentFrameId >= 0:
      engine.pendingPropagation.addLast(frameId)

proc resolveBvPrograms(engine: Engine) =
  ## Resolve bvProgram results in done frames by spawning child frames.
  ## Child inherits parent's handlers. Parent waits in fsSuspended.
  while engine.pendingBvResolve.len > 0:
    let i = engine.pendingBvResolve.popFirst()
    if engine.frames[i].state != fsDone: continue
    if not engine.frames[i].hasResult: continue
    if engine.frames[i].result.kind != bvProgram: continue
    if engine.frames[i].failed: continue
    
    let innerProg = engine.frames[i].result.innerProgram
    # Spawn child
    discard engine.newFrame(innerProg, innerProg.entry, i)
    # Modify parent after spawn
    engine.frames[i].hasResult = false
    engine.frames[i].transition(fsSuspended)

proc step(engine: Engine): bool =
  ## Execute one frame step. Returns true if work was done.
  if engine.queueLen == 0:
    return false

  let frameId = engine.dequeue()
  if frameId >= engine.frames.len:
    return true

  let frame = engine.frames[frameId]
  frame.transition(fsRunning)

  if frame.pc.int < 0 or frame.pc.int >= frame.program.ops.len:
    frame.error = RtError(kind: ForeignError, msg: "Invalid PC: " & $frame.pc.int)
    frame.failed = true
    completeOrReturn(engine, frame, frameId)
    return true

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
  while engine.pendingPropagation.len > 0:
    let i = engine.pendingPropagation.popFirst()
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
      
    # Parent is done
    engine.frames[pid].transition(fsDone)
    # Check if parent needs bvResolve or its own propagation
    if engine.frames[pid].hasResult and engine.frames[pid].result.kind == bvProgram and not engine.frames[pid].failed:
      engine.pendingBvResolve.addLast(pid)
    if engine.frames[pid].parentFrameId >= 0:
      engine.pendingPropagation.addLast(pid)
      
    # Mark child as consumed
    child.parentFrameId = -1

proc hasWorkToDo(engine: Engine): bool =
  ## Check if there's pending work.
  engine.queueLen > 0 or engine.pendingBvResolve.len > 0 or engine.pendingPropagation.len > 0

proc runLoop*(engine: Engine) =
  ## Execute until no more work or budget exhausted.
  var steps = 0
  while steps < engine.budget and engine.hasWorkToDo():
    if engine.queueLen > 0:
      discard engine.step()
      steps += 1
    # Resolve bvProgram results via child frames
    engine.resolveBvPrograms()
    # Propagate child→parent results
    engine.propagateChildResults()

proc interpretProgram*(engine: Engine, program: EffProgram, entry: ContId): tuple[hasResult: bool, result: BoxedValue, failed: bool, error: RtError, budgetExhausted: bool] =
  let frameId = engine.newFrame(program, entry)
  
  var steps = 0
  while steps < engine.budget and engine.hasWorkToDo():
    if engine.queueLen > 0:
      discard engine.step()
      steps += 1
    engine.resolveBvPrograms()
    engine.propagateChildResults()

  result.budgetExhausted = (steps >= engine.budget)

  if frameId < engine.frames.len:
    let frame = engine.frames[frameId]
    result.hasResult = frame.hasResult
    result.result = frame.result
    result.failed = frame.failed
    result.error = frame.error

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
  let raw = engine.interpretProgram(eff.program, eff.program.entry)

  if raw.budgetExhausted:
    return evalFalse[T](RtError(kind: Timeout, msg: "execution budget exhausted"))
    
  if raw.failed:
    return evalFalse[T](raw.error)
  elif raw.hasResult:
    return evalTrue(eff.unboxer(raw.result))
    
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
