# ADR-002: State Machine VM with Defunctionalized Continuation Table

## Status

Accepted

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
    opMap        ## Transform current value
    opPerform    ## Request effect handling
    opHandle     ## Install effect handler scope

  EffOp* = object
    case kind*: EffOpKind
    of opPure:
      value*: RootRef
    of opFail:
      error*: EffError
    of opBind:
      source*: ContId
      next*: ContId
    of opMap:
      mapTarget*: ContId
      mapFn*: proc(v: RootRef): RootRef {.gcsafe, closure.}
    of opPerform:
      tag*: EffectTag
      payload*: RootRef
    of opHandle:
      body*: ContId
      handlerTag*: EffectTag
      handlerImpl*: HandlerProc

  EffProgram* = object
    ops*: seq[EffOp]
    entry*: ContId
```

### Frame: Execution State

Each running computation has a Frame tracking its position in the program:

```nim
type
  FrameId* = distinct int
  FrameState* = enum
    fsReady, fsRunning, fsSuspended, fsDone

  Frame* = object
    id*: FrameId
    parentId*: FrameId
    pc*: ContId               ## Program counter into EffProgram
    program*: ptr EffProgram
    state*: FrameState
    eval*: RootRef            ## Current Eval[T]
    handlerStack*: seq[HandlerEntry]
    locals*: seq[RootRef]     ## Frame-local values
```

### Engine: State Machine Loop

The engine dequeues ready frames and executes one instruction per step:

```nim
proc step(engine: Engine): bool =
  let frameId = engine.readyQ.dequeue()
  var frame = engine.frames[frameId]
  frame.state = fsRunning

  let op = frame.program.ops[frame.pc.int]
  case op.kind
  of opPure:
    frame.eval = box(evalTrue(op.value))
    frame.state = fsDone
  of opFail:
    frame.eval = box(evalFalse(op.error))
    frame.state = fsDone
  of opBind:
    # Push source frame, set up continuation
    let childId = engine.newFrame(frame.id, op.source)
    engine.enqueue(childId)
    frame.state = fsSuspended  # wait for child
    frame.pc = op.next         # resume here after child completes
  of opPerform:
    # Walk handler stack, find matching handler
    engine.dispatchEffect(frame, op.tag, op.payload)
  of opHandle:
    frame.handlerStack.add(HandlerEntry(tag: op.handlerTag, impl: op.handlerImpl))
    frame.pc = op.body
    engine.enqueue(frame.id)
  of opMap:
    let childId = engine.newFrame(frame.id, op.mapTarget)
    engine.enqueue(childId)
    # ... transform result when child completes
```

### InternalJump: Low-Frequency Escape

For rare cases (fatal errors, deep unwinding), an exception-based jump:

```nim
type
  InternalJump* = object of CatchableError
    targetFrame*: FrameId
    reason*: string
```

This is **never exposed** in any public API. `{.raises: [].}` on all public procs
guarantees this statically.

## Rationale

### vs. CPS callbacks (current)

| Aspect | CPS Callbacks | Continuation Table |
|--------|--------------|-------------------|
| Allocation | Heap closure per andThen | Flat seq of ops |
| Inspectability | Opaque procs | Structured data |
| Tracing | Requires hooks | Natural (walk ops) |
| Serialization | Impossible | Possible (minus closures) |
| Suspension | Complex (save closure) | Natural (save pc + locals) |

### vs. Bytecode VM

A full bytecode VM would compile Nim expressions into instructions. This is
overengineering — we only need to represent the **control flow structure**
(bind, perform, handle), not arbitrary computation. Leaf operations (value
transformations) remain as Nim procs via `mapFn` and `handlerImpl`.

### vs. Free monad (ref object tree)

A free monad tree (`Pure | Bind | Perform | Handle`) would be recursive ref
objects — similar allocation pressure to CPS. The continuation table is a
flattened form of the same structure.

## Consequences

### Positive

- Program structure is inspectable data, enabling tracing and debugging
- Frame suspension/resumption is natural (save/restore pc + locals)
- Budget-based preemption works by counting steps, not estimating closure depth
- Handler dispatch walks a data structure, not a closure chain
- Memory layout is cache-friendly (sequential ops in seq)

### Negative

- Value transformations still require closures (`mapFn`, `handlerImpl`)
- Type erasure via `RootRef` loses compile-time type safety inside the VM
- The builder API must manage ContId linking correctly

### Neutral

- Complexity moves from closure management to table management — roughly equivalent
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
    EffOp(kind: opBind, source: ContId(1), next: ContId(2)),  # [0] entry
    EffOp(kind: opPure, value: box(1)),                        # [1] source
    EffOp(kind: opMap, mapTarget: ContId(1),                   # [2] continuation
          mapFn: proc(v: RootRef): RootRef = box(unbox[int](v) + 1))
  ],
  entry: ContId(0)
)
```
