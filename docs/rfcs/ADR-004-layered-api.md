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

**Sees**: `Eff[T]`, `perform`, `handle`, `pure`, `andThen`, `map`
**Does NOT see**: `TruthValue`, `Eval[T]`, `Resumption`, `Frame`, `EffProgram`

```nim
import rteffects/algebra

proc myTask(): Eff[int] {.rt.} =
  let x = perform ReadConfig("key")
  let y = perform Compute(x)
  pure(y)
```

The `.rt.` macro provides syntactic sugar. Without it, the builder API
(`pure`, `andThen`, `perform`) is still usable directly.

Effect declaration is by convention (EffectTag constants), not by import.

### Tier 2: Handler Author API

**Sees**: Everything in Tier 1 + `TruthValue`, `Eval[T]`, `Resumption`
**Does NOT see**: `Frame`, `EffProgram`, `ContId`, `Engine` internals

```nim
import rteffects/[algebra, semantics]
import rteffects/vm/types  # for Resumption

proc myHandler(payload: RootRef, resume: Resumption) =
  # Can inspect TruthValue, choose resumption strategy
  resume.resume(box(value))   # → tvTrue
  # or
  resume.abort(error)         # → tvFalse
  # or
  resume.suspend()            # → tvNeither
```

Handler authors import `semantics` to access `TruthValue` and `Eval[T]`
operations (join, meet, negate) for composing evaluation results.

### Tier 3: Runner API

**Sees**: `run()` returning `Result[T]`
**Does NOT see**: Any internal state

```nim
import rteffects/runner

let result = run(handledComputation)
# result: Result[T] — the only 2-valued boundary
if result.isOk:
  echo result.ok
else:
  echo result.err
```

### Import Graph

```
Tier 1 (app developer):
  import rteffects/algebra     # Eff[T], pure, andThen, perform, handle

Tier 2 (handler author):
  import rteffects/algebra     # Tier 1 API
  import rteffects/semantics   # TruthValue, Eval[T], lattice ops
  import rteffects/vm/types    # Resumption

Tier 3 (runner):
  import rteffects/runner      # run() → Result[T]

Convenience:
  import rteffects             # Re-exports algebra + runner (Tiers 1+3)
```

### What each tier CAN and CANNOT do

| Capability | App Dev | Handler | Runner |
|-----------|---------|---------|--------|
| Compose effects (`andThen`) | Yes | Yes | — |
| Perform effects | Yes | Yes | — |
| Install handlers | Yes | Yes | — |
| Access TruthValue | No | Yes | No |
| Resume/abort/suspend | No | Yes | No |
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
