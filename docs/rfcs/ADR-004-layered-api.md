# ADR-004: 3-Tier API Visibility

## Status

Accepted

## Context

The 4-valued Belnap semantics (ADR-001) and algebraic effects (ADR-003) create
a powerful but complex system. Not all users need to understand all layers.

Three distinct user personas interact with the effects system:

1. **App developers**: Compose effects declaratively. Want simplicity.
2. **Handler authors**: Interpret effects, control computation flow. Need power.
3. **Main/runner**: Execute fully-handled computations. Want a clean exit.

Exposing 4-valued logic to all users would add unnecessary complexity.
Hiding it from handler authors would cripple their ability to implement
suspend, fork, and resolve operations.

## Decision

Implement a 3-tier visibility model where each tier sees exactly what it needs.

### Tier 1: App Developer API

**Sees**: `Eff[T]`, `perform`, `handle`, `pure`, `andThen`, `map`, `BoxedValue`
**Does NOT see**: `TruthValue`, `Eval[T]`, `Frame`, `EffProgram`, `Engine`

```nim
import rteffects/algebra

let tag = EffectTag("readConfig")
let eff = perform[string](tag, boxStr("key"))
  .andThen(proc(raw: string): Eff[Config] {.gcsafe.} =
    pure(parseConfig(raw))
  )
```

The builder API (`pure`, `andThen`, `perform`, `handle`, `map`) is the primary
interface. A `.rt.` macro for syntactic sugar is planned but not yet implemented.

Effect declaration is by convention (EffectTag constants), not by import.

### Tier 2: Handler Author API

**Sees**: Everything in Tier 1 + `TruthValue`, `Eval[T]`, `BoxedValue` constructors
**Does NOT see**: `Frame`, `EffProgram`, `ContId`, `Engine` internals

```nim
import rteffects/[algebra, semantics]
import rteffects/vm/types  # for BoxedValue constructors

proc myHandler(payload: BoxedValue,
               resume: proc(v: BoxedValue) {.gcsafe.},
               abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  # Choose resumption strategy — implicitly determines TruthValue
  resume(boxStr(value))   # → tvTrue
  # or
  abort(RtError(kind: ForeignError, msg: "failed"))  # → tvFalse
  # or
  discard  # call neither → tvNeither (implicit suspend)
```

Handler authors import `semantics` to access `TruthValue` and `Eval[T]`
operations (join, meet, negate, leqI) for composing evaluation results.

### Tier 3: Runner API

**Sees**: `run()` returning `Result[T]`
**Does NOT see**: Any internal state

```nim
import rteffects/vm/engine  # run() lives in engine.nim

let result = run[int](handledComputation)
# result: Result[int] — the only 2-valued boundary
if result.isOk:
  echo result.ok
else:
  echo result.err
```

Note: `run()` and `interpret()` are in `vm/engine.nim`, not a separate
`runner.nim` module. The runner ACL is co-located with the VM engine.

### Import Graph

```
Tier 1 (app developer):
  import rteffects/algebra     # Eff[T], pure, andThen, perform, handle
  import rteffects/vm/types    # BoxedValue, EffectTag constructors

Tier 2 (handler author):
  import rteffects/algebra     # Tier 1 API
  import rteffects/semantics   # TruthValue, Eval[T], lattice ops
  import rteffects/vm/types    # BoxedValue constructors

Tier 3 (runner):
  import rteffects/vm/engine   # run(), interpret() → Result[T] / Eval[T]

Convenience:
  import rteffects             # Re-exports algebra + engine (Tiers 1+3)
```

### What each tier CAN and CANNOT do

| Capability | App Dev | Handler | Runner |
|-----------|---------|---------|--------|
| Compose effects (`andThen`) | Yes | Yes | — |
| Perform effects | Yes | Yes | — |
| Install handlers | Yes | Yes | — |
| Access TruthValue | No | Yes | No |
| Resume/abort (closures) | No | Yes | No |
| Inspect Eval[T] | No | Yes | No |
| Run to Result[T] | — | — | Yes |
| Access VM internals | No | No | No |

## Rationale

### vs. Flat API (everything visible)

Exposing `TruthValue`, `Eval[T]`, `Frame`, and `Engine` to all users would
overwhelm app developers who just want to compose effects. It also makes
backward-incompatible changes to internals harder, as users may depend on them.

### vs. 2-tier (user / internal)

A 2-tier model would either:
- Hide TruthValue from handler authors (crippling their power), or
- Expose VM internals to handler authors (leaking implementation)

The 3-tier model puts handler authors in a principled middle ground.

### vs. Capability-based access control

We could enforce tiers via Nim's module system (private fields, separate packages).
However, Nim's export system (`*`) is coarse. The tier model is enforced by
convention (which modules you import) rather than by compiler restriction.
This is pragmatic — Nim's type system provides some protection via opaque types.

## Consequences

### Positive

- App developers see a simple API (~6 procs)
- Handler authors have full power without VM internals leaking
- Runner boundary is a clean 2-valued exit
- Each tier can evolve independently

### Negative

- Tier boundaries enforced by convention, not compiler
- Documentation must clearly communicate which tier each API belongs to
- Handler authors must understand 4-valued logic (learning curve)

### Neutral

- The re-export in `rteffects.nim` provides a convenient default (Tier 1 + 3)
- Advanced users can import individual modules for finer control
