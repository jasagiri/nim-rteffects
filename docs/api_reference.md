# RTEffects v2 API Reference

This document covers the public API of RTEffects v2. The library is organized into four tiers based on audience. Most application code only needs Tier 1.

---

## Tier 1: App Developer API

Import paths: `rteffects/core`, `rteffects/algebra`

### `Eff[T]`

```nim
type Eff*[T] = ref object of EffBase
  boxer*:   proc(v: T): BoxedValue {.gcsafe.}
  unboxer*: proc(v: BoxedValue): T {.gcsafe.}
```

The primary computation type. Represents an effectful program that, when run, produces a value of type `T` or fails with an `RtError`. Values are composed with `andThen` and `map`; effects are introduced with `perform` and handled with `handle`.

---

### Constructors

#### `pure`

```nim
proc pure*[T](v: T): Eff[T]
```

Lifts a pure value into `Eff`. Equivalent to `return` in a monad. Never fails.

#### `fail`

```nim
proc fail*[T](e: RtError): Eff[T]
```

Creates an immediately-failing `Eff` carrying the given error.

---

### Composition

#### `andThen`

```nim
proc andThen*[T, U](eff: Eff[T], f: proc(v: T): Eff[U] {.gcsafe.}): Eff[U]
```

Sequences two effects. Calls `f` with the result of `eff` only if `eff` succeeds. Propagates failure without calling `f`.

#### `map`

```nim
proc map*[T, U](eff: Eff[T], f: proc(v: T): U {.gcsafe.}): Eff[U]
```

Transforms the success value of `eff` with a pure function `f`. Does not affect the error path.

---

### Runner

#### `run`

```nim
proc run*[T](eff: Eff[T], budget = 10000): Result[T] {.raises: [].}
```

Executes the effect program to completion and collapses the result to `Result[T]`. The `budget` parameter caps the number of VM reduction steps; exceed it and the result is an `Incomplete` error. Does not raise; all errors are captured in the returned `Result`.

---

### `Result[T]`

```nim
type Result*[T] = object
  isOk*: bool
  ok*:   T
  err*:  RtError
```

Tagged union returned by `run`. Check `isOk` before accessing `ok` or `err`.

---

### `RtError`

```nim
type RtError* = object
  kind*:       RtErrorKind
  msg*:        string
  cause*:      ref RtError    # optional chained cause
  stackTrace*: string         # optional capture
  children*:   seq[RtError]   # populated for AggregateError
```

Structured error value. Carried through the `Eff` monad without stack unwinding.

---

### `RtErrorKind`

```nim
type RtErrorKind* = enum
  Timeout
  Cancelled
  ExceptionRaised
  ForeignError
  AggregateError
  Contradiction   # tvBoth semantics: value and error both present
  Incomplete      # VM budget exhausted
```

Discriminant for `RtError`. Use in `case` expressions to route error handling.

---

### Error Constructors

Convenience constructors from `rteffects/core`:

```nim
proc cancelledError*(): RtError
```
Creates a `Cancelled` error.

```nim
proc timeoutError*(): RtError
```
Creates a `Timeout` error.

```nim
proc exceptionError*(msg: string): RtError
```
Creates an `ExceptionRaised` error with a message string.

```nim
proc exceptionError*(ex: ref Exception): RtError
```
Creates an `ExceptionRaised` error from a caught Nim exception.

```nim
proc foreignError*(msg: string): RtError
```
Creates a `ForeignError` for errors originating outside the effect system.

```nim
proc aggregateError*(errors: seq[RtError]): RtError
```
Creates an `AggregateError` bundling multiple failures. Populates `children`.

```nim
proc withCause*(e: RtError, cause: RtError): RtError
```
Returns a copy of `e` with `cause` chained into the `cause` field.

```nim
proc rootCause*(e: RtError): RtError
```
Follows the `cause` chain to its end and returns the originating error.

---

### Supporting Types

#### `TaskId` / `TypedTaskId[T]`

```nim
type TaskId*        = distinct int
type TypedTaskId*[T] = object
  id*: TaskId
const InvalidTaskId* = TaskId(-1)
```

Opaque handles for referencing tasks submitted to an `Engine`. `TypedTaskId[T]` carries the result type at the type level.

#### `Unit`

```nim
type Unit* = object
```

Represents the absence of a meaningful return value (analogous to `void`).

```nim
proc unit*(): Unit
```
Returns the single `Unit` value.

#### `IoInterest`

```nim
type IoInterest* = enum ioRead, ioWrite
```

Indicates the direction of interest when waiting on a file descriptor.

---

## Tier 2: Handler Author API

Import path: `rteffects/algebra`, `rteffects/vm/types`

Handler authors define named effects and provide implementations that intercept `perform` calls.

---

### `EffectTag`

```nim
type EffectTag* = distinct string
```

A string-typed discriminant that uniquely names an effect. By convention, use a fully-qualified identifier such as `EffectTag("mylib/console/print")` to avoid collisions across packages.

---

### `BoxedValue`

```nim
type BoxedValueKind* = enum
  bvNone, bvInt, bvStr, bvFloat, bvBool, bvRef, bvProgram

type BoxedValue* = object
  case kind*: BoxedValueKind
  of bvNone:    discard
  of bvInt:     intVal*:       int
  of bvStr:     strVal*:       string
  of bvFloat:   floatVal*:     float
  of bvBool:    boolVal*:      bool
  of bvRef:     refVal*:       RootRef
  of bvProgram: innerProgram*: EffProgram
                innerUnboxer*: proc(v: BoxedValue): BoxedValue {.gcsafe.}
```

A dynamically-typed value used to pass payloads through the VM without generics. Use the box/unbox helpers to convert.

---

### Box / Unbox Helpers

```nim
proc boxNone*():          BoxedValue {.raises: [].}
proc boxInt*(v: int):     BoxedValue {.raises: [].}
proc boxStr*(v: string):  BoxedValue {.raises: [].}
proc boxFloat*(v: float): BoxedValue {.raises: [].}
proc boxBool*(v: bool):   BoxedValue {.raises: [].}
proc boxRef*(v: RootRef): BoxedValue {.raises: [].}
```

Wrap a typed value into `BoxedValue`.

```nim
proc unboxInt*(v: BoxedValue):   int    {.raises: [].}
proc unboxStr*(v: BoxedValue):   string {.raises: [].}
proc unboxFloat*(v: BoxedValue): float  {.raises: [].}
proc unboxBool*(v: BoxedValue):  bool   {.raises: [].}
```

Extract the inner value. Behavior is undefined if `v.kind` does not match. Check `v.kind` before calling.

---

### `perform`

```nim
proc perform*[T](tag: EffectTag, payload: BoxedValue = boxNone()): Eff[T]
```

Introduces an effect into the computation. The VM suspends the current frame and dispatches to the nearest enclosing handler registered for `tag`. If no handler is found the effect propagates upward; if it reaches the top-level runner unhandled, `run` returns a `ForeignError`.

---

### `handle`

```nim
proc handle*[T](eff: Eff[T], tag: EffectTag, h: HandlerProc): Eff[T]
```

Installs handler `h` for the named effect `tag` within the dynamic extent of `eff`. Returns a new `Eff[T]` identical to `eff` but with the handler in scope.

---

### `HandlerProc`

```nim
type HandlerProc* = proc(
  payload: BoxedValue,
  resume:  proc(v: BoxedValue) {.gcsafe.},
  abort:   proc(e: RtError)    {.gcsafe.}
) {.gcsafe, closure.}
```

Signature for effect handler implementations.

- `payload` - the value passed to `perform`.
- `resume(v)` - call to continue the suspended computation with result value `v`.
- `abort(e)` - call to inject a failure into the suspended computation.

A handler must call exactly one of `resume` or `abort`, exactly once.

---

## Tier 3: Evaluation Semantics

Import path: `rteffects/semantics`

The semantics layer exposes a Belnap four-valued logic lattice for programs that must reason about both success and failure simultaneously (e.g., speculative execution, policy checking, or test oracles).

---

### `TruthValue`

```nim
type TruthValue* = enum
  tvTrue     # definite success
  tvFalse    # definite failure
  tvBoth     # over-determined: both success and failure observed
  tvNeither  # under-determined: no information yet
```

The four elements of the Belnap/Dunn bilattice FOUR. The lattice has two orderings:

- **Information order**: `tvNeither` < `tvTrue`, `tvFalse` < `tvBoth` (more information is higher).
- **Truth order**: `tvFalse` < `tvNeither`, `tvBoth` < `tvTrue` (more true is higher).

---

### Lattice Operations

```nim
proc join*(a, b: TruthValue): TruthValue {.raises: [].}
```
Least upper bound in the information order (logical OR over known facts). `tvBoth` if either argument is `tvBoth`.

```nim
proc meet*(a, b: TruthValue): TruthValue {.raises: [].}
```
Greatest lower bound in the information order (logical AND over known facts). `tvNeither` if either argument is `tvNeither`.

```nim
proc negate*(a: TruthValue): TruthValue {.raises: [].}
```
Negation: swaps `tvTrue`/`tvFalse`; `tvBoth` and `tvNeither` are fixed points.

```nim
proc leqI*(a, b: TruthValue): bool {.raises: [].}
```
Returns `true` if `a` is below `b` in the information order (`a` has less or equal information than `b`).

---

### `Eval[T]`

```nim
type Eval*[T] = object
  truth*: TruthValue
  value*: Option[T]
  error*: Option[RtError]
```

The result of `interpret`. Carries a truth value alongside an optional success value and optional error, allowing both to be present simultaneously when `truth = tvBoth`.

---

### `Eval` Constructors

```nim
proc evalTrue*[T](v: T): Eval[T] {.raises: [].}
```
Definite success: `truth = tvTrue`, `value = some(v)`.

```nim
proc evalFalse*[T](e: RtError): Eval[T] {.raises: [].}
```
Definite failure: `truth = tvFalse`, `error = some(e)`.

```nim
proc evalBoth*[T](v: T, e: RtError): Eval[T] {.raises: [].}
```
Over-determined: `truth = tvBoth`, both `value` and `error` are set.

```nim
proc evalNeither*[T](): Eval[T] {.raises: [].}
```
Under-determined: `truth = tvNeither`, neither `value` nor `error` is set.

---

### `Eval` Combinators

```nim
proc map*[T, U](ev: Eval[T], f: proc(v: T): U): Eval[U]
```
Applies `f` to the success value if present; propagates truth value and error unchanged.

```nim
proc flatMap*[T, U](ev: Eval[T], f: proc(v: T): Eval[U]): Eval[U]
```
Chains two `Eval` computations, joining truth values and merging errors via `join`.

---

### `interpret` Runner

```nim
proc interpret*[T](eff: Eff[T], budget = 10000): Eval[T]
```

Runs `eff` under the four-valued semantics. Unlike `run`, does not collapse `tvBoth` to an error; callers can inspect both the value and the error when the program is over-determined. Unhandled effects produce `tvFalse` with a `ForeignError`.

---

### `toResult`

```nim
proc toResult*[T](ev: Eval[T]): Result[T] {.raises: [].}
```

Collapses an `Eval[T]` to a classical `Result[T]`:

| `truth`      | outcome                                    |
|--------------|--------------------------------------------|
| `tvTrue`     | `Result` with `isOk = true`                |
| `tvFalse`    | `Result` with `isOk = false`, carries error |
| `tvBoth`     | `Result` with `isOk = false`, `Contradiction` error |
| `tvNeither`  | `Result` with `isOk = false`, `Incomplete` error |

---

## Standard Handlers

Import path: `rteffects/handlers`

The handlers module provides ready-to-use effect tags and handler implementations for common I/O operations (HTTP, file system). Three handler variants are available for each effect: sync (blocking), mock (testing), and deferred (async).

`import rteffects` re-exports this module automatically.

---

### Effect Tags

```nim
const httpGetTag*  = EffectTag("http:get")   ## HTTP GET request
const httpPostTag* = EffectTag("http:post")  ## HTTP POST request
const fileReadTag* = EffectTag("file:read")  ## File read
const fileWriteTag* = EffectTag("file:write") ## File write
```

---

### Typed Perform Wrappers

```nim
proc performHttpGet*(url: string): Eff[string]
```
Perform HTTP GET. Payload: URL string. Resume value: response body.

```nim
proc performHttpPost*(url: string, body: string): Eff[string]
```
Perform HTTP POST. Payload encodes URL and body separated by newline. Resume value: response body.

```nim
proc performFileRead*(path: string): Eff[string]
```
Read a file. Payload: file path. Resume value: file content.

```nim
proc performFileWrite*(path: string, content: string): Eff[string]
```
Write a file. Payload encodes path and content separated by newline. Resume value: empty string on success.

---

### Sync Handlers

Blocking handlers using `std/httpclient` and `readFile`/`writeFile`. Suitable for simple scripts.

```nim
proc syncHttpGetHandler*(): HandlerEntry
proc syncHttpPostHandler*(): HandlerEntry
proc syncFileReadHandler*(): HandlerEntry
proc syncFileWriteHandler*(): HandlerEntry
```

Each returns a `HandlerEntry` with `tag` and `impl` fields. Pass `.impl` to `handle`.

---

### Mock Handlers

For testing. Match by URL/path substring.

```nim
proc mockHttpGetHandler*(responses: seq[(string, string)]): HandlerEntry
```
Returns the response body for the first `(pattern, body)` pair where `pattern` is a substring of the request URL. Aborts if no match.

```nim
proc mockFileReadHandler*(files: seq[(string, string)]): HandlerEntry
```
Returns the content for the first `(pattern, content)` pair where `pattern` is a substring of the file path. Aborts if no match.

---

### Deferred Handlers

For Engine-based async I/O. The handler does **not** call `resume`; the frame goes to `fsSuspended`. The caller is responsible for calling `engine.resumeFrame(fid, value)` or `engine.abortFrame(fid, error)` later.

```nim
proc deferredHttpGetHandler*(): HandlerEntry
proc deferredHttpPostHandler*(): HandlerEntry
proc deferredFileReadHandler*(): HandlerEntry
```

---

### Usage Example

```nim
import rteffects

# With mock handler (testing)
let eff = performHttpGet("https://api.example.com/data")
let result = run[string](handle[string](eff, httpGetTag,
  mockHttpGetHandler(@[("api.example.com", "{\"ok\":true}")]).impl))

# With deferred handler (async)
let engine = newEngine(budget = 100)
let eff2 = handle[string](performHttpGet("https://slow.api"), httpGetTag,
  deferredHttpGetHandler().impl)
let fid = engine.newFrame(eff2.program, eff2.program.entry)
engine.runLoop()
# ... later, when I/O completes:
engine.resumeFrame(fid, boxStr("response body"))
engine.runLoop()
```

---

### GPU Inference

GPU-bound operations (LLM, VLM, TTS, ASR) modeled as effects for priority-based scheduling.

```nim
const gpuInferTag* = EffectTag("gpu:infer")
```

#### Types

```nim
type GpuInferPriority* = enum
  gipBackground = 0    ## VLM scene description, ambient audio analysis
  gipNormal = 5        ## standard requests
  gipUserFacing = 10   ## direct user interaction (chat response)

type GpuInferPayload* = ref object of RootObj
  kind*: string              ## "llm" | "vlm" | "tts" | "asr"
  priority*: GpuInferPriority
  requestJson*: string       ## JSON-serialized inference request

type GpuInferResult* = ref object of RootObj
  success*: bool
  responseJson*: string      ## JSON-serialized inference response
  error*: string             ## error message if !success
```

#### Perform Wrapper

```nim
proc performGpuInfer*(payload: GpuInferPayload): Eff[GpuInferResult]
```
Request GPU inference. Payload carries the request kind, priority, and serialized request. Resume value: `GpuInferResult`.

#### Mock Handler

```nim
proc mockGpuInferHandler*(responses: seq[(string, string)]): HandlerEntry
```
Returns the response JSON for the first `(kind_substring, responseJson)` pair where `kind_substring` matches `payload.kind`. Aborts if no match.

#### Deferred Handler

```nim
proc deferredGpuInferHandler*(): HandlerEntry
```
Suspends the frame. A GPU scheduler calls `engine.resumeFrame(fid, boxRef(GpuInferResult(...)))` when inference completes. Priority dispatch is the scheduler's responsibility.

#### Usage Example

```nim
import rteffects

# Testing with mock
let eff = performGpuInfer(GpuInferPayload(
  kind: "llm", priority: gipUserFacing,
  requestJson: """{"messages":[{"role":"user","content":"hello"}]}"""))
let result = run[GpuInferResult](handle[GpuInferResult](
  eff, gpuInferTag,
  mockGpuInferHandler(@[("llm", """{"response":"Hi!"}""")]).impl))
assert result.ok.success

# Async with deferred handler
let eng = newEngine(budget = 100)
let eff2 = handle[GpuInferResult](
  performGpuInfer(GpuInferPayload(kind: "vlm", priority: gipBackground,
    requestJson: "{}")),
  gpuInferTag, deferredGpuInferHandler().impl)
let fid = eng.newFrame(eff2.program, eff2.program.entry)
eng.runLoop()
# ... GPU completes:
eng.resumeFrame(fid, boxRef(GpuInferResult(success: true, responseJson: "{}")))
eng.runLoop()
```

---

## Async Resume API (Engine)

Import path: `rteffects/vm/engine`

These procedures allow external code (async I/O callbacks, event loops) to resume or abort suspended frames.

---

### `resumeFrame`

```nim
proc resumeFrame*(engine: Engine, frameId: int, value: BoxedValue)
```

Resume a suspended frame with a value. The frame must be in `fsSuspended` state. Sets the frame's result and returns control to the continuation stack. No-op if the frame ID is invalid or the frame is not suspended.

---

### `abortFrame`

```nim
proc abortFrame*(engine: Engine, frameId: int, error: RtError)
```

Abort a suspended frame with an error. The frame must be in `fsSuspended` state. Sets the frame's error and propagates failure through the continuation stack. No-op if the frame ID is invalid or the frame is not suspended.

---

### `hasSuspended`

```nim
proc hasSuspended*(engine: Engine): bool
```

Returns `true` if any frames are in `fsSuspended` state (waiting for async I/O).

---

### `allDone`

```nim
proc allDone*(engine: Engine): bool
```

Returns `true` if the ready queue is empty and no frames are suspended. Indicates all work is complete.

---

## Tier 4: VM Internals

Import paths: `rteffects/vm/types`, `rteffects/vm/engine`

This tier is intended for library developers extending the runtime. Application code and handler authors should not depend on these types directly, as they may change between minor versions.

---

### `EffProgram` and `EffOp`

```nim
type ContId* = distinct int   # index into EffProgram.ops

type EffOpKind* = enum
  opPure, opFail, opBind, opMap, opPerform, opHandle

type EffOp* = object  # variant; fields depend on EffOpKind

type EffProgram* = object
  ops*:   seq[EffOp]
  entry*: ContId
```

`EffProgram` is the bytecode representation produced by the smart constructors (`pure`, `fail`, `andThen`, `map`, `perform`, `handle`). `ContId` is an index into `ops` used as a continuation pointer. Use `addOp` to append operations when constructing programs programmatically.

```nim
proc addOp*(prog: var EffProgram, op: EffOp): ContId
```
Appends an `EffOp` to `prog.ops` and returns its index.

---

### `Engine` and `Frame`

```nim
type FrameState* = enum fsReady, fsRunning, fsSuspended, fsDone
type FrameEvent* = enum evDequeue, evYield, evComplete, evSuspend, evResume

type HandlerEntry* = object
  tag*:  EffectTag
  impl*: HandlerProc

type Frame* = object
  id*:        FrameId
  pc*:        ContId
  program*:   EffProgram
  sm*:        StateMachine[FrameState, FrameEvent]
  result*:    BoxedValue
  hasResult*: bool
  failed*:    bool
  error*:     RtError
  handlers*:  seq[HandlerEntry]
  contStack*: seq[ContId]

type Engine* = ref object
  frames*:  Table[int, Frame]
  readyQ*:  Deque[int]
  nextId*:  int
  budget*:  int
```

`Engine` is a cooperative, single-threaded effect interpreter. It maintains a ready queue of `Frame` values and steps each frame until the budget is exhausted or all frames reach `fsDone`. `Frame.sm` is an actor state machine (from the `actor-state-machine` package) that enforces valid state transitions.

```nim
proc newEngine*(budget = 1000): Engine
```
Allocates a new `Engine` with the given step budget.

---

## Module Index

| Module | Import path | Tier |
|--------|-------------|------|
| Core types and error constructors | `rteffects/core` | 1 |
| Effect algebra (`Eff`, `pure`, `fail`, `andThen`, `map`, `run`, `perform`, `handle`) | `rteffects/algebra` | 1, 2 |
| Standard handlers (HTTP, File, GPU, TTS, ASR — sync, mock, deferred) | `rteffects/handlers` | 1, 2 |
| Four-valued semantics (`Eval`, `TruthValue`, `interpret`) | `rteffects/semantics` | 3 |
| VM value representation (`BoxedValue`, `EffProgram`, `EffOp`) | `rteffects/vm/types` | 2, 4 |
| VM execution engine (`Engine`, `Frame`, `resumeFrame`, `abortFrame`) | `rteffects/vm/engine` | 4 |
