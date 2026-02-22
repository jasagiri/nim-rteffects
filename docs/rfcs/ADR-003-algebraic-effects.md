# ADR-003: Algebraic Effects (perform/handle) as Primary API

## Status

Accepted

## Context

RTEffects v1 provides `spawn`, `join`, `cancel`, `sleep` as built-in runtime
operations. Users cannot define custom effects. Error handling uses
`recover`/`catchError` rather than structured handlers with resumption control.

An algebraic effects system provides:
1. **Effect declaration**: Define what operations are available
2. **perform**: Request an effect (delegate to handler)
3. **handle**: Install a handler that interprets effects
4. **Resumption control**: Handler controls whether to resume, abort, or suspend

This is strictly more expressive than the current API -- `spawn`, `sleep`, etc.
become built-in effect handlers rather than hardcoded operations.

## Decision

Introduce algebraic effects as the primary user-facing API.

### Effect Declaration

Effects are identified by `EffectTag` -- a distinct string naming the effect:

```nim
type
  EffectTag* = distinct string

# Built-in effect tags
const
  effSpawn* = EffectTag("spawn")
  effSleep* = EffectTag("sleep")
  effCancel* = EffectTag("cancel")

# User-defined effect tags
const
  effLog* = EffectTag("log")
  effFileRead* = EffectTag("file.read")
```

### BoxedValue

All payloads and handler values use `BoxedValue`, a type-erased sum type:

```nim
type
  BoxedValueKind* = enum
    bvNone, bvInt, bvStr, bvFloat, bvBool, bvRef, bvProgram

  BoxedValue* = object
    case kind*: BoxedValueKind
    of bvNone: discard
    of bvInt: intVal*: int
    of bvStr: strVal*: string
    of bvFloat: floatVal*: float
    of bvBool: boolVal*: bool
    of bvRef: refVal*: RootRef
    of bvProgram:
      innerProgram*: EffProgram
      innerUnboxer*: proc(v: BoxedValue): BoxedValue {.gcsafe.}
```

Constructors: `boxInt(v)`, `boxStr(v)`, `boxFloat(v)`, `boxBool(v)`,
`boxRef(v)`, `boxNone()`.

Extractors: `unboxInt(v)`, `unboxStr(v)`, `unboxFloat(v)`, `unboxBool(v)`.

### perform

`perform` creates an `opPerform` entry in the EffProgram. At runtime, the VM
walks the handler stack (innermost first) looking for a matching tag:

```nim
proc perform*[T](tag: EffectTag, payload: BoxedValue = boxNone()): Eff[T]
```

### handle

`handle` wraps a computation with a handler for a specific effect:

```nim
proc handle*[T](eff: Eff[T], tag: EffectTag, h: HandlerProc): Eff[T]
```

### HandlerProc

Handlers receive the payload and two inline closures -- `resume` and `abort` --
directly. There is no `Resumption` object:

```nim
type
  HandlerProc* = proc(payload: BoxedValue,
                       resume: proc(v: BoxedValue) {.gcsafe.},
                       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}
```

The error type is `RtError` (defined in `core.nim`).

Handler authors see `TruthValue` through their choice of which closure to call:

| Action                           | TruthValue  | Meaning                        |
|----------------------------------|-------------|--------------------------------|
| Call `resume(v)`                 | tvTrue      | Continue computation with `v`  |
| Call `abort(e)`                  | tvFalse     | Fail computation with `e`      |
| Call neither                     | tvNeither   | Suspend (implicit)             |
| Future: fork                     | tvBoth      | Speculative execution          |

Suspension happens automatically when neither `resume` nor `abort` is called.
There is no explicit `suspend()` proc.

### Handler Composition

Handlers compose by nesting. Inner handlers match first:

```nim
let task = handle(
  handle(
    myComputation(),
    effLog, logHandler
  ),
  effFileRead, fileHandler
)
```

When `myComputation` performs `effLog`, the inner handler matches.
When it performs `effFileRead`, the VM walks past the log handler to the file
handler.

Internally, the VM walks `frame.handlers` from last to first (innermost first).

Unhandled effects produce `RtError(kind: ForeignError, msg: "unhandled effect: " & $tag)`.

## Rationale

### vs. Hardcoded operations (current)

Hardcoded operations cannot be composed, mocked for testing, or extended by users.
With algebraic effects, `sleep` becomes a handler that can be replaced with
a test double:

```nim
# Production
let result = run(handle(myTask(), effSleep, realSleepHandler))

# Testing
let result = run(handle(myTask(), effSleep, instantSleepHandler))
```

### vs. Typeclass/interface-based effects

Typeclasses require all effects to be known at compile time and passed as
parameters. Algebraic effects with dynamic dispatch (handler stack) allow
effects to be installed at any nesting level without threading parameters.

### vs. Monad transformers

Monad transformers compose poorly (order matters, lifting is tedious). Algebraic
effect handlers compose naturally by nesting, with no lifting required.

## Consequences

### Positive

- All effects (including built-ins) are user-extensible and composable
- Handlers enable dependency injection for testing
- Inline closures give handler authors full control over computation flow
- Handler authors can express 4-valued evaluation states through resume/abort/neither

### Negative

- Dynamic handler dispatch (tag matching) has runtime overhead vs. direct calls
- Handler stack walking is O(n) in handler depth per perform
- Type safety is partially lost inside handlers (BoxedValue boxing)

### Neutral

- Built-in effects (spawn, sleep) have the same API as user-defined effects
- The `.rt.` macro is a planned future feature to hide handler plumbing for app developers

## Examples

### App developer (does not see 4-valued logic)

```nim
let effFileRead = EffectTag("file.read")
let effLog = EffectTag("log")

# Build a computation that performs effects
let fetchConfig =
  perform[string](effFileRead, boxStr("config.json"))
    .andThen(proc(raw: string): Eff[string] =
      perform[string](effLog, boxStr("Config loaded"))
        .andThen(proc(_: string): Eff[string] =
          pure(raw)  # return the raw config
        )
    )

# Install handlers and run
let fileHandler: HandlerProc = proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  let path = unboxStr(payload)
  let content = readFile(path)
  resume(boxStr(content))

let logHandler: HandlerProc = proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  echo unboxStr(payload)
  resume(boxNone())

let result = run(
  handle(handle(fetchConfig,
    effFileRead, fileHandler),
    effLog, logHandler)
)
# result: Result[string]
```

### Handler author (sees 4-valued states via resume/abort/neither)

```nim
let effHttpGet = EffectTag("http.get")
let effCache = EffectTag("cache.get")

# Retry handler: resume on success, abort after max retries
let retryHandler: HandlerProc = proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  let url = unboxStr(payload)
  for attempt in 0..<3:
    try:
      let resp = httpGet(url)
      resume(boxStr(resp))  # -> tvTrue
      return
    except:
      discard
  abort(RtError(kind: ForeignError, msg: "max retries"))  # -> tvFalse

# Caching handler: resume on hit, suspend on miss (implicit)
let cachingHandler: HandlerProc = proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  let key = unboxStr(payload)
  if cache.hasKey(key):
    resume(boxStr(cache[key]))  # -> tvTrue (from cache)
  # else: neither resume nor abort called -> tvNeither (suspended)
```
