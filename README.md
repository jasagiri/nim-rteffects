# RTEffects

A runtime effects library for Nim with algebraic effects, 4-valued Belnap
evaluation semantics, and a state machine VM.

## Requirements

- Nim >= 2.2.8
- [actor-state-machine](https://github.com/jasagiri/actor-state-machine) (sibling project)
- [egison-patterns](https://github.com/jasagiri/egison-patterns) (transitive dependency)

## Architecture

RTEffects v2 replaces v1's CPS callback architecture with:

1. **Belnap 4-valued semantics** — `TruthValue {tvTrue, tvFalse, tvBoth, tvNeither}`
   forming a De Morgan bilattice, enabling representation of contradictory and
   undetermined evaluation states.

2. **Algebraic effects** — `perform`/`handle` as the primary user API.
   Effects are identified by `EffectTag` and handled by composable handlers.

3. **State machine VM** — A defunctionalized continuation table (`EffProgram`)
   interpreted by a frame-based engine with `StateMachine[FrameState, FrameEvent]`
   lifecycle management.

### 3-Tier API Visibility

```
Tier 1 (App developer):  Eff[T], pure, andThen, map, perform, handle
Tier 2 (Handler author): + TruthValue, Eval[T], BoxedValue, resume/abort
Tier 3 (Runner):         run() → Result[T]  (the only 2-valued boundary)
Standard handlers:       handlers module (HTTP, File I/O, mock, deferred)
```

## Quick Start

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# Pure computation
let result = run[int](pure[int](42))
assert result.isOk
assert result.ok == 42

# Chained computation (monadic bind)
let eff = pure[int](1)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 10))
let result2 = run[int](eff)
assert result2.isOk
assert result2.ok == 20

# Effect handling
let tag = EffectTag("double")
let body = perform[int](tag, boxInt(21))
let handled = body.handle(tag, proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  resume(boxInt(unboxInt(payload) * 2))
)
let result3 = run[int](handled)
assert result3.isOk
assert result3.ok == 42
```

## Module Structure

```
src/rteffects/
├── core.nim          # RtError, Result[T], TaskId (shared kernel)
├── semantics.nim     # TruthValue, Eval[T], Belnap lattice operations
├── algebra.nim       # Eff[T], pure, andThen, map, perform, handle
├── handlers.nim      # Standard effect tags (HTTP, File), sync/mock/deferred handlers
└── vm/
    ├── types.nim     # EffOp, EffProgram, ContId, BoxedValue, EffectTag
    └── engine.nim    # Frame, Engine, interpret, run, resumeFrame, abortFrame
```

## Core Types

### Effect Algebra (Tier 1)

- `Eff[T]` — A description of an effectful computation producing `T`. Lazy.
- `EffectTag` — Distinct string identifying an effect for handler dispatch.
- `BoxedValue` — Type-erased value (variant: int, string, float, bool, ref, program).

### Evaluation Semantics (Tier 2)

- `TruthValue` — `{tvTrue, tvFalse, tvBoth, tvNeither}` with lattice operations.
- `Eval[T]` — Computation result with 4-valued truth, value, and error.
- `join`, `meet`, `negate`, `leqI` — Belnap lattice operations.

### Standard Handlers

- `handlers` module — Ready-to-use effect tags and handlers for HTTP and file I/O.
- `performHttpGet`, `performHttpPost`, `performFileRead`, `performFileWrite` — Typed perform wrappers.
- `syncHttpGetHandler`, `syncHttpPostHandler`, `syncFileReadHandler`, `syncFileWriteHandler` — Blocking handlers.
- `mockHttpGetHandler`, `mockFileReadHandler` — URL/path substring matching for tests.
- `deferredHttpGetHandler`, `deferredHttpPostHandler`, `deferredFileReadHandler` — Suspend frame for async I/O.

### Runner (Tier 3)

- `run[T](eff): Result[T]` — Interpret and collapse to 2-valued result.
- `interpret[T](eff): Eval[T]` — Interpret without collapsing.

### Async Resume API (Engine)

- `resumeFrame(engine, frameId, value)` — Resume a suspended frame with a value.
- `abortFrame(engine, frameId, error)` — Abort a suspended frame with an error.
- `hasSuspended(engine): bool` — Check if any frames are waiting for async I/O.
- `allDone(engine): bool` — Check if all frames are complete.

## Running Tests

```bash
# Individual test files
nim c -r tests/t_engine.nim
nim c -r tests/t_semantics.nim
nim c -r tests/t_eval.nim
nim c -r tests/t_vm_types.nim
nim c -r tests/t_algebra.nim
nim c -r tests/t_core.nim
nim c -r tests/t_handlers.nim
nim c -r tests/t_async_resume.nim
nim c -r tests/t_engine_properties.nim
```

## Design Documents

- [RFC-0001: Overview](docs/rfcs/RFC-0001-overview.md)
- [ADR-001: Belnap 4-valued Semantics](docs/rfcs/ADR-001-belnap-semantics.md)
- [ADR-002: State Machine VM](docs/rfcs/ADR-002-state-machine-vm.md)
- [ADR-003: Algebraic Effects](docs/rfcs/ADR-003-algebraic-effects.md)
- [ADR-004: 3-Tier API Visibility](docs/rfcs/ADR-004-layered-api.md)
- [ADR-005: Module Boundaries](docs/rfcs/ADR-005-module-boundaries.md)

## License

Apache-2.0
