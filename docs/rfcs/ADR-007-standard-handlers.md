# ADR-007: Standard Effect Handlers for Common I/O Operations

## Status

Accepted

Date: 2026-03-17

## Context

RTEffects provides the algebraic effects infrastructure — `perform`, `handle`,
`EffectTag`, `BoxedValue` — but until now every consumer had to define its own
effect tags and handler implementations for common operations like HTTP requests
and file I/O.

This creates two problems:

1. **Boilerplate**: every project that needs HTTP or file effects duplicates the
   same boxing/unboxing patterns and tag string choices.
2. **Vocabulary fragmentation**: without canonical tag strings, effects authored
   in different libraries cannot be composed or handled by a shared handler.

Three distinct execution modes arise in practice:

| Mode | Use case | Behavior |
|------|----------|----------|
| Blocking (sync) | Command-line scripts, batch jobs | Calls OS/network directly, blocks until done |
| Mock (test) | Unit tests, property tests | Returns pre-configured responses; no I/O |
| Deferred (async) | Engine-driven cooperative multitasking | Suspends the frame; resumes externally |

None of the modes is universally correct. A standard library must serve all three.

## Decision

Add a `rteffects/handlers` module that provides a shared vocabulary of effect
tags, typed perform wrappers, and three handler variants for each operation.

### Effect Tags (canonical vocabulary)

```nim
let httpGetTag*  = EffectTag("http:get")
let httpPostTag* = EffectTag("http:post")
let fileReadTag* = EffectTag("file:read")
let fileWriteTag* = EffectTag("file:write")
```

Tag strings use a `domain:verb` convention. Canonicalizing them in-tree ensures
that any two libraries importing `rteffects/handlers` agree on identity.

### Typed Perform Wrappers

```nim
proc performHttpGet*(url: string): Eff[string]
proc performHttpPost*(url, body: string): Eff[string]
proc performFileRead*(path: string): Eff[string]
proc performFileWrite*(path, content: string): Eff[string]
```

Wrappers handle boxing via `BoxedValue` so callers never touch the raw
`perform` API for these operations.

Multi-argument operations (POST, file-write) encode their payload as
a `ref object` (e.g., `HttpPostPayload`, `FileWritePayload`) boxed via `boxRef`.
Handlers cast the `refVal` back to the expected type to recover the arguments.
This keeps `perform`'s single-value contract while providing type-safe,
unconstrained payload support.


### HandlerEntry Type

```nim
type HandlerEntry* = object
  tag*: EffectTag
  impl*: HandlerProc
```

Each factory returns a `HandlerEntry`. The caller passes `.impl` to `handle`.
Pairing tag and implementation enables future handler registry patterns without
coupling the factory to a specific `handle` call site.

### Variant 1 — Sync Handlers

```nim
proc syncHttpGetHandler*(): HandlerEntry
proc syncHttpPostHandler*(): HandlerEntry
proc syncFileReadHandler*(): HandlerEntry
proc syncFileWriteHandler*(): HandlerEntry
```

Use `std/httpclient` (HTTP) and `std/os` + `readFile`/`writeFile` (file).
Call `resume` immediately with the result or error. Block the calling thread.
Intended for scripts and CLI tools where simplicity outweighs concurrency.

### Variant 2 — Mock Handlers

```nim
proc mockHttpGetHandler*(responses: Table[string, string]): HandlerEntry
proc mockHttpPostHandler*(responses: Table[string, string]): HandlerEntry
proc mockFileReadHandler*(files: Table[string, string]): HandlerEntry
proc mockFileWriteHandler*(): HandlerEntry
```

Match the request URL or file path using substring matching against the keys
of the supplied `Table`. The first matching key wins. If no key matches,
`resume` is called with an error result.

`mockFileWriteHandler` accepts no table — writes are silently discarded and
`resume` is called with an empty success value.

Substring matching (rather than exact or regex matching) is chosen for
practicality: test scenarios rarely need more precision, and substring matching
avoids a regex dependency.

### Variant 3 — Deferred Handlers

```nim
proc deferredHttpGetHandler*(): HandlerEntry
proc deferredHttpPostHandler*(): HandlerEntry
proc deferredFileReadHandler*(): HandlerEntry
proc deferredFileWriteHandler*(): HandlerEntry
```

Do **not** call `resume` inside the handler body. The frame suspends in
`ssSuspended` state. The Engine-level caller is responsible for eventually
calling `resumeFrame` (on success) or `abortFrame` (on failure) with the
result. This is the correct handler form for cooperative async I/O driven by
an event loop or work queue.

### Re-export from rteffects.nim

`src/rteffects.nim` re-exports `handlers`, so `import rteffects` provides
access to everything without a separate import line.

### Module Placement

```
src/rteffects/
├── core.nim
├── semantics.nim
├── algebra.nim
├── handlers.nim      ← new: standard I/O effect handlers
└── vm/
    ├── types.nim
    └── engine.nim
```

`handlers.nim` sits between Tier 1 (app developer) and Tier 2 (handler author)
in the layered API (ADR-004). It imports `algebra.nim`, `vm/types.nim`, and
`vm/engine.nim` but does not import `semantics.nim` — it never touches
`TruthValue` or `Eval[T]` directly.

## Rationale

### vs. Separate package

A separate `nim-rteffects-handlers` package was considered. Rejected because:

- The canonical effect tag strings (`"http:get"` etc.) must be a single source
  of truth. Splitting them across packages introduces version skew risk.
- The handlers are tightly coupled to the `BoxedValue` boxing contract and the
  deferred `resumeFrame`/`abortFrame` API. An in-tree module can evolve with
  those APIs without a separate release cycle.
- The added dependency coordination burden exceeds the benefit of a separate
  package for foundational I/O operations.

### vs. One variant per handler (no sync/mock/deferred split)

A single handler per operation would force a global choice. Scripts would need
the Engine overhead; tests would perform real I/O; async code would block.
The three-variant design lets each call site pick the execution model
appropriate for its context.

### vs. Regex matching for mocks

Substring matching was chosen over regex for two reasons: it avoids adding a
regex dependency, and test scenarios for effect handlers are typically simple
enough that substring matching on URL prefixes or file path segments suffices.
If a project needs regex matching, it can author a custom mock handler using
the same `HandlerEntry` interface.

### vs. Returning HandlerProc directly

Returning `HandlerEntry` (tag + impl pair) rather than a bare `HandlerProc`
enables callers to register handlers into a table keyed by `EffectTag` and
enables future handler registry patterns. The cost is one extra field access
(`.impl`) at the call site — negligible.

### Why newline-separated payload encoding for POST/write

`perform` carries a single `BoxedValue`. Multi-argument operations need to
pack multiple strings into one value. Options considered:

| Encoding | Pros | Cons |
|----------|------|------|
| `ref object` | Type-safe, no content limits | Minor allocation cost |
| JSON object | Handles all content | Adds json parse overhead |
| Separate effect tags per argument count | Clean types | Combinatorial tag explosion |

`ref object` boxing provides the best balance of type safety, performance,
and lack of content constraints.

## Consequences

### Positive

- Zero-boilerplate HTTP and file effects for the common case: call
  `performHttpGet(url)` and handle with the appropriate variant.
- Canonical effect tag strings eliminate vocabulary fragmentation across
  projects that use rteffects.
- Mock handlers make testing algebraic effect programs trivial — no real
  network or filesystem access required.
- Deferred handlers provide a correct bridge to the Engine async resume API
  (see planned ADR-008).
- `import rteffects` continues to give access to everything — no import
  surface change for existing code.

### Negative

- Adds `std/httpclient` as a transitive dependency for projects that import
  `handlers` (even if they only use mock or deferred variants). Mitigated:
  sync handler procs are only compiled when called; the import is conditional
  on `when not defined(rteffectsNoSync)` if the dependency proves problematic.
- `mockFileWriteHandler` silently discards writes — callers that need to
  inspect written content must author a custom handler.

### Neutral

- Module count increases by one (`handlers.nim`). Consistent with the
  established pattern of one bounded context per module (ADR-005).
- The deferred handler pattern requires external resumption infrastructure
  (an event loop or work queue) — this module does not provide that
  infrastructure, only the suspension side.

## Files Changed

| File | Change |
|------|--------|
| `src/rteffects/handlers.nim` | New module: effect tags, typed wrappers, three handler variants |
| `src/rteffects.nim` | Add `include rteffects/handlers` re-export |
