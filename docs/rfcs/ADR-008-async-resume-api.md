# ADR-008: Async Resume API for Deferred Effect Handlers

## Status

Accepted

## Date

2026-03-17

## Context

The Engine's `perform` → `handle` mechanism requires handlers to call `resume(value)`
or `abort(error)` synchronously within the handler body. Real-world I/O (HTTP
requests, file operations, database queries) is inherently asynchronous: the
result is not available at the time the handler is invoked.

When a handler calls neither `resume` nor `abort`, the frame enters `fsSuspended`
state. Prior to this ADR there was no way for external code (event loops, async
callbacks) to resume or abort suspended frames. This gap prevented integration
with async I/O runtimes such as `asyncdispatch`, `chronos`, or custom libuv
bindings.

Additionally, event loops need two predicates to drive their poll loop:

1. Whether there are any frames currently waiting on I/O (`hasSuspended`).
2. Whether all work is finished and the loop can exit (`allDone`).

Neither predicate was available on `Engine`.

## Decision

Add four procedures to `rteffects/vm/engine`:

### resumeFrame

```nim
proc resumeFrame*(engine: Engine, frameId: int, value: BoxedValue)
```

- Resume a suspended frame with a value.
- Sets `frame.result` and `frame.hasResult = true`.
- Calls `completeOrReturn` to continue the continuation stack.
- No-op if `frameId` is invalid or the frame is not in `fsSuspended`.

### abortFrame

```nim
proc abortFrame*(engine: Engine, frameId: int, error: RtError)
```

- Abort a suspended frame with an error.
- Sets `frame.error` and `frame.failed = true`.
- Calls `completeOrReturn` to propagate failure.
- No-op if `frameId` is invalid or the frame is not in `fsSuspended`.

### hasSuspended

```nim
proc hasSuspended*(engine: Engine): bool
```

- Returns `true` if any frame is in `fsSuspended` state.
- Used by event loops to know whether to poll for I/O completion.

### allDone

```nim
proc allDone*(engine: Engine): bool
```

- Returns `true` when `queueLen == 0` AND no suspended frames exist.
- The termination condition for an event loop driving the engine.

## Interaction with Belnap Semantics

The Belnap four-valued logic (ADR-001) maps naturally onto frame suspension:

| Frame state | Belnap value | Meaning |
|-------------|-------------|---------|
| `fsSuspended` | `tvNeither` | Undetermined — awaiting external I/O |
| After `resumeFrame` | `tvTrue` | Value provided; continuation proceeds |
| After `abortFrame` | `tvFalse` | Error provided; failure propagates |
| Contradiction in chain | `tvBoth` | Both value and error — handled by existing `completeOrReturn` |

`resumeFrame` transitions a frame from `tvNeither` toward `tvTrue`.
`abortFrame` transitions a frame from `tvNeither` toward `tvFalse`.
The Engine's existing `completeOrReturn` handles all continuation-stack
unwinding and preserves Belnap semantics, including the `tvBoth` case if a
contradiction arises further along the chain.

## Usage Pattern

```
1. Build Eff[T] with a deferred handler
   (handler calls neither resume nor abort — frame enters fsSuspended)
2. Submit to Engine:
      let fid = engine.newFrame(eff.program, eff.program.entry)
3. engine.runLoop()
      → frame reaches fsSuspended
4. Start async I/O externally, storing fid alongside the pending request
5. On I/O completion:
      engine.resumeFrame(fid, boxStr(response))
   On I/O failure:
      engine.abortFrame(fid, exceptionError(msg))
6. engine.runLoop()
      → frame continues from where it was suspended → reaches fsDone
```

A minimal event loop integrating the two predicates:

```nim
while not engine.allDone():
  engine.runLoop()
  if engine.hasSuspended():
    pollIoEvents()   # platform-specific: asyncdispatch.poll(), etc.
```

## Safety Properties

- `resumeFrame` and `abortFrame` are no-ops on invalid or non-suspended frames.
  This prevents double-resume bugs from crashing the engine.
- Multiple concurrent suspended frames are supported; each is tracked
  independently by `frameId`.
- Resume order is arbitrary and does not need to match suspension order.
- After `resumeFrame` or `abortFrame`, the frame is re-enqueued via
  `completeOrReturn`; the caller must invoke `runLoop()` again to execute the
  resumed continuation.

## Rationale

### Why frameId-based API rather than closure callbacks?

A callback approach would require the handler to capture and store `resume`/`abort`
closures, then pass them to the external I/O subsystem. The `frameId`-based API
is simpler: the handler stores only an integer, and `Engine` remains the single
owner of frame state. Closure lifecycle issues (captured references keeping
frames alive) are avoided entirely.

### Why no-op on invalid state?

Defensive design. In a concurrent or callback-driven environment, double-resume
is easy to introduce accidentally (e.g. both a timeout handler and a success
handler fire). A no-op silently discards the second call rather than corrupting
engine state.

### Why separate from `Engine.step`?

`resumeFrame` and `abortFrame` are external entry points, not part of the
internal stepping loop. They set frame state and re-enqueue, but they do not
execute steps themselves. This separation keeps the stepping loop free of
external synchronisation concerns and allows the caller to batch multiple
resumes before a single `runLoop()` call.

### Why not integrate with asyncdispatch directly?

Tight coupling to one async runtime would preclude use with others (chronos,
tokio-nim, raw epoll, etc.). The four-procedure API is runtime-agnostic: any
event loop that can call a Nim procedure on I/O completion can drive the engine.

## Consequences

### Positive

- Enables integration with any async I/O runtime (`asyncdispatch`, `chronos`,
  libuv bindings, custom epoll loops).
- Works naturally with deferred handlers introduced alongside this ADR.
- Multiple concurrent I/O operations are supported via multiple suspended frames
  without any additional coordination mechanism.
- Clean separation of concerns: the Engine schedules continuations; external
  code drives I/O.
- No breaking changes to existing `perform`/`handle`/`run` API surface.

### Negative

- The caller must manage the `frameId` → I/O operation mapping externally.
  The Engine provides no built-in registry for pending I/O.
- `runLoop()` must be called explicitly after `resumeFrame`/`abortFrame`;
  resumption is not automatic.
- No built-in timeout mechanism. Callers must implement timeouts externally
  by calling `abortFrame` from a timer callback.

## Files Changed

| File | Change |
|------|--------|
| `src/rteffects/vm/engine.nim` | Added `resumeFrame`, `abortFrame`, `hasSuspended`, `allDone` |
| `tests/t_async_resume.nim` | New test suite covering async resume, abort, and event-loop pattern |
