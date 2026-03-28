# ADR-009: Robust Ref Support and VM Engine Optimization

## Status

Accepted

Date: 2026-03-27

## Context

Prior to this ADR, RTEffects had several limitations impacting robustness, performance, and usability:

1.  **Ref Object Support**: The `Eff[T]` algebra only supported a few primitive types (`int`, `string`, `float`, `bool`) for boxing. User-defined `ref object` types were discarded (converted to `bvNone`), forcing developers to use fragile workarounds like newline-separated strings for complex payloads.
2.  **VM Performance**: The engine's `runLoop` performed O(N) scans over all frames to find those needing `bvProgram` resolution or result propagation. As the number of concurrent frames grew, this led to quadratic performance degradation.
3.  **Memory Efficiency**: The `readyQ` was a simple `seq` with an increasing index, causing linear memory growth throughout the execution loop.
4.  **Error Reporting**: Budget exhaustion was silently reported as `evalNeither`, making it indistinguishable from an incomplete but normal computation.
5.  **Type Safety**: Runtime `cast` operations from `RootRef` lacked type validation, posing a risk of memory corruption or segmentation faults if internal invariants were violated.

## Decision

Implement a series of foundational improvements to the VM and Effect Algebra to ensure production-grade robustness and scalability.

### 1. Full `ref object` Support in Algebra

Extend `defaultBoxer` and `defaultUnboxer` to handle `ref` types using `boxRef` and `unboxRef`. 

```nim
proc defaultBoxer[T](v: T): BoxedValue =
  # ...
  elif T is ref: boxRef(v)
  # ...

proc defaultUnboxer[T](v: BoxedValue): T =
  # ...
  elif T is ref:
    if v.kind == bvRef and not v.refVal.isNil and v.refVal of T:
      cast[T](v.refVal)
    else:
      raise newException(Defect, "Internal unboxing error")
```

### 2. Event-Driven VM Engine

Optimize the VM engine by replacing full-frame scans with specialized pending lists and using a proper `Deque` for the ready queue.

-   **Queue Management**: Replaced `seq[int]` with `Deque[int]` for `readyQ`.
-   **Pending Lists**: Introduced `pendingBvResolve` and `pendingPropagation` deques. Frames are added to these lists only when they transition to a state requiring specific action (e.g., completion of a `bvProgram`).
-   **O(1) Dispatch**: `runLoop` now processes only the frames that are actually ready or pending, eliminating the O(N) scan.

### 3. Strict Error and Boundary Handling

-   **Budget Exhaustion**: `interpret` now explicitly returns `evalFalse(Timeout)` when the execution budget is exceeded.
-   **Instruction Safety**: Added boundary checks for the Instruction Pointer (`pc`) before every operation fetch.
-   **Type Validation**: All `unbox` and `cast` operations now perform `of` type checks to prevent memory safety issues.

### 4. Refactored Standard Handlers

Standard I/O handlers (HTTP, File) now use type-safe `ref object` payloads instead of manual string encoding.

```nim
type
  HttpPostPayload* = ref object of RootObj
    url*, body*, contentType*: string

proc performHttpPost*(url, body: string): Eff[string] =
  perform[string](httpPostTag, boxRef(HttpPostPayload(url: url, body: body)))
```

### 5. Completed Belnap Bilattice

Added `meet` and `negate` operations for the `Eval[T]` type to complete the algebraic bilattice implementation in `semantics.nim`.

## Rationale

### Robustness over "Simplicity"

Previous string-based workarounds for multi-argument effects were simple to implement but fragile and limited. Moving to `ref object` boxing provides a general-purpose, type-safe solution that handles any content (including binary data or nested objects).

### Scalability by Design

The move from O(N) scans to O(1) event-driven dispatch is essential for systems where hundreds or thousands of effectful tasks might run concurrently (e.g., complex sensor fusion or large-scale policy engines).

### Fail-Fast Principle

Silent failures are the most expensive bugs to debug. Explicit `Timeout` errors and `Defect` on type mismatches ensure that issues are caught and diagnosed immediately at the source.

## Consequences

### Positive

-   **Type Safety**: User-defined types can be passed through effects with full runtime type checking.
-   **Performance**: VM execution overhead is constant regardless of the total number of frames.
-   **Zero Warnings**: The codebase compiles cleanly with `--warningAsError:on`.
-   **Logical Completeness**: `Eval[T]` now fully supports all Belnap bilattice operations.

### Negative

-   **Minor Allocation Overhead**: Boxing `ref object` involves an extra allocation compared to raw primitives (mitigated by Nim's efficient ORC/ARC).
-   **Strictness**: Code that relied on "soft" unboxing (returning `nil` on mismatch) will now crash, requiring developers to be explicit about their types.

### Neutral

-   **Breaking Changes**: Handlers relying on the old newline-separated string payload format must be updated to use the new `ref object` payloads.

## Examples

### Using Ref Payloads in Handlers

```nim
let handler = proc(payload: BoxedValue, resume, abort: proc) =
  let data = cast[HttpPostPayload](payload.refVal) # Safe due to internal 'of' check in unboxer
  echo "Posting to: ", data.url
  resume(boxStr("OK"))
```

### Exhaustive Truth Table Verification

The test suite now includes exhaustive 4x4 matrix checks for all Belnap operations, ensuring 100% logic coverage in `semantics.nim`.
