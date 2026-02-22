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
4. **Resumption**: Handler controls whether to resume, abort, or suspend

This is strictly more expressive than the current API — `spawn`, `sleep`, etc.
become built-in effect handlers rather than hardcoded operations.

## Decision

Introduce algebraic effects as the primary user-facing API.

### Effect Declaration

Effects are identified by `EffectTag` — a distinct string naming the effect:

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

### perform

`perform` creates an `opPerform` entry in the EffProgram. At runtime, the VM
walks the handler stack (innermost first) looking for a matching tag:

```nim
proc perform*[T](tag: EffectTag, payload: RootRef = nil): Eff[T]
```

App developer usage:
```nim
proc myTask(): Eff[string] {.rt.} =
  let data = perform FileRead(path)  # .rt. macro expands this
  let parsed = parse(data)
  pure(parsed)
```

### handle

`handle` wraps a computation with a handler for a specific effect:

```nim
proc handle*[T](body: Eff[T], tag: EffectTag, h: HandlerProc): Eff[T]

type
  HandlerProc* = proc(payload: RootRef, resume: Resumption): RootRef {.gcsafe.}
```

Handler author usage:
```nim
let handled = handle(myTask(), effFileRead, proc(payload, resume) =
  let path = unbox[string](payload)
  let content = readFile(path)
  resume.resume(box(content))  # resume computation with file content
)
```

### Resumption

The handler receives a `Resumption` that controls computation flow:

```nim
type
  Resumption* = object
    resume*: proc(value: RootRef) {.gcsafe.}   ## Continue with value → T
    abort*: proc(error: EffError) {.gcsafe.}    ## Fail computation → F
    suspend*: proc() {.gcsafe.}                 ## Pause computation → N
```

Handler authors see `TruthValue` through their choice of resumption operation:
- `resume(v)` → evaluation becomes tvTrue
- `abort(e)` → evaluation becomes tvFalse
- `suspend()` → evaluation becomes tvNeither

Future extension for speculative execution:
- `fork(branches)` → evaluation may become tvBoth at merge

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
When it performs `effFileRead`, the VM walks past the log handler to the file handler.

Unhandled effects produce `evalFalse(unhandledEffectError(tag))`.

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
- Resumption gives handler authors full control over computation flow
- Handler authors can see and operate on 4-valued evaluation states

### Negative

- Dynamic handler dispatch (tag matching) has runtime overhead vs. direct calls
- Handler stack walking is O(n) in handler depth per perform
- Type safety is partially lost inside handlers (RootRef boxing)

### Neutral

- The `.rt.` macro hides the complexity for app developers
- Built-in effects (spawn, sleep) have the same API as user-defined effects

## Examples

### App developer (does not see 4-valued logic)

```nim
proc fetchConfig(): Eff[Config] {.rt.} =
  let raw = perform FileRead("config.json")
  perform Log("Config loaded")
  let config = parseConfig(raw)
  pure(config)

# Install handlers and run
let result = run(
  handle(handle(fetchConfig(),
    effFileRead, fileSystemHandler),
    effLog, stdoutLogHandler)
)
# result: Result[Config]
```

### Handler author (sees 4-valued states via Resumption)

```nim
proc retryHandler(payload: RootRef, resume: Resumption) =
  let req = unbox[HttpRequest](payload)
  for attempt in 0..<3:
    try:
      let resp = httpGet(req.url)
      resume.resume(box(resp))  # → tvTrue
      return
    except:
      discard
  resume.abort(EffError(kind: ekForeign, msg: "max retries"))  # → tvFalse

proc cachingHandler(payload: RootRef, resume: Resumption) =
  let key = unbox[string](payload)
  if cache.hasKey(key):
    resume.resume(box(cache[key]))  # → tvTrue (from cache)
  else:
    resume.suspend()  # → tvNeither (need async fetch)
```
