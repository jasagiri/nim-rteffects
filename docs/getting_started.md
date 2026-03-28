# Getting Started with RTEffects

RTEffects v2 is an algebraic effects system for Nim with Belnap 4-valued logic. It lets you describe effectful computations as first-class values, compose them safely, and control their semantics through handlers.

## Requirements

- Nim >= 2.2.8
- No external dependencies

## API Tiers

The library is organised into three tiers:

| Tier | Who uses it | Imports |
|------|-------------|---------|
| **Tier 1** — App developer | `Eff[T]`, `pure`, `fail`, `andThen`, `map`, `run` | `rteffects/algebra`, `rteffects/vm/engine` |
| **Tier 2** — Handler author | `perform`, `handle`, `EffectTag`, `BoxedValue`, `box*`, `unbox*` | `rteffects/algebra`, `rteffects/vm/types` |
| **Tier 3** — Semantics | `TruthValue`, `Eval[T]`, `interpret` | `rteffects/semantics`, `rteffects/vm/engine` |
| **Standard handlers** | `performHttpGet`, `HttpPostPayload`, `syncHttpGetHandler`, ... | `rteffects/handlers` (or `rteffects`) |

Most application code only needs Tier 1. For HTTP/file I/O effects, `import rteffects` gives access to all tiers including the standard handlers.

## Basic Concepts

### Eff[T]

`Eff[T]` is a description of an effectful computation that produces a value of type `T`. Like a recipe, it does nothing on its own — you hand it to `run` to execute it.

```nim
import rteffects/algebra
import rteffects/vm/engine

# Lift a plain value into Eff
let greeting: Eff[string] = pure("hello")

# Run the computation
let result = run(greeting)
if result.isOk:
  echo result.ok   # hello
```

### pure and fail

`pure` wraps a value in a successful `Eff`. `fail` creates an `Eff` that carries an `RtError`.

```nim
import rteffects/algebra
import rteffects/vm/engine
import rteffects/core

# Success
let ok = pure(42)

# Failure
let err = fail[int](RtError(kind: Contradiction, msg: "bad state"))

# run returns Result[T]
let r = run(ok)
echo r.isOk   # true
echo r.ok     # 42

let e = run(err)
echo e.isOk   # false
echo e.err.msg
```

### Result[T]

`run` returns `Result[T]`, a simple discriminated record:

```nim
type Result*[T] = object
  isOk*: bool
  ok*: T
  err*: RtError
```

`RtError` carries a `kind` (`Timeout`, `Cancelled`, `ExceptionRaised`, `ForeignError`, `AggregateError`, `Contradiction`, `Incomplete`), a `msg`, an optional `cause`, and a `stackTrace`.

## Chaining Computations

### andThen

`andThen` sequences two computations. The second receives the value produced by the first.

All closures passed to `andThen` must carry the `{.gcsafe.}` pragma.

```nim
import rteffects/algebra
import rteffects/vm/engine

proc readConfig(): Eff[string] =
  pure("/etc/app/config.toml")

proc loadFile(path: string): Eff[int] =
  # pretend we read a line count
  pure(path.len)

let pipeline =
  readConfig().andThen(proc(path: string): Eff[int] {.gcsafe.} =
    loadFile(path)
  )

let result = run(pipeline)
echo result.ok   # length of the config path string
```

### map

`map` transforms the produced value without introducing a new effect. It is equivalent to `andThen` followed by `pure`.

```nim
import rteffects/algebra
import rteffects/vm/engine

let doubled =
  pure(21).map(proc(n: int): int {.gcsafe.} = n * 2)

echo run(doubled).ok   # 42
```

Chain multiple `map` and `andThen` calls to build longer pipelines:

```nim
let result =
  pure(10)
    .map(proc(n: int): int {.gcsafe.} = n + 5)
    .map(proc(n: int): string {.gcsafe.} = "value=" & $n)
    .andThen(proc(s: string): Eff[string] {.gcsafe.} =
      pure(s & "!")
    )

echo run(result).ok   # value=15!
```

## Error Handling

Use `fail` to signal an error at any point. Once a `fail` enters the pipeline, subsequent `andThen` and `map` steps are skipped.

```nim
import rteffects/algebra
import rteffects/vm/engine
import rteffects/core

proc divide(a, b: int): Eff[int] =
  if b == 0:
    fail[int](RtError(kind: Contradiction, msg: "division by zero"))
  else:
    pure(a div b)

# Error propagates through map — the map body is never called
let result =
  divide(10, 0).map(proc(n: int): string {.gcsafe.} = "got " & $n)

let r = run(result)
echo r.isOk        # false
echo r.err.msg     # division by zero
```

The `budget` parameter of `run` sets a step limit. Exceeding it yields a `Timeout` error:

```nim
let r = run(myEff, budget = 500)
if not r.isOk and r.err.kind == Timeout:
  echo "computation ran out of steps (budget exhausted)"
```

## Algebraic Effects

Algebraic effects let a computation declare that it needs something from the outside world — logging, state, I/O — without hardcoding how that need is satisfied. The computation calls `perform`; a `handle` wrapper supplies the answer.

### EffectTag and BoxedValue

`EffectTag` is a distinct string that names an effect. `BoxedValue` is a type-erased container used to pass data into and out of effect operations. As of v2.1.0, it supports primitive types and user-defined `ref object` types.

```nim
import rteffects/vm/types

let tag = EffectTag("double")
let bv = boxInt(42)
echo unboxInt(bv)    # 42

# Supporting ref objects
type User = ref object of RootObj
  name: string
let userBv = boxRef(User(name: "Bob"))
let user = cast[User](unboxRef(userBv))
```

### perform and handle

`perform` suspends the current computation and emits an effect to the nearest matching handler. `handle` installs a handler for one `EffectTag`. The handler receives the payload and `resume`/`abort` callbacks.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/engine
import rteffects/vm/types

let doubleTag = EffectTag("double")

# Request the "double" effect with payload 21
let body = perform[int](doubleTag, boxInt(21))

# Attach a handler that doubles the payload
let handled = body.handle(doubleTag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    let n = unboxInt(payload)
    resume(boxInt(n * 2))
)

let r = run[int](handled)
echo r.ok   # 42
```

Different handlers can give the same computation entirely different semantics — the same `perform` can be handled by a production handler, a mock handler for testing, or an aborting handler that validates input.

## Tier 3: Belnap Semantics

For advanced use-cases you can inspect the 4-valued truth of a result with `interpret`:

```nim
import rteffects/algebra
import rteffects/vm/engine
import rteffects/semantics

let eval = interpret[int](pure[int](42))
case eval.truth
of tvTrue:    echo "definite success"
of tvFalse:   echo "definite failure"
of tvBoth:    echo "both success and failure (contradiction)"
of tvNeither: echo "no information yet (incomplete)"
```

`Eval[T]` carries a `truth: TruthValue`, an `value: Option[T]`, and an `error: Option[RtError]`.

## Standard Handlers

The `handlers` module provides ready-to-use effect tags and handler implementations for HTTP and file I/O. Three variants are available per effect:

- **Sync** — Blocking, for simple scripts (`syncHttpGetHandler`, `syncFileReadHandler`, ...)
- **Mock** — URL/path substring matching, for testing (`mockHttpGetHandler`, `mockFileReadHandler`)
- **Deferred** — Suspends the frame, for async I/O with `Engine` (`deferredHttpGetHandler`, ...)

```nim
import rteffects

# Perform an HTTP GET with a mock handler (for testing)
let eff = performHttpGet("https://api.example.com/data")
let handled = handle[string](eff, httpGetTag,
  mockHttpGetHandler(@[("api.example.com", "{\"ok\":true}")]).impl)
let result = run[string](handled)
echo result.ok  # {"ok":true}
```

For async patterns using deferred handlers, see [Patterns — Async Resume](patterns.md#6-async-resume-pattern).

## Next Steps

- [API Reference](api_reference.md) — complete type and proc documentation
- [Examples](../examples/) — runnable programs covering common patterns
- [Patterns](patterns.md) — composing handlers, testing with effect stubs, error recovery
