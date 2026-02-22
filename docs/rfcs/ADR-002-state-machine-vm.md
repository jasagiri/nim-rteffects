# ADR-002: State Machine VM with Defunctionalized Continuation Table

## Status

Accepted (partially superseded by ADR-006)

**Note**: The defunctionalized continuation table and Frame/Engine architecture
remain as designed. The `StateMachine[FrameState, FrameEvent]` integration for
frame state management has been replaced with a lightweight enum — see ADR-006
for rationale and performance data.

## Context

RTEffects v1 represents computations as CPS callbacks:

```nim
Task[T] = proc(rt: ptr Runtime, k: Cont[T]) {.gcsafe, closure.}
Cont[T] = proc(rt: ptr Runtime, res: Result[T]) {.gcsafe, closure.}
```

Every `andThen` allocates a heap closure. Every continuation is an opaque proc
that cannot be inspected, serialized, or traced. The runtime is a monolithic
1240-line struct mixing scheduling, channels, and synchronization.

For the redesigned effects system with 4-valued semantics, we need:
- A representation that can be inspected (for tracing and debugging)
- State transitions that produce `Eval[T]` (not `Result[T]`)
- Efficient handling of high-frequency operations (branching, rollback)
- Clear separation between program structure and execution state

## Decision

Replace CPS callbacks with a **defunctionalized continuation table** executed
by a **state machine VM**.

### BoxedValue: Type-Erased Values

Values flowing through the VM are wrapped in `BoxedValue`, a variant object
that avoids `RootRef` casting for common types:

```nim
type
  BoxedValueKind* = enum
    bvNone, bvInt, bvStr, bvFloat, bvBool, bvRef, bvProgram

  BoxedValue* = object
    case kind*: BoxedValueKind
    of bvNone: discard
    of bvInt: intVal*: int
    of bvStr: strVal*: string
    of bvFloat: floatVal*: float
    of bvBool: boolVal*: bool
    of bvRef: refVal*: RootRef
    of bvProgram:
      innerProgram*: EffProgram  ## Nested program from andThen
      innerUnboxer*: proc(v: BoxedValue): BoxedValue {.gcsafe.}
```

The `bvProgram` kind is critical for monadic bind (`andThen`): the `mapFn`
closure returns a `BoxedValue(kind: bvProgram)` carrying a nested `EffProgram`.
The engine resolves these via recursive `interpretStep`.

### EffProgram: The Continuation Table

A computation is represented as a flat sequence of operations with explicit
continuation links:

```nim
type
  ContId* = distinct int

  EffOpKind* = enum
    opPure       ## Return a value
    opFail       ## Return an error
    opBind       ## Sequence: run source, pass result to next
    opMap        ## Transform current value with a function
    opPerform    ## Request effect handling
    opHandle     ## Install effect handler scope

  EffOp* = object
    case kind*: EffOpKind
    of opPure:
      pureValue*: BoxedValue
    of opFail:
      failError*: RtError
    of opBind:
      bindSource*: ContId   ## Run this first
      bindNext*: ContId     ## Then continue here with result
    of opMap:
      mapTarget*: ContId
      mapFn*: proc(v: BoxedValue): BoxedValue {.gcsafe, closure.}
    of opPerform:
      performTag*: EffectTag
      performPayload*: BoxedValue
    of opHandle:
      handleBody*: ContId
      handleTag*: EffectTag
      handleImpl*: proc(payload: BoxedValue,
                        resume: proc(v: BoxedValue) {.gcsafe.},
                        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}

  EffProgram* = object
    ops*: seq[EffOp]
    entry*: ContId
```

### Frame: Execution State

Each running computation has a Frame tracking its position in the program.
State transitions use direct enum assignment via an inline `transition` proc
(see ADR-006 for the migration from `StateMachine`):

```nim
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
```

State transitions are inlined with optional debug recording:

```nim
proc transition(frame: var Frame, to: FrameState) {.inline.} =
  when defined(rteffectsDebug):
    frame.transitions.add(TransitionRecord(
      fromState: frame.state, toState: to))
  frame.state = to
```

### contStack: Return Address Mechanism

Compound ops (`opBind`, `opMap`, `opHandle`) push their own `ContId` onto
`contStack` before dispatching to a sub-expression. When a terminal op
(`opPure`, `opFail`) or a completed compound op produces a result, it calls
`completeOrReturn`, which pops `contStack` to return to the parent:

```nim
proc completeOrReturn(engine: Engine, frame: var Frame, frameId: int) =
  if frame.contStack.len > 0:
    frame.pc = frame.contStack.pop()
    frame.transition(fsReady)
    engine.enqueue(frameId)
  else:
    frame.transition(fsDone)
```

This replaces the parent-child frame model. All execution happens within a
single frame using the `contStack` as an intra-frame call stack.

### Engine: Stepping Loop

The engine dequeues ready frames and executes one instruction per step.
Frames are accessed in place via a template to avoid copying (ADR-006).
State transitions use direct enum assignment:

```nim
proc step(engine: Engine): bool =
  let frameId = engine.dequeue()
  template frame: untyped = engine.frames[frameId]  # in-place access
  frame.transition(fsRunning)

  let op = frame.program.ops[frame.pc.int]
  case op.kind
  of opPure:
    frame.result = op.pureValue
    frame.hasResult = true
    completeOrReturn(engine, frame, frameId)

  of opBind:
    if frame.hasResult:
      if frame.result.kind == bvProgram:
        # Fast-resolve trivial inner programs inline (ADR-006)
        let innerOp = frame.result.innerProgram.ops[innerEntry]
        case innerOp.kind
        of opPure:
          frame.result = innerOp.pureValue
          frame.transition(fsReady)
          engine.enqueue(frameId)
        else:
          # Fallback to full interpretStep for complex inner programs
          let inner = engine.interpretStep(innerProg, innerProg.entry)
          # ...
      else:
        frame.pc = op.bindNext
        frame.transition(fsReady)
        engine.enqueue(frameId)
    # ... (fail short-circuit, first visit)

  of opPerform:
    # ... handler dispatch with resume/abort closures

  of opHandle:
    # ... install handler and evaluate body

  of opMap:
    # ... apply transform function
```

### Handler Signature

Handlers receive the payload and two inline closures -- `resume` and `abort` --
rather than a `Resumption` object. The handler calls exactly one of them to
continue execution, or calls neither to suspend the frame:

```nim
proc(payload: BoxedValue,
     resume: proc(v: BoxedValue) {.gcsafe.},
     abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}
```

## Rationale

### vs. CPS callbacks (current)

| Aspect | CPS Callbacks | Continuation Table |
|--------|--------------|-------------------|
| Allocation | Heap closure per andThen | Flat seq of ops |
| Inspectability | Opaque procs | Structured data |
| Tracing | Requires hooks | Natural (walk ops) |
| Serialization | Impossible | Possible (minus closures) |
| Suspension | Complex (save closure) | Natural (save pc + contStack) |
| Type erasure | RootRef casts | BoxedValue variant |

### vs. Bytecode VM

A full bytecode VM would compile Nim expressions into instructions. This is
overengineering -- we only need to represent the **control flow structure**
(bind, perform, handle), not arbitrary computation. Leaf operations (value
transformations) remain as Nim procs via `mapFn` and `handleImpl`.

### vs. Free monad (ref object tree)

A free monad tree (`Pure | Bind | Perform | Handle`) would be recursive ref
objects -- similar allocation pressure to CPS. The continuation table is a
flattened form of the same structure.

### Why BoxedValue over RootRef

`RootRef` requires heap allocation and unsafe downcasting for every value.
`BoxedValue` stores common types (`int`, `string`, `float`, `bool`) inline
in the variant, avoiding allocation. The `bvRef` branch preserves `RootRef`
as an escape hatch. The `bvProgram` branch enables monadic composition without
a separate mechanism.

### Why SM events over direct state assignment (superseded by ADR-006)

> **Note**: This section describes the original rationale. ADR-006 replaced the
> StateMachine with direct enum assignment after benchmarking showed 57% overhead.
> Debug history is available via `-d:rteffectsDebug`.

Using `StateMachine[FrameState, FrameEvent]` provides:
- **Validated transitions**: invalid transitions (e.g., `fsDone -> fsRunning`)
  are caught immediately instead of silently corrupting state
- **Transition history**: debuggable trace of all state changes
- **Observer hooks**: external systems can subscribe to frame lifecycle events
- **Metrics**: automatic counting of transitions for performance analysis

## Consequences

### Positive

- Program structure is inspectable data, enabling tracing and debugging
- Frame suspension/resumption is natural (save/restore pc + contStack)
- Budget-based preemption works by counting steps, not estimating closure depth
- Handler dispatch walks a data structure, not a closure chain
- Memory layout is cache-friendly (sequential ops in seq, frames in seq)
- BoxedValue avoids heap allocation for primitive types
- Fast-path interpretation bypasses Engine for trivial programs (ADR-006)
- Inline bvProgram resolution avoids frame creation for andThen chains (ADR-006)
- `bvProgram` enables recursive program resolution for monadic bind

### Negative

- Value transformations still require closures (`mapFn`, `handleImpl`)
- Type erasure via `BoxedValue` loses compile-time type safety inside the VM
- The builder API must manage ContId linking correctly
- `bvProgram` resolution via recursive `interpretStep` adds stack depth

### Neutral

- Complexity moves from closure management to table management -- roughly equivalent
- The `.rt.` macro output changes from nested procs to EffProgram construction

## Examples

### Before (v1): CPS closure chain

```nim
# pure(1).andThen(x => pure(x + 1))
# Generates:
proc task(rt: ptr Runtime, k: Cont[int]) =
  let k2: Cont[int] = proc(rt: ptr Runtime, res: Result[int]) =
    if res.isOk:
      let x = res.ok
      let k3: Cont[int] = k  # capture outer continuation
      rt.enqueueCont(proc() = k3(rt, ok(x + 1)))
    else:
      k(rt, res)
  rt.enqueueCont(proc() = k2(rt, ok(1)))
```

### After (v2): Continuation table

```nim
# pure(1).andThen(x => pure(x + 1))
# Generates:
EffProgram(
  ops: @[
    EffOp(kind: opPure, pureValue: boxInt(1)),           # [0] source
    EffOp(kind: opMap, mapTarget: ContId(0),              # [1] andThen continuation
          mapFn: proc(v: BoxedValue): BoxedValue =
            # Returns bvProgram carrying pure(unboxInt(v) + 1)
            let inner = pure(unboxInt(v) + 1)
            BoxedValue(kind: bvProgram,
              innerProgram: inner.program,
              innerUnboxer: ...)),
    EffOp(kind: opBind, bindSource: ContId(0),            # [2] entry
          bindNext: ContId(1)),
  ],
  entry: ContId(2)
)
```

### Effect handling

```nim
# perform(readTag).handle(readTag, handler)
# Generates:
EffProgram(
  ops: @[
    EffOp(kind: opPerform,                                # [0] effect request
          performTag: EffectTag("read"),
          performPayload: boxNone()),
    EffOp(kind: opHandle,                                 # [1] entry
          handleBody: ContId(0),
          handleTag: EffectTag("read"),
          handleImpl: proc(payload: BoxedValue,
                           resume: proc(v: BoxedValue) {.gcsafe.},
                           abort: proc(e: RtError) {.gcsafe.}) =
            resume(boxStr("file contents"))),
  ],
  entry: ContId(1)
)
```

### Execution trace

For `pure(1).andThen(x => pure(x + 1))`:

```
step 1: dequeue frame, transition(fsRunning)
         pc=2 (opBind), first visit -> push ContId(2) onto contStack
         set pc=0 (bindSource), transition(fsReady), enqueue

step 2: dequeue frame, transition(fsRunning)
         pc=0 (opPure), result=boxInt(1), hasResult=true
         completeOrReturn: contStack.pop -> pc=2, transition(fsReady), enqueue

step 3: dequeue frame, transition(fsRunning)
         pc=2 (opBind), hasResult=true, plain value (bvInt)
         set pc=1 (bindNext), transition(fsReady), enqueue

step 4: dequeue frame, transition(fsRunning)
         pc=1 (opMap), hasResult=true -> apply mapFn
         result=BoxedValue(kind: bvProgram, innerProgram=pure(2))
         completeOrReturn: contStack has ContId(2) -> pop, transition(fsReady)

step 5: dequeue frame, transition(fsRunning)
         pc=2 (opBind), hasResult=true, result=bvProgram
         fast-resolve: inner entry is opPure -> result=boxInt(2) (ADR-006)
         transition(fsReady), enqueue

step 6: dequeue frame, transition(fsRunning)
         pc=2 (opBind), hasResult=true, result=bvInt(2) (plain value)
         set pc=1 (bindNext), transition(fsReady), enqueue

step 7: dequeue frame, transition(fsRunning)
         pc=1 (opMap), hasResult=true -> apply mapFn (identity after resolve)
         completeOrReturn: contStack empty -> transition(fsDone)
         final result: boxInt(2)
```

Note: steps 4-5 demonstrate inline bvProgram resolution (ADR-006). Without
this optimization, step 5 would create a new frame and run interpretStep
recursively for the inner `pure(2)` program.
