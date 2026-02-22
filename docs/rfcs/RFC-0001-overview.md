# RFC-0001: RTEffects v2 — State Machine VM with Algebraic Effects and Belnap Semantics

## Status

- [x] Draft
- [x] Review
- [x] Accepted
- [ ] Superseded

Core modules (core, semantics, algebra, vm/types, vm/engine) have been
implemented. Concurrency primitives remain in the v1 runtime and are planned
for future migration.

## Summary

Replace CPS callback architecture with a state machine VM using defunctionalized
continuation tables, introduce Belnap 4-valued evaluation semantics, and provide
algebraic effects (perform/handle) as the primary user API.

## Motivation

### Problems with v1

1. **Monolithic runtime** — `runtime.nim` (1240 lines) mixes scheduling, channels,
   semaphores, and mutexes in a single module with no clear bounded contexts.

2. **2-valued Result permeates the API** — `Cont[T] = proc(rt, res: Result[T])`
   forces a binary success/failure model at every layer. The continuation itself
   carries a 2-valued result, preventing the system from expressing intermediate
   states like "suspended" or "contradictory."

3. **Hardcoded effects** — `sleep`, `spawn`, `cancel` are built-in runtime
   operations. Users cannot define custom effects or compose handlers.

4. **No handler composition** — The essence of algebraic effects (perform an
   operation, let a handler interpret it) is absent. Error handling uses
   `recover`/`catchError` rather than structured effect handlers.

5. **Cannot model contradictory or undetermined states** — Speculative execution,
   race conditions producing both success and failure, and suspended computations
   have no principled representation.

### Why Belnap 4-valued logic?

Belnap's First-Degree Entailment (FDE) provides exactly four truth values:

| Value | Meaning | Use case |
|-------|---------|----------|
| T (True) | Computation succeeded with a definite value | Normal completion |
| F (False) | Computation failed with a definite error | Error handling |
| B (Both) | Contradictory — both success and failure exist | Race/speculative execution merge |
| N (Neither) | Undetermined — neither success nor failure yet | Suspension, cancellation, timeout |

These four values form a complete De Morgan lattice with well-defined algebraic
properties (join, meet, negation), making them composable and mathematically sound.

### Why state machine VM?

CPS callbacks allocate heap closures for every continuation. A defunctionalized
continuation table represents the same control flow as flat data:

- **Inspectable**: The VM can examine and optimize the program structure
- **Serializable**: Programs can be checkpointed and restored
- **Traceable**: Every state transition is observable without closure introspection
- **Cache-friendly**: Sequential ops in a `seq` beat pointer-chasing through closures

## Architecture Overview

### Bounded Context Map

```
┌─ Effect Algebra (app developer) ────────────┐
│  Eff[T], perform, handle, pure, andThen     │
│  → Does NOT see TruthValue                  │
│  → Composes computations declaratively      │
└────────┬────────────────────────────────────┘
         │ effects interpreted by handlers
┌────────▼────────────────────────────────────┐
│  Handler Semantics (handler author)         │
│  TruthValue, Eval[T], resume/abort closures │
│  Handler receives:                          │
│    (payload: BoxedValue,                    │
│     resume: proc(v: BoxedValue),            │
│     abort: proc(e: RtError))               │
│  suspend = neither resume nor abort called  │
│  → Operates on 4-valued evaluation states   │
└────────┬────────────────────────────────────┘
         │ Eval[T] flows through VM
┌────────▼────────────────────────────────────┐
│  VM Execution (internal)                    │
│  Frame, EffProgram, Engine                  │
│  Defunctionalized continuation table        │
│  Lightweight enum state (ADR-006)           │
│  → Completely hidden from users             │
└────────┬────────────────────────────────────┘
         │ Eval[T] → Result[T] (ACL)
┌────────▼────────────────────────────────────┐
│  Runner (outermost)                         │
│  run(): Result[T]                           │
│  → The only place 2-valued appears          │
│  → EXIT of the effects system, not the API  │
│  → Lives in vm/engine.nim (runner ACL)      │
└─────────────────────────────────────────────┘
```

### Module Structure

```
src/rteffects/
├── core.nim          # RtError, Result[T], TaskId (shared kernel)
├── semantics.nim     # TruthValue, Eval[T], Belnap lattice operations
├── algebra.nim       # Eff[T], pure, andThen, map, perform, handle
└── vm/
    ├── types.nim     # EffOp, EffProgram, ContId, BoxedValue, EffectTag
    └── engine.nim    # Frame, Engine, interpret, run (includes runner ACL)
```

**Planned future modules** (not yet implemented):

| Module | Purpose |
|--------|---------|
| `runner.nim` | Standalone runner with configurable collapse strategies |
| `scheduler.nim` | ReadyQueue, multi-frame task lifecycle |
| `trace.nim` | TraceEvent, Snapshot (observability) |
| `nursery.nim` | Structured concurrency (as v2 effect handler) |
| `channel.nim` | Inter-task communication (as v2 effect handler) |
| `sync.nim` | Semaphore, Mutex (as v2 effect handler) |
| `cps.nim` | `.rt.` macro (syntax sugar over algebra.nim) |

Note: `nursery.nim` and `cps.nim` exist as v1 modules built on `runtime.nim`.
They will be reimplemented as v2 effect handlers in a future iteration.

### Key Principle: Result[T] is the EXIT, not the API

```
User writes:   perform FileRead("config.json")
Handler sees:  BoxedValue + resume/abort closures (→ TruthValue implicitly)
VM executes:   Frame state transitions on EffProgram (lightweight enum, ADR-006)
Runner exits:  Result[T] (the only 2-valued boundary)
```

## Key Types

### RtError

The shared error type across the system. Supports error chaining (`cause`),
aggregate errors (`children`), and Belnap-specific error kinds (`Contradiction`,
`Incomplete`) for when 4-valued states collapse to 2-valued at the runner boundary.

### BoxedValue

The VM uses `BoxedValue` (a variant object) instead of `RootRef` for type-erased
values. This avoids heap allocation for common scalar types:

```nim
BoxedValueKind = enum
  bvNone, bvInt, bvStr, bvFloat, bvBool, bvRef, bvProgram
```

The `bvProgram` variant carries a nested `EffProgram` for `andThen` chains,
allowing the engine to resolve inner programs without circular imports.

## External Dependencies

None. The library requires only `nim >= 2.3.0`.

The `actor-state-machine` dependency was removed in ADR-006 after benchmarking
showed it consumed 57% of execution time. Frame state is now a lightweight enum
with optional debug history (`-d:rteffectsDebug`).

## Key Decisions

- **ADR-001**: Belnap 4-valued semantics for evaluation layer
- **ADR-002**: State machine VM with defunctionalized continuation table
- **ADR-003**: Algebraic effects (perform/handle) as primary API
- **ADR-004**: 3-tier API visibility (app / handler / runner)
- **ADR-005**: Module boundaries derived from bounded context analysis
- **ADR-006**: VM performance optimization (StateMachine removal, fast paths)

## Migration Path

1. Build new modules alongside existing code (v1 untouched) — **done**
2. New tests validate v2 modules independently — **done**
3. Create compatibility layer: `Task[T] = Eff[T]`, `runDefault = run`
4. Existing test suite validates backward compatibility
5. Gradually migrate high-level patterns (nursery, channel, sync)

## Rejected Alternatives

### Keep CPS callbacks with module splitting only

Would address the monolith problem but not the 2-valued limitation or lack of
algebraic effects. The fundamental `Cont[T] = proc(rt, res: Result[T])` design
prevents expressing B and N states.

### 3-valued logic (Kleene) instead of 4-valued

Kleene logic has {T, F, Unknown} but cannot distinguish between "contradictory"
(B: both T and F information received) and "unknown" (N: no information received).
This distinction is critical for handler authors dealing with race conditions
versus suspended computations.

### Expose 4-valued logic to all API consumers

Would make the API unnecessarily complex for app developers who just want to
compose effects. The 3-tier visibility model keeps simplicity for the common case
while providing power for handler authors.

### Free monad (ref object hierarchy) for Eff[T]

Would allocate heap closures for every `andThen` node, similar to v1's CPS
problem. The defunctionalized continuation table avoids this by representing
the program as flat data.
