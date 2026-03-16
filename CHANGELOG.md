# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-03-17

Initial public release. RTEffects v2 is a complete rewrite from the v1 CPS-based
architecture to algebraic effects with Belnap 4-valued paraconsistent logic.

### Highlights

- **Paraconsistent computation model**: 4-valued Belnap logic (`tvTrue`, `tvFalse`,
  `tvBoth`, `tvNeither`) replaces classical 2-valued error handling. Contradictory
  states (success AND failure simultaneously) are first-class values, not crashes.
- **Algebraic effects**: `perform`/`handle` as the primary composition API.
  Effects are named by `EffectTag`, handled by composable closures, and can be
  swapped between production, mock, and deferred implementations without changing
  application code.
- **State machine VM**: A defunctionalized continuation table (`EffProgram`)
  interpreted by a frame-based cooperative engine, replacing heap-allocated CPS
  callbacks with flat arrays and index-based dispatch.

### Added

#### Core Types (`rteffects/core`)
- `RtError` structured error type with `kind`, `msg`, `cause` chain, `stackTrace`,
  and `children` (for `AggregateError`)
- `RtErrorKind`: `Timeout`, `Cancelled`, `ExceptionRaised`, `ForeignError`,
  `AggregateError`, `Contradiction`, `Incomplete`
- Error constructors: `cancelledError`, `timeoutError`, `exceptionError`,
  `foreignError`, `aggregateError`, `withCause`, `rootCause`
- `Result[T]` tagged union with `isOk`, `ok`, `err`
- `TaskId`, `TypedTaskId[T]`, `Unit`, `IoInterest`

#### Belnap Semantics (`rteffects/semantics`)
- `TruthValue` enum forming a De Morgan bilattice with two orderings
  (information order and truth order)
- Lattice operations: `join` (LUB), `meet` (GLB), `negate`, `leqI`
- `Eval[T]` 4-valued computation result with `truth`, `value`, `error`
- `Eval` constructors: `evalTrue`, `evalFalse`, `evalBoth`, `evalNeither`
- `Eval` combinators: `map`, `flatMap`
- `toResult` ACL collapse: `Eval[T]` → `Result[T]` (4-valued → 2-valued boundary)

#### Effect Algebra (`rteffects/algebra`)
- `Eff[T]` lazy effectful computation type
- Constructors: `pure[T]`, `fail[T]`
- Composition: `andThen[T,U]` (monadic bind), `map[T,U]` (functor map)
- Effect introduction: `perform[T](tag, payload)`
- Effect handling: `handle[T](eff, tag, handler)`
- `HandlerProc` type: `(payload, resume, abort) → void`

#### VM Types (`rteffects/vm/types`)
- `EffProgram` defunctionalized continuation table
- `EffOp` with kinds: `opPure`, `opFail`, `opBind`, `opMap`, `opPerform`, `opHandle`
- `ContId` continuation pointer (distinct int)
- `BoxedValue` type-erased variant: `bvNone`, `bvInt`, `bvStr`, `bvFloat`,
  `bvBool`, `bvRef`, `bvProgram`
- Box/unbox helpers for all primitive types

#### VM Engine (`rteffects/vm/engine`)
- `Engine` cooperative single-threaded effect interpreter
- `Frame` execution state with `contStack` return addresses
- `FrameState`: `fsReady`, `fsRunning`, `fsSuspended`, `fsDone`
- `interpret[T](eff, budget)` → `Eval[T]` (4-valued result)
- `run[T](eff, budget)` → `Result[T]` (2-valued collapse)
- Fast-path optimization: trivial `opPure`/`opFail` bypass Engine overhead entirely
- Inline `bvProgram` resolution avoids frame creation for simple `andThen` chains
- `seq[Frame]` + `readyHead` index replace `Table[int, Frame]` (ADR-006)
- `when defined(rteffectsDebug)`: transition history tracking

#### Async Resume API (`rteffects/vm/engine`)
- `resumeFrame(engine, frameId, value)` — resume suspended frame from external callback
- `abortFrame(engine, frameId, error)` — abort suspended frame with error
- `hasSuspended(engine)` — check for frames waiting on async I/O
- `allDone(engine)` — termination condition for event loops

#### Standard Handlers (`rteffects/handlers`)
- Effect tags: `httpGetTag`, `httpPostTag`, `fileReadTag`, `fileWriteTag`
- Typed perform wrappers: `performHttpGet`, `performHttpPost`, `performFileRead`,
  `performFileWrite`
- Sync handlers (blocking, `std/httpclient`): `syncHttpGetHandler`,
  `syncHttpPostHandler`, `syncFileReadHandler`, `syncFileWriteHandler`
- Mock handlers (URL/path substring match): `mockHttpGetHandler`, `mockFileReadHandler`
- Deferred handlers (frame suspends for async): `deferredHttpGetHandler`,
  `deferredHttpPostHandler`, `deferredFileReadHandler`
- `HandlerEntry` type pairing `tag` + `impl`

#### Convenience Re-export (`rteffects`)
- `import rteffects` re-exports: `core`, `vm/types`, `algebra`, `vm/engine`, `handlers`

#### Examples
- ex01–ex08: Basic API (pure, chaining, map, errors, effects, handler composition,
  Belnap semantics, runner ACL)
- ex09: **Speculative execution** — run multiple strategies, detect contradictions
  via `join(tvTrue, tvFalse) = tvBoth`
- ex10: **Policy engine** — Allow/Deny rules, `tvBoth` = conflict escalation
- ex11: **Sensor fusion** — multi-source data with `leqI` information ordering
  and `meet` for common knowledge
- ex12: **Fault-tolerant pipeline** — partial ETL results preserved through
  `tvBoth` propagation in `flatMap` chains
- ex13: **Standard handlers** — mock HTTP/file, composition patterns
- ex14: **Async I/O** — deferred handlers + `resumeFrame`/`abortFrame`, concurrent frames
- ex15: **Validation aggregation** — `join` accumulates all evidence vs `meet`
  finds consensus
- ex16: **Knowledge lattice** — monotone fact accumulation, `negate(tvBoth) = tvBoth`
  (contradiction as fixed point)

#### Tests
- `t_core`: 28 tests — error types, constructors, formatting
- `t_semantics`: 36 tests — lattice properties (commutativity, associativity,
  idempotency, absorption, ordering)
- `t_eval`: 20 tests — `Eval[T]` constructors, `map`, `flatMap`, `toResult`
- `t_algebra`: 18 tests — `Eff[T]` program construction, type boxing
- `t_vm_types`: 18 tests — `BoxedValue`, `EffOp`, `ContId`, `EffectTag`
- `t_engine`: 38 tests — interpretation, frame lifecycle, type support,
  budget exhaustion, exception handling
- `t_engine_properties`: 9 tests — frame termination, handler resume/abort,
  mock matching, `allDone` invariant
- `t_handlers`: 9 tests — typed wrappers, mock matching, deferred suspension,
  composition
- `t_async_resume`: 4 tests — suspend, resume, abort, concurrent frames

**Total: 180 tests, 16 runnable examples**

#### Documentation
- API reference covering all four tiers
- Getting started guide with tier table and examples
- Patterns guide: handler composition, error handling, testing, standard handlers,
  async resume
- RFC-0001: Architecture overview
- ADR-001: Belnap 4-valued semantics
- ADR-002: State machine VM with defunctionalized continuation table
- ADR-003: Algebraic effects (perform/handle)
- ADR-004: 3-tier API visibility
- ADR-005: Module boundaries from bounded context analysis
- ADR-006: VM performance optimization (8.6×–33× speedup over v1)
- ADR-007: Standard effect handlers for common I/O operations
- ADR-008: Async resume API for deferred effect handlers

### Changed

- Architecture: CPS callback chains → defunctionalized continuation table
- Error model: 2-valued `Result[T]` → 4-valued `Eval[T]` with `toResult` collapse
- Effect system: hardcoded effects → algebraic `perform`/`handle`
- VM state management: `actor-state-machine` dependency → lightweight enum (ADR-006)
- Minimum Nim version: 2.0.0 → 2.2.8

### Removed

- v1 CPS-based runtime (`runtime.nim`, `types.nim`, `nursery.nim`, etc.)
- v1 examples
- `actor-state-machine` external dependency (replaced by inline enum, ADR-006)
- `egison-patterns` transitive dependency

[0.1.0]: https://github.com/jasagiri/nim-rteffects/releases/tag/v0.1.0
