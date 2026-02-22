# ADR-006: VM Performance Optimization — Lightweight Frame State and Fast-Path Interpretation

## Status

Accepted

Supersedes: StateMachine integration in ADR-002

## Context

Benchmarking revealed that the `actor-state-machine` library used for Frame state
management (ADR-002) was the dominant performance bottleneck, consuming **57% of
execution time** for the simplest operation (`pure[int](42) + run`).

### Root cause analysis

Profiling with isolated cost-breakdown benchmarks identified three layers of overhead:

| Component | Cost (ns) | % of total | Root cause |
|-----------|-----------|-----------|------------|
| `StateMachine.handleEvent` | 1,562 | 57% | `now()` ×3 (~730ns) + `newJObject()` (~71ns) + history push per transition |
| `newEngine()` (Table + Deque init) | 623 | 23% | `initTable[int, Frame]` + `initDeque[int]` heap allocation |
| Frame copy/writeback | ~400 | 15% | `var frame = engine.frames[id]` + `engine.frames[id] = frame` per step |
| Remaining (boxing, ops) | ~140 | 5% | Inherent VM cost |

Total: **2,726 ns** for `pure[int](42) + run`.

### Usage audit

A systematic audit of all StateMachine features across the codebase found:

| Feature | Used? | Details |
|---------|-------|---------|
| State transitions | Yes | 4 events (evDequeue, evYield, evComplete, evSuspend) |
| Return value of `handleEvent` | **No** | All 14 call sites use `discard` |
| Transition history | **No** | Only in 3 tests, not in production code |
| Metrics | **No** | Only in 1 test |
| Observer hooks | **No** | Never used |
| Lock/Rollback/Consensus | **No** | Never used |
| JSON export | **No** | Never used |

The engine uses StateMachine as a write-only enum assignment. All of its advanced
features (history, metrics, observers, rollback, consensus, JSON export) are unused.

## Decision

Replace the StateMachine dependency and associated infrastructure with three
targeted optimizations applied incrementally.

### Round 1: StateMachine → lightweight enum

Remove `import state_machine` and `StateMachine[FrameState, FrameEvent]`.
Replace `Frame.sm` with a direct `Frame.state: FrameState` field.
Replace all `discard frame.sm.handleEvent(evXxx)` with inline state assignment
via a `transition` proc:

```nim
proc transition(frame: var Frame, to: FrameState) {.inline.} =
  when defined(rteffectsDebug):
    frame.transitions.add(TransitionRecord(
      fromState: frame.state, toState: to))
  frame.state = to
```

Remove the `FrameEvent` enum entirely — events were only meaningful to the
StateMachine. The engine directly assigns the target state.

Optional debug support via compile-time flag:

```nim
when defined(rteffectsDebug):
  type TransitionRecord* = object
    fromState*, toState*: FrameState
```

### Round 2: seq-based storage and fast-path interpretation

**Replace `Table[int, Frame]` with `seq[Frame]`**: Frame IDs are sequential
integers (0, 1, 2, ...) assigned by `newFrame`. A seq provides O(1) indexed
access with better cache locality than a hash table.

**Replace `Deque[int]` with `seq[int]` + `readyHead` index**: The ready queue
is append-only with sequential consumption. A seq with a head pointer avoids
deque node allocation:

```nim
Engine* = ref object
  frames*: seq[Frame]
  readyQ*: seq[int]       ## Simple queue (append + index scan)
  readyHead*: int         ## Index of next item to dequeue
  budget*: int
```

**Add fast-path for trivial programs**: When the top-level `Eff[T]` program
consists of a single `opPure` or `opFail`, bypass Engine creation entirely:

```nim
proc tryFastInterpret[T](eff: Eff[T]): (bool, Eval[T]) =
  let entry = eff.program.entry.int
  if entry < 0 or entry >= eff.program.ops.len:
    return (false, evalNeither[T]())
  let op = eff.program.ops[entry]
  case op.kind
  of opPure: return (true, evalTrue(eff.unboxer(op.pureValue)))
  of opFail: return (true, evalFalse[T](op.failError))
  else:      return (false, evalNeither[T]())
```

### Round 3: Inline bvProgram resolution and in-place frame access

**Inline bvProgram fast-resolve in opBind**: When `andThen` closures return
trivial programs (the common case: `pure[int](x + 1)`), resolve the inner
program's entry op directly without creating a new frame:

```nim
of opBind:
  if frame.hasResult and frame.result.kind == bvProgram:
    let innerOp = frame.result.innerProgram.ops[innerEntry]
    case innerOp.kind
    of opPure:
      frame.result = innerOp.pureValue  # resolve inline
      engine.enqueue(frameId)
    of opFail:
      frame.error = innerOp.failError   # resolve inline
    else:
      # fallback to full interpretStep for complex inner programs
```

**Fast-resolve in `interpretStep`**: Same pattern — check for trivial programs
before creating a frame, using a loop to resolve chained bvProgram results:

```nim
proc interpretStep(engine, program, entry) =
  while true:
    let op = prog.ops[ent.int]
    case op.kind
    of opPure: return (hasResult: true, result: op.pureValue)
    of opFail: return (failed: true, error: op.failError)
    else: discard
    let raw = engine.interpretProgram(prog, ent)
    if raw.hasResult and raw.result.kind == bvProgram:
      prog = raw.result.innerProgram; continue
    return raw
```

**In-place frame access**: Replace the copy/writeback pattern with a template
that operates directly on the seq element:

```nim
# Before: copies ~200 bytes twice per step
var frame = engine.frames[frameId]
# ... modify frame ...
engine.frames[frameId] = frame

# After: modifies in place (zero copy)
template frame: untyped = engine.frames[frameId]
```

This is safe because the template re-evaluates `engine.frames[frameId]` on each
access, so even if `engine.frames` is reallocated (by `newFrame` in the
`interpretStep` fallback path), the access resolves to the current array.

## Rationale

### vs. Keeping StateMachine with optimization flags

The StateMachine library's core design calls `now()` and allocates JSON on every
transition. Even with history disabled, the function call overhead and
`newJObject` allocation remain in the hot path. Removing the dependency
eliminates the overhead entirely.

### vs. Custom lightweight state machine

A validation-only state machine (transition table, no history) was considered.
However, the engine's state transitions are trivially correct (4 states, 5
transitions, all controlled by the engine itself, no external events). A
transition table adds overhead without catching real bugs. Direct enum
assignment with optional debug history provides equivalent safety at zero
runtime cost.

### vs. Arena allocation for frames

Pre-allocating a fixed-size frame pool was considered for Round 2. However,
`seq[Frame]` with sequential IDs provides equivalent O(1) access with simpler
implementation. Arena allocation would only help if frame creation/destruction
were frequent (they are not — frames are created once and run to completion).

### vs. Pointer-based frame access

Using `addr engine.frames[frameId]` was considered instead of the template
approach. This would be unsafe if `engine.frames` grows (via `newFrame` during
recursive `interpretStep`), invalidating the pointer. The template approach
is safe by construction since it re-evaluates on each access.

### Why inline bvProgram resolution matters

In a typical `andThen` chain, each step's closure returns `pure[int](x + 1)`,
producing a `bvProgram` with a single `opPure` entry. Without inline resolution,
each step creates a new frame in `interpretStep`, runs the stepping loop (1
step), extracts the result, and destroys the frame. With inline resolution,
the `opPure` value is extracted directly — no frame, no stepping loop, no
queue operations.

## Results

All measurements: `-d:release -d:danger --opt:speed`, 5 repeats.

### Cumulative improvement

| Benchmark | Original (ns) | Round 1 | Round 2 | Round 3 | Total speedup |
|-----------|---------------|---------|---------|---------|---------------|
| pure[int]+run | 2,726 | 929 | 82 | 82 | **33x** |
| andThen 5-step | 42,636 | 7,732 | 6,879 | 3,246 | **13x** |
| fail short-circuit | 28,445 | 5,618 | 4,895 | 2,492 | **11x** |
| perform+handle | 5,885 | 1,395 | 848 | 624 | **9.4x** |
| map chain (3) | 12,110 | 2,279 | 1,560 | 1,021 | **12x** |
| depth=100 | 1,457,037 | 724,107 | 698,800 | 170,302 | **8.6x** |

### vs. exception overhead ratio

| Benchmark | Before | After |
|-----------|--------|-------|
| perform+handle | 23x slower | **9.8x** slower |
| pure return | ~1,000x | **118x** |
| fail propagation | ~570x | **50x** |

### Cost breakdown (final state)

| Component | Cost (ns) | % of pure+run |
|-----------|-----------|---------------|
| pure[int](42) construction | 48 | 59% |
| newEngine() | 24 | 29% |
| boxing/unboxing | 8 | 10% |
| stepping overhead | ~2 | 2% |

## Consequences

### Positive

- 8.6x–33x speedup across all scenarios without API changes
- Zero external dependencies (`actor-state-machine` removed)
- `perform+handle` under 10x exception overhead (was 23x)
- Fast path makes trivial programs (pure/fail) nearly free
- In-place frame access eliminates ~400 bytes of copying per engine step
- Debug history available via `-d:rteffectsDebug` compile flag

### Negative

- No runtime transition validation (invalid transitions silently succeed)
  - Mitigated: engine controls all transitions; no external state mutation
  - Mitigated: `when defined(rteffectsDebug)` records history for debugging
- No observer hooks for frame lifecycle events
  - Mitigated: no code used this feature
  - Mitigated: can be added as a separate concern if needed

### Remaining bottlenecks

| Bottleneck | Cost | Fix complexity | Description |
|-----------|------|---------------|-------------|
| `pure[int]` construction | 48ns | Medium | Heap allocation of `Eff[T]` ref + `EffProgram` + boxer/unboxer closures |
| `andThen` construction | 185ns/step | High | `mergeProgram` copies O(n) ops per step → O(n²) total for n-step chains |
| Closure allocation in chains | ~50ns/step | High | Each andThen closure `proc(x): Eff[U] = pure(x+1)` allocates new Eff + EffProgram |
| Deep chain scaling | O(n²) | High | Requires shared program references or structural sharing |

The O(n²) construction cost in `mergeProgram` is the dominant factor for deep
chains (depth=100: 170μs). Addressing this requires shared program references
— a larger architectural change deferred to a future ADR.

## Files Changed

| File | Change |
|------|--------|
| `src/rteffects/vm/engine.nim` | Replaced SM with enum, seq-based storage, fast paths, in-place access |
| `tests/t_engine.nim` | Updated 5 SM tests to check `frame.state` directly |
| `rteffects.nimble` | Removed `requires "actor_state_machine >= 0.1.0"` |
| `config.nims` | Removed external path dependency |
| `benchmarks/bench_cost_breakdown.nim` | Updated for post-SM architecture |
