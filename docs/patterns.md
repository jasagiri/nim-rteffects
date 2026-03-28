# RTEffects v2 Patterns

## Imports

All examples use the following imports unless noted otherwise:

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
```

For Belnap semantics (`Eval[T]`, `TruthValue`, `evalTrue`, etc.) also import:

```nim
import rteffects/semantics
```

For standard handlers (HTTP, file I/O) use the convenience re-export:

```nim
import rteffects
```

---

## 1. Effect Handler Patterns

### Basic Handler (perform + handle + resume)

`perform` requests an effect identified by a tag. `handle` installs a handler
that intercepts the effect. The handler calls `resume` to supply a value and
continue the computation.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let doubleTag = EffectTag("double")

# Request the effect
let body = perform[int](doubleTag, boxInt(21))

# Handle it: unbox payload, compute, resume with result
let eff = body.handle(doubleTag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) * 2))
)

let result = run[int](eff)
assert result.isOk
assert result.ok == 42
```

### Handlers with Structured Payloads (ref object)

As of v2.1.0, you can pass user-defined `ref object` types through the effect
system. This is the preferred way to handle effects with multiple arguments.

```nim
type
  AuthRequest* = ref object of RootObj
    user*: string
    token*: string

let authTag = EffectTag("auth")

let body = perform[bool](authTag, boxRef(AuthRequest(user: "alice", token: "secret")))

let eff = body.handle(authTag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    # Use unboxRef and cast to recover the type.
    # The system performs an internal 'of' check to ensure safety.
    let req = cast[AuthRequest](unboxRef(payload))
    if req.token == "secret":
      resume(boxBool(true))
    else:
      resume(boxBool(false))
)

assert run[bool](eff).ok == true
```

### Aborting Handler (validate input, abort on error)

A handler can call `abort` instead of `resume` to terminate the computation
with an error. The error propagates through the chain just like `fail`.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let validateTag = EffectTag("validate")

let eff = perform[int](validateTag, boxInt(-5))
  .handle(validateTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let n = unboxInt(payload)
      if n < 0:
        abort(RtError(kind: ForeignError, msg: "negative input: " & $n))
      else:
        resume(boxInt(n))
  )

let result = run[int](eff)
assert not result.isOk
assert result.err.msg == "negative input: -5"
```

### Handler with State (counting, accumulating via closure)

Because handlers are closures, they can close over mutable variables to
accumulate state across multiple `perform` calls within the same handler scope.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let logTag = EffectTag("log")

var messages: seq[string] = @[]

# Chain three log effects and collect them
let body = perform[string](logTag, boxStr("start"))
  .andThen(proc(_: string): Eff[string] {.gcsafe.} =
    perform[string](logTag, boxStr("middle"))
  )
  .andThen(proc(_: string): Eff[string] {.gcsafe.} =
    perform[string](logTag, boxStr("end"))
  )

let eff = body.handle(logTag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    {.cast(gcsafe).}:
      messages.add(unboxStr(payload))
    resume(payload)  # pass the string through as the value
)

let result = run[string](eff)
assert result.isOk
assert messages == @["start", "middle", "end"]
```

Note: capturing a `var` from an outer scope in a `{.gcsafe.}` closure requires
a `{.cast(gcsafe).}` block because Nim cannot prove the mutation is safe across
threads. This is acceptable in single-threaded handler code.

---

## 2. Handler Composition

### Multiple Handlers for Different Tags

Install multiple `handle` calls for distinct tags. Each handler only fires for
its matching tag.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let readTag  = EffectTag("read")
let writeTag = EffectTag("write")

# A computation that performs both effects
let body = perform[string](readTag, boxStr("key"))
  .andThen(proc(v: string): Eff[string] {.gcsafe.} =
    perform[string](writeTag, boxStr("key=" & v))
  )

# Chain two handlers, one for each tag
let eff = body
  .handle(readTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxStr("hello"))  # return fixed value for "key"
  )
  .handle(writeTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(payload)  # echo back what was written
  )

let result = run[string](eff)
assert result.isOk
assert result.ok == "key=hello"
```

### Nested Handlers (Innermost Wins for the Same Tag)

When the same tag is handled at multiple levels, the innermost handler (the one
closest to the `perform` in the program structure) intercepts the effect. The
outer handler is never reached.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let tag = EffectTag("compute")

let body = perform[int](tag, boxInt(10))

# Inner handler: add 5 → produces 15
let withInner = body.handle(tag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) + 5))
)

# Outer handler: multiply by 100 — never invoked because inner matches first
let withBoth = withInner.handle(tag,
  proc(payload: BoxedValue,
       resume: proc(v: BoxedValue) {.gcsafe.},
       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) * 100))
)

let result = run[int](withBoth)
assert result.ok == 15  # inner handler won; outer was not reached
```

### Handler That Does Not Match (Passes Through)

A handler installed for tag `A` has no effect on a `perform` for tag `B`. The
unmatched perform bubbles up to the next enclosing handler (or produces an
"unhandled effect" error if none exists).

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let readTag  = EffectTag("read")
let otherTag = EffectTag("other")

# perform uses readTag; handler is for otherTag — no match
let eff = perform[int](readTag, boxInt(7))
  .handle(otherTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxInt(99))
  )

let result = run[int](eff)
# readTag is unhandled → error
assert not result.isOk
assert "unhandled effect" in result.err.msg
```

---

## 3. Error Handling Patterns

### Short-Circuit on fail (andThen Propagates Errors)

A `fail` short-circuits the entire `andThen` chain. Subsequent steps are
skipped and the error is forwarded to the final result.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let eff = fail[int](RtError(kind: ForeignError, msg: "connection refused"))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    # Never executed
    pure[int](x + 1)
  )
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    # Never executed
    pure[int](x * 2)
  )

let result = run[int](eff)
assert not result.isOk
assert result.err.msg == "connection refused"
```

Failure mid-chain works the same way:

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let eff = pure[int](1)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    fail[int](RtError(kind: Timeout, msg: "step timed out"))
  )
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    # Never executed
    pure[int](x * 100)
  )

let result = run[int](eff)
assert not result.isOk
assert result.err.kind == Timeout
```

### Validation with Abort

Use an aborting handler to model validation. Compose multiple validated
`perform` calls in a chain — the first failed validation stops the chain.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let checkTag = EffectTag("check")

proc validate(n: int): Eff[int] =
  perform[int](checkTag, boxInt(n))

let handler = proc(payload: BoxedValue,
                   resume: proc(v: BoxedValue) {.gcsafe.},
                   abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  let n = unboxInt(payload)
  if n < 0:
    abort(RtError(kind: ForeignError, msg: "must be non-negative: " & $n))
  elif n > 100:
    abort(RtError(kind: ForeignError, msg: "must be <= 100: " & $n))
  else:
    resume(boxInt(n))

let eff = validate(42)
  .andThen(proc(a: int): Eff[int] {.gcsafe.} = validate(-1))
  .andThen(proc(b: int): Eff[int] {.gcsafe.} = pure[int](b))
  .handle(checkTag, handler)

let result = run[int](eff)
assert not result.isOk
assert result.err.msg == "must be non-negative: -1"
```

### Error Inspection via Result

`run` returns a `Result[T]` with two fields: `isOk: bool` and `ok: T` (on
success) or `err: RtError` (on failure). Inspect `err.kind` to distinguish
error categories.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let eff = fail[string](RtError(
  kind: Timeout,
  msg: "operation timed out",
))

let result = run[string](eff)
if result.isOk:
  echo "value: ", result.ok
else:
  case result.err.kind
  of Timeout:
    echo "retry after timeout"
  of Cancelled:
    echo "request was cancelled"
  of ForeignError:
    echo "external error: ", result.err.msg
  else:
    echo "unexpected error: ", result.err
```

---

## 4. Testing Patterns

### Testing Pure Computations

For computations with no effects, build a chain of `pure`, `andThen`, and
`map`, then `run` and assert on the result.

```nim
import std/unittest
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

suite "pure computation":
  test "given a chain of pure steps when run then result is correct":
    let eff = pure[int](10)
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 5))
      .map(proc(x: int): int {.gcsafe.} = x * 2)

    let result = run[int](eff)
    check result.isOk
    check result.ok == 30  # (10 + 5) * 2
```

### Testing Effects with Mock Handlers

Replace real handlers with test doubles that return controlled values. This lets
you test the computation logic in isolation from the effect implementation.

```nim
import std/unittest
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let dbTag = EffectTag("db.query")

# The computation under test
proc fetchUser(id: int): Eff[string] =
  perform[string](dbTag, boxInt(id))

suite "effect with mock handler":
  test "given mock db handler when fetching user then returns mock value":
    # Install a test handler that returns a fixed value
    let eff = fetchUser(42)
      .andThen(proc(name: string): Eff[string] {.gcsafe.} =
        pure[string]("Hello, " & name)
      )
      .handle(dbTag,
        proc(payload: BoxedValue,
             resume: proc(v: BoxedValue) {.gcsafe.},
             abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          # Mock: return "Alice" for any id
          resume(boxStr("Alice"))
      )

    let result = run[string](eff)
    check result.isOk
    check result.ok == "Hello, Alice"

  test "given mock db handler that aborts when fetching user then result is error":
    let eff = fetchUser(99)
      .handle(dbTag,
        proc(payload: BoxedValue,
             resume: proc(v: BoxedValue) {.gcsafe.},
             abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          abort(RtError(kind: ForeignError, msg: "not found: " & $unboxInt(payload)))
      )

    let result = run[string](eff)
    check not result.isOk
    check result.err.msg == "not found: 99"
```

### Using interpret for Semantic Verification

`interpret` returns an `Eval[T]` with a `TruthValue` field. Use this in tests
that need to verify the 4-valued outcome (for example, confirming that an
unhandled effect produces `tvFalse` rather than leaving the result undetermined).

```nim
import std/[unittest, options]
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

suite "semantic verification with interpret":
  test "given pure value when interpreted then truth is tvTrue":
    let ev = interpret[int](pure[int](42))
    check ev.truth == tvTrue
    check ev.value == some(42)

  test "given fail when interpreted then truth is tvFalse":
    let ev = interpret[int](fail[int](RtError(kind: Timeout, msg: "t")))
    check ev.truth == tvFalse
    check ev.error.isSome

  test "given unhandled effect when interpreted then truth is tvFalse":
    let ev = interpret[int](perform[int](EffectTag("missing")))
    check ev.truth == tvFalse

  test "given handled effect when interpreted then truth is tvTrue":
    let tag = EffectTag("increment")
    let eff = perform[int](tag, boxInt(10))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
      .handle(tag,
        proc(payload: BoxedValue,
             resume: proc(v: BoxedValue) {.gcsafe.},
             abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          resume(boxInt(unboxInt(payload) + 1))
      )

    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(22)  # (10 + 1) * 2
```

---

## 5. Common Pitfalls

### GC-Safety: Closures Need {.gcsafe.}

All closures passed to `andThen`, `map`, `handle`, and `perform` must be marked
`{.gcsafe.}`. Nim's type checker enforces this at the call site.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# Wrong: missing {.gcsafe.}
# This will not compile because andThen requires a gcsafe closure.
#
#   let bad = pure[int](1).andThen(proc(x: int): Eff[int] =
#     pure[int](x + 1)
#   )

# Correct: explicit {.gcsafe.}
let good = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
  pure[int](x + 1)
)
let result = run[int](good)
assert result.ok == 2
```

When a `{.gcsafe.}` closure captures a `var` from its enclosing scope (for
example, to accumulate state), wrap the mutation in `{.cast(gcsafe).}`:

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let logTag = EffectTag("log")
var calls = 0

let eff = perform[int](logTag, boxNone())
  .handle(logTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      {.cast(gcsafe).}:
        calls.inc
      resume(boxInt(calls))
  )

let result = run[int](eff)
assert result.ok == 1
assert calls == 1
```

### EffectTag Must Be a Local `let`, Not a Global `let`, When Captured in Closures

`EffectTag` is a `distinct string`. Global `let` values of `distinct` types
may trigger GC-safety warnings when captured inside `{.gcsafe.}` closures
because Nim conservatively treats heap-allocated globals as potentially shared.
Declare the tag as a local `let` inside the function that builds the effect,
or pass it as a parameter.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# Preferred: tag is local to the builder proc
proc makeDoubler(x: int): Eff[int] =
  let tag = EffectTag("double")   # local — no GC-safety issue
  perform[int](tag, boxInt(x))
    .handle(tag,
      proc(payload: BoxedValue,
           resume: proc(v: BoxedValue) {.gcsafe.},
           abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
        resume(boxInt(unboxInt(payload) * 2))
    )

let result = run[int](makeDoubler(21))
assert result.ok == 42
```

### Handler Scope: handle Only Covers Its Immediate Body Expression

A handler installed via `handle` intercepts `perform` calls within the
`eff` argument passed to `handle`. It does **not** intercept `perform` calls
inside closures that are created and invoked later by `andThen` continuations,
because those closures run in a new execution context that may extend beyond
the handler's scope in the continuation table.

In practice this means: place `handle` **after** the `andThen` chain that
contains the `perform` calls you want to intercept, not before.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let tag = EffectTag("effect")

# Correct: the handler wraps the entire chain, including the perform inside it
let eff = perform[int](tag, boxInt(5))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 10))
  .handle(tag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxInt(unboxInt(payload) * 2))
  )

let result = run[int](eff)
assert result.ok == 20  # (5 * 2) + 10
```

If the handler wraps only the `perform` node and the `andThen` continuation
is appended outside the handler scope, the handler still fires for the `perform`
because `handle` is placed around the sub-expression containing `perform` in
the continuation table. However, to keep reasoning straightforward, always
place `handle` as the outermost combinator.

---

## 6. Standard Handlers Pattern

### Using Pre-built Handlers

The `handlers` module provides typed perform wrappers and matching handler
implementations for HTTP and file I/O. Use `performHttpGet` instead of manually
calling `perform` with `boxStr`.

```nim
import rteffects

# Typed perform wrapper — no manual boxing needed
let eff = performHttpGet("https://api.example.com/data")
  .map(proc(resp: string): string {.gcsafe.} = "parsed:" & resp)

# Mock handler for testing — matches by URL substring
let result = run[string](handle[string](eff, httpGetTag,
  mockHttpGetHandler(@[("api.example.com", "{\"ok\":true}")]).impl))
assert result.isOk
assert result.ok == "parsed:{\"ok\":true}"
```

### Composing Multiple Standard Handlers

```nim
import rteffects

let pipeline = performHttpGet("https://api.example.com/config")
  .andThen(proc(config: string): Eff[string] {.gcsafe.} =
    performFileWrite("/tmp/config.json", config)
  )

let handled = handle[string](
  handle[string](pipeline, httpGetTag,
    mockHttpGetHandler(@[("api.example.com", "{\"port\":8080}")]).impl),
  fileWriteTag,
  syncFileWriteHandler().impl)
```

---

## 7. Async Resume Pattern

### Deferred Handler + External Resume

Deferred handlers do not call `resume`. The frame suspends and waits for
an external callback (event loop, async I/O completion) to call
`engine.resumeFrame` or `engine.abortFrame`.

```nim
import rteffects

# 1. Build effect with deferred handler
let eff = handle[string](
  performHttpGet("https://slow.api/data"), httpGetTag,
  deferredHttpGetHandler().impl)

# 2. Submit to engine
let engine = newEngine(budget = 200)
let fid = engine.newFrame(eff.program, eff.program.entry)
engine.runLoop()

# Frame is now suspended
assert engine.hasSuspended()
assert not engine.allDone()

# 3. Later, when async I/O completes:
engine.resumeFrame(fid, boxStr("HTTP 200 response body"))
engine.runLoop()

assert engine.allDone()
assert engine.frames[fid].result.strVal == "HTTP 200 response body"
```

### Aborting a Suspended Frame

```nim
import rteffects

engine.abortFrame(fid, exceptionError("connection timeout"))
engine.runLoop()

assert engine.frames[fid].failed
assert engine.frames[fid].error.msg == "connection timeout"
```

### Multiple Concurrent Suspended Frames

```nim
import rteffects

let engine = newEngine(budget = 500)
let fidA = engine.newFrame(effA.program, effA.program.entry)
let fidB = engine.newFrame(effB.program, effB.program.entry)
engine.runLoop()

# Both suspended — resume in any order
engine.resumeFrame(fidB, boxStr("B done"))
engine.resumeFrame(fidA, boxStr("A done"))
engine.runLoop()

assert engine.allDone()
```

---

### Type Erasure: BoxedValue Must Be Unboxed to the Correct Type

`BoxedValue` is a variant object. Calling `unboxInt` on a `bvStr` value will
access the wrong field. The type contract between the `perform` call site and
the handler is not enforced by the compiler; it is the programmer's
responsibility.

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let tag = EffectTag("fetch")

# perform sends a string payload
let eff = perform[string](tag, boxStr("https://example.com"))
  .handle(tag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      # Correct: payload is bvStr, so use unboxStr
      let url = unboxStr(payload)
      resume(boxStr("response from " & url))

      # Wrong (would access intVal on a bvStr, giving garbage or a crash):
      #   let n = unboxInt(payload)
  )

let result = run[string](eff)
assert result.isOk
assert result.ok == "response from https://example.com"
```

Use `boxNone` / `bvNone` when the effect carries no payload and the handler
ignores it:

```nim
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

let yieldTag = EffectTag("yield")

let eff = perform[int](yieldTag)  # boxNone() is the default
  .handle(yieldTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      assert payload.kind == bvNone
      resume(boxInt(0))
  )

let result = run[int](eff)
assert result.ok == 0
```
