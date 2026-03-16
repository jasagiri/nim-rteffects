# ADR-005: Module Boundaries from Bounded Context Analysis

## Status

Accepted (updated 2026-03-17 to reflect handlers.nim and current module layout)

## Context

RTEffects v1 had four modules:
- `core.nim` (111 lines) — types only
- `runtime.nim` (1240 lines) — everything else
- `cps.nim` (210 lines) — macro
- `nursery.nim` (188 lines) — structured concurrency

The monolithic `runtime.nim` violated bounded context separation: scheduling,
channel communication, semaphores, mutexes, async dispatch, tracing, and
cancellation were all in one module with shared mutable state.

A bounded context analysis (Wittgenstein language game methodology) identified
five distinct contexts, each with its own ubiquitous language and rules.

## Decision

Decompose the system into modules aligned with bounded contexts. Each module
owns its terms and communicates through explicit boundaries (ACL or Shared Kernel).

### Context -> Module Mapping (current implementation)

| Bounded Context | Module(s) | Primary Terms |
|----------------|-----------|---------------|
| Effect Algebra | `algebra.nim` | Eff[T], perform, handle, pure, andThen, map |
| Evaluation Semantics | `semantics.nim` | TruthValue, Eval[T], join, meet, negate, leqI |
| VM Execution | `vm/types.nim`, `vm/engine.nim` | Frame, EffProgram, ContId, BoxedValue, Engine |
| Type Safety | `core.nim` | RtError, Result[T], TaskId |
| Standard I/O Handlers | `handlers.nim` | HttpHandler, FileHandler, MockHandler, DeferredHandler |

Standard I/O handlers (`handlers.nim`) are now implemented as effect handlers
built on top of the algebra and VM, bridging two audiences: app developers who
consume ready-made handlers, and handler authors who implement new ones (see
ADR-007 and ADR-008 for the handler contract and async resume protocol).

Remaining high-level patterns (nursery, channel, sync) will be effect handlers
built on the same pattern. These are planned but not yet implemented:

| Pattern | Planned Module | Built as | Status |
|---------|---------------|----------|--------|
| Standard I/O handlers | `handlers.nim` | Effect handlers | Implemented |
| Structured concurrency | `nursery.nim` | Effect handler | Planned |
| Inter-task communication | `channel.nim` | Effect handler | Planned |
| Synchronization | `sync.nim` | Effect handler | Planned |
| Observability | `trace.nim` | Trace events | Planned |
| CPS macro | `cps.nim` | Syntax sugar | Planned |

### Boundary Types

#### ACL: Effect Algebra <-> Evaluation Semantics

`algebra.nim` does NOT import `semantics.nim`. The bridge is `vm/engine.nim`
which imports both and translates `Eff[T]` tree traversal into `Eval[T]` results.

```
algebra.nim --(Eff[T])--> vm/engine.nim --(Eval[T])--> semantics.nim
```

This ACL ensures that app developers (Tier 1) never encounter TruthValue.

#### ACL: VM Engine -> User Code (Runner)

There is no separate `runner.nim`. The runner ACL lives inside `vm/engine.nim`
as the `run*` procs. `interpret()` produces `Eval[T]`; `run()` collapses
`Eval[T]` to `Result[T]` at the boundary.

```
vm/engine.nim interpret() --(Eval[T])--> vm/engine.nim run() --(Result[T])--> user code
```

#### Shared Kernel: core.nim

`RtError`, `Result[T]`, `TaskId`, and `Unit` are shared by all contexts. These
are stable, rarely-changing types that form the shared kernel with no
dependencies of its own.

### Module Dependency Graph

```
core.nim (shared kernel -- no dependencies)
    ^
semantics.nim (depends on core for RtError)
    ^
vm/types.nim (depends on core for RtError)
    ^
algebra.nim (depends on core, vm/types for ContId/EffProgram/BoxedValue)
    ^
vm/engine.nim (depends on core, semantics, vm/types, algebra)
    ^
handlers.nim (depends on core, algebra, vm/types, vm/engine)
```

#### External Dependencies

The core library (`core.nim`, `semantics.nim`, `algebra.nim`, `vm/`) has no
external dependencies beyond `nim >= 2.3.0`.

`handlers.nim` introduces one conditional dependency: `std/httpclient` is
imported for the synchronous HTTP handler only. Async variants use the VM's
own async resume mechanism (see ADR-008) and do not pull in `std/httpclient`.

The `actor-state-machine` dependency was removed after ADR-006 identified it
as the dominant performance bottleneck (57% of execution time).

#### Key Constraints

- `algebra.nim` does NOT import `semantics.nim` -- contexts are kept separate.
- `vm/types.nim` does NOT import `semantics.nim` -- it depends only on `core.nim`.
- Handler callbacks in `algebra.nim` are inline closures (HandlerProc), not
  a separate Resumption type.
- Scheduling is handled by `vm/engine.nim` via a `readyQ: seq[int]` with
  a `readyHead` index inside the Engine -- there is no separate scheduler module.

### File Layout (current implementation)

```
src/rteffects/
├── core.nim          # Shared kernel
├── semantics.nim     # Evaluation Semantics context
├── algebra.nim       # Effect Algebra context
├── handlers.nim      # Standard I/O Handlers (HTTP, File, mock, deferred)
└── vm/
    ├── types.nim     # VM Execution context (types)
    └── engine.nim    # VM Execution context (engine + async resume API)

src/rteffects.nim     # Convenience re-export: exports all modules including handlers
```

### Planned Modules (not yet implemented)

The following modules are planned for future implementation as effect handlers
built on the algebra and VM layer:

```
src/rteffects/
├── nursery.nim       # Structured concurrency (effect handler)
├── channel.nim       # Inter-task communication (effect handler)
├── sync.nim          # Semaphore, Mutex (effect handler)
├── trace.nim         # Observability: TraceEvent, Snapshot
└── cps.nim           # .rt. macro (syntax sugar for builder API)
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

### vs. Separate runner.nim

A dedicated `runner.nim` was considered but rejected in the current design.
The `run*` procs in `vm/engine.nim` already serve as the ACL that collapses
`Eval[T]` to `Result[T]`. A separate module would add indirection without
meaningful separation -- the runner needs intimate knowledge of the engine's
Frame and Engine types.

### vs. Separate vm/scheduler.nim

A dedicated scheduler module was considered but the current scheduling logic
(a `readyQ: Deque[FrameId]` and round-robin dispatch) is simple enough to
live inside `vm/engine.nim`. If scheduling grows more complex (priority queues,
work-stealing, fair scheduling), extracting `vm/scheduler.nim` would be
warranted.

## Consequences

### Positive

- Each module has a single bounded context with clear ubiquitous language
- ACL boundaries prevent concept leakage between contexts
- Modules can be tested independently (semantics.nim has zero side effects)
- Core module count is small (6 files including handlers.nim) making navigation straightforward
- `handlers.nim` proves the pattern: standard I/O handlers live above the VM
  without modifying core or algebra (see ADR-007, ADR-008)
- New effect handlers (nursery, channel) will follow the same pattern when added

### Negative

- The runner ACL is co-located with the engine, making it harder to swap
  runner strategies independently
- Import chains are longer than the v1 monolith
- Circular dependency risk if boundaries are violated

### Neutral

- Total code volume is similar -- just redistributed
- `handlers.nim` is now implemented; remaining planned modules (nursery, channel,
  sync, trace, cps) will increase file count when implemented but each will
  follow the established pattern
