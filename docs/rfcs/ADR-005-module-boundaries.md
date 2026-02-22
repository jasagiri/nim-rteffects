# ADR-005: Module Boundaries from Bounded Context Analysis

## Status

Accepted

## Context

RTEffects v1 has four modules:
- `core.nim` (111 lines) — types only
- `runtime.nim` (1240 lines) — everything else
- `cps.nim` (210 lines) — macro
- `nursery.nim` (188 lines) — structured concurrency

The monolithic `runtime.nim` violates bounded context separation: scheduling,
channel communication, semaphores, mutexes, async dispatch, tracing, and
cancellation are all in one module with shared mutable state.

A bounded context analysis (Wittgenstein language game methodology) identified
five distinct contexts, each with its own ubiquitous language and rules.

## Decision

Decompose the system into modules aligned with bounded contexts. Each module
owns its terms and communicates through explicit boundaries (ACL or Shared Kernel).

### Context → Module Mapping

| Bounded Context | Module(s) | Primary Terms |
|----------------|-----------|---------------|
| Effect Algebra | `algebra.nim` | Eff[T], perform, handle, pure, andThen |
| Evaluation Semantics | `semantics.nim` | TruthValue, Eval[T], join, meet, negate |
| VM Execution | `vm/types.nim`, `vm/engine.nim`, `vm/scheduler.nim` | Frame, EffProgram, ContId, Scheduler |
| Type Safety | `core.nim` | EffError, Result[T], TaskId |
| Observability | `trace.nim` | TraceEvent, Snapshot |

High-level patterns (nursery, channel, sync) are effect handlers built on
top of the algebra and VM:

| Pattern | Module | Built as |
|---------|--------|----------|
| Structured concurrency | `nursery.nim` | Effect handler |
| Inter-task communication | `channel.nim` | Effect handler |
| Synchronization | `sync.nim` | Effect handler |

### Boundary Types

#### ACL: Effect Algebra ↔ Evaluation Semantics

`algebra.nim` does NOT import `semantics.nim`. The bridge is in `vm/engine.nim`
which imports both and translates `Eff[T]` tree traversal into `Eval[T]` results.

```
algebra.nim ──(Eff[T])──→ vm/engine.nim ──(Eval[T])──→ semantics.nim
```

This ACL ensures that app developers (Tier 1) never encounter TruthValue.

#### ACL: VM ↔ Runner

The runner imports `vm/engine.nim` and calls `interpret()` which returns `Eval[T]`.
The runner then calls `toResult()` from `semantics.nim` to collapse 4-value to 2-value.

```
vm/engine.nim ──(Eval[T])──→ runner.nim ──(Result[T])──→ user code
```

#### Shared Kernel: core.nim

`EffError`, `Result[T]`, `TaskId` are shared by all contexts. These are stable,
rarely-changing types that form the shared kernel.

### Module Dependency Graph

```
core.nim (shared kernel — no dependencies)
    ↑
semantics.nim (depends on core for EffError)
    ↑
vm/types.nim (depends on core, semantics)
    ↑
algebra.nim (depends on core, vm/types for ContId/EffProgram)
    ↑
vm/engine.nim (depends on all above)
    ↑
vm/scheduler.nim (depends on vm/types)
    ↑
runner.nim (depends on vm/engine, semantics)
    ↑
nursery.nim, channel.nim, sync.nim (depend on algebra, vm/scheduler)
    ↑
cps.nim (depends on algebra — macro generates builder API calls)
```

### File Layout

```
src/rteffects/
├── core.nim          # Shared Kernel: EffError, Result[T], TaskId
├── semantics.nim     # Evaluation Semantics: TruthValue, Eval[T], lattice
├── algebra.nim       # Effect Algebra: Eff[T], pure, andThen, perform, handle
├── vm/
│   ├── types.nim     # VM types: EffOp, EffProgram, ContId, Frame, Resumption
│   ├── engine.nim    # VM engine: interpret, step, main loop
│   └── scheduler.nim # Scheduler: ReadyQueue, task lifecycle
├── runner.nim        # Runner ACL: run() → Result[T]
├── trace.nim         # Observability: TraceEvent, Snapshot
├── nursery.nim       # Structured concurrency (effect handler)
├── channel.nim       # Channels (effect handler)
├── sync.nim          # Semaphore, Mutex (effect handler)
└── cps.nim           # .rt. macro (syntax sugar)

src/rteffects.nim     # Re-exports algebra + runner (convenience)
```

## Rationale

### vs. Keep monolithic runtime.nim

The monolith prevents independent testing, independent evolution, and clear
ownership of concepts. Every change risks unintended coupling.

### vs. Split by technical layer (types/impl/api)

Technical layering (all types in one file, all impls in another) does not
capture domain boundaries. `TruthValue` and `EffProgram` are in different
bounded contexts even though both are "types."

### vs. One module per type

Too fine-grained. A bounded context groups related types and operations that
share rules and meaning. `TruthValue`, `Eval[T]`, `join`, `meet`, `negate`
belong together in `semantics.nim`.

## Consequences

### Positive

- Each module has a single bounded context with clear ubiquitous language
- ACL boundaries prevent concept leakage between contexts
- Modules can be tested independently (semantics.nim has zero side effects)
- New effect handlers (nursery, channel) follow the same pattern

### Negative

- More files to navigate (13 vs 4)
- Import chains are longer
- Circular dependency risk if boundaries are violated

### Neutral

- Total code volume is similar — just redistributed
- The `.rt.` macro output changes but user-facing syntax stays the same
