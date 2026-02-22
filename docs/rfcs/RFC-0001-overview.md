# RFC-0001: RTEffects v2 — State Machine VM with Algebraic Effects and Belnap Semantics

## Status

- [x] Draft
- [ ] Review
- [ ] Accepted
- [ ] Superseded

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
│  TruthValue, Eval[T], Resumption            │
│  resume / abort / suspend / fork / resolve  │
│  → Operates on 4-valued evaluation states   │
└────────┬────────────────────────────────────┘
         │ Eval[T] flows through VM
┌────────▼────────────────────────────────────┐
│  VM Execution (internal)                    │
│  Frame, EffProgram, Scheduler               │
│  Defunctionalized continuation table        │
│  → Completely hidden from users             │
└────────┬────────────────────────────────────┘
         │ Eval[T] → Result[T] (ACL)
┌────────▼────────────────────────────────────┐
│  Runner (outermost)                         │
│  run(): Result[T]                           │
│  → The only place 2-valued appears          │
│  → EXIT of the effects system, not the API  │
└─────────────────────────────────────────────┘
```

### Module Structure

```
src/rteffects/
├── semantics.nim     # TruthValue, Belnap lattice, Eval[T]
├── algebra.nim       # Eff[T], pure, andThen, perform, handle (builder API)
├── vm/
│   ├── types.nim     # EffOp, EffProgram, ContId, Frame, Resumption
│   ├── engine.nim    # State machine main loop, interpret
│   └── scheduler.nim # ReadyQueue, task lifecycle
├── runner.nim        # ACL: run() collapses Eval[T] → Result[T]
├── trace.nim         # TraceEvent, Snapshot (observability)
├── core.nim          # EffError, Result[T], TaskId (foundation)
├── nursery.nim       # Structured concurrency (effect handler)
├── channel.nim       # Inter-task communication (effect handler)
├── sync.nim          # Semaphore, Mutex (effect handler)
└── cps.nim           # .rt. macro (syntax sugar over algebra.nim)
```

### Key Principle: Result[T] is the EXIT, not the API

```
User writes:   perform FileRead("config.json")
Handler sees:  TruthValue + resume/abort/suspend
VM executes:   Frame state transitions on EffProgram
Runner exits:  Result[T] (the only 2-valued boundary)
```

## Key Decisions

- **ADR-001**: Belnap 4-valued semantics for evaluation layer
- **ADR-002**: State machine VM with defunctionalized continuation table
- **ADR-003**: Algebraic effects (perform/handle) as primary API
- **ADR-004**: 3-tier API visibility (app / handler / runner)
- **ADR-005**: Module boundaries derived from bounded context analysis

## Migration Path

1. Build new modules alongside existing code (v1 untouched)
2. New tests validate v2 modules independently
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
