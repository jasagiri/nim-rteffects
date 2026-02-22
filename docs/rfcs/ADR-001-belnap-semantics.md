# ADR-001: Belnap 4-valued Semantics

## Status

Accepted

## Context

RTEffects v1 uses `Result[T]` with `isOk: bool` — a 2-valued evaluation model.
This cannot represent:

- **Suspended computation** (N): A task awaiting I/O or another task has neither
  succeeded nor failed. v1 represents this as "still running" in the task state
  machine, but this information is invisible to the evaluation layer.

- **Contradictory results** (B): A `race` of two tasks where one succeeds and
  one fails before cancellation propagates produces both a value and an error.
  v1 discards one arbitrarily.

Handler authors need to reason about these states to implement:
- `suspend()`: Pause computation, return N
- `fork()`: Run multiple branches, producing potential B at merge points
- `resolve()`: Collapse B to T or F based on handler logic

## Decision

Introduce Belnap's 4-valued logic (First-Degree Entailment) as the evaluation
semantics layer.

### TruthValue

```nim
type
  TruthValue* = enum
    tvTrue    ## Definite value exists
    tvFalse   ## Definite failure exists
    tvBoth    ## Contradictory: both value and failure
    tvNeither ## Undetermined: neither value nor failure
```

### Belnap Lattice

The four values form a De Morgan lattice with two orderings:

**Information ordering** (≤_i): How much information we have
```
        tvBoth
       /      \
  tvTrue      tvFalse
       \      /
       tvNeither
```

**Truth ordering** (≤_t): How "true" the value is
```
        tvTrue
       /      \
  tvBoth     tvNeither
       \      /
       tvFalse
```

**Operations** (on information ordering):

| Operation | Definition | Property |
|-----------|-----------|----------|
| `join(a, b)` | Least upper bound in ≤_k | Commutative, associative, idempotent |
| `meet(a, b)` | Greatest lower bound in ≤_k | Commutative, associative, idempotent |
| `negate(a)` | Logical negation (T↔F, B→B, N→N) | Involution: negate(negate(a)) = a |

Note: `negate` is the **logical** negation. De Morgan laws hold for truth ordering
operations (∨, ∧), NOT for information ordering operations (join, meet). This is a
fundamental property of Belnap's bilattice FOUR. Absorption laws hold for both:
`join(a, meet(a, b)) == a` and `meet(a, join(a, b)) == a`.

**Join table**:

| join | T | F | B | N |
|------|---|---|---|---|
| T | T | B | B | T |
| F | B | F | B | F |
| B | B | B | B | B |
| N | T | F | B | N |

**Negate table**:

| a | negate(a) |
|---|-----------|
| T | F |
| F | T |
| B | B |
| N | N |

### Eval[T]

```nim
type
  Eval*[T] = object
    truth*: TruthValue
    value*: Option[T]
    error*: Option[RtError]
```

Invariants:
- `tvTrue` → `value.isSome`, `error.isNone`
- `tvFalse` → `value.isNone`, `error.isSome`
- `tvBoth` → `value.isSome`, `error.isSome`
- `tvNeither` → `value.isNone`, `error.isNone`

### Operations on Eval[T]

```nim
proc map*[T, U](ev: Eval[T], f: proc(v: T): U): Eval[U]
  ## Transform value if present (tvTrue or tvBoth). Error and truth preserved.

proc flatMap*[T, U](ev: Eval[T], f: proc(v: T): Eval[U]): Eval[U]
  ## Chain evaluation. Invokes f when value is present.
  ## For tvBoth, inner result's truth is joined with tvBoth.

proc leqI*(a, b: TruthValue): bool
  ## Information ordering: a <=i b iff join(a, b) == b.
```

### ACL Collapse (4-value → 2-value)

```nim
proc toResult*[T](ev: Eval[T]): Result[T] {.raises: [].} =
  case ev.truth
  of tvTrue:    ok(ev.value.get)
  of tvFalse:   err(ev.error.get)
  of tvBoth:    err(RtError(kind: Contradiction, msg: "contradictory evaluation"))
  of tvNeither: err(RtError(kind: Incomplete, msg: "incomplete evaluation"))
```

This is the **only** boundary where 4-valued collapses to 2-valued.

## Rationale

### vs. 2-valued (current)

2-valued cannot distinguish N (suspended) from F (failed), nor represent B
(contradictory). Handler authors lose information they need.

### vs. 3-valued (Kleene)

Kleene logic `{T, F, U}` merges B and N into a single "unknown." But
"contradictory" (received conflicting information) and "unknown" (received no
information) are operationally distinct. A handler should `resolve` contradictions
but `wait` on unknowns.

### vs. Monadic error types (Either/Result with rich errors)

Rich error types can encode N and B as error variants, but this collapses the
lattice structure. You lose `join`, `meet`, and `negate` as composable operations.
The lattice properties guarantee that combining evaluations is well-defined.

## Consequences

### Positive

- Handler authors can distinguish all four evaluation states
- Lattice operations compose evaluation results mathematically
- De Morgan laws enable algebraic reasoning about negation
- App developers are unaffected (they only see `Result[T]`)

### Negative

- Additional complexity in the evaluation layer
- `tvBoth` scenarios must be carefully designed (when does B arise?)
- New error kinds (`Contradiction`, `Incomplete`) needed in RtErrorKind

### Neutral

- TruthValue is a 4-element enum — negligible runtime cost
- Eval[T] adds one enum + two Options vs. Result[T]'s one bool

## Examples

### Before (v1)

```nim
# Race: first to complete wins, others cancelled
let result = runDefault(race(@[taskA(), taskB()]))
# result: Result[T] — we lost information about the other task
```

### After (v2 — handler author perspective)

```nim
# Handler for race effect (conceptual — future extension)
proc raceHandler(payload: BoxedValue,
                 resume: proc(v: BoxedValue) {.gcsafe.},
                 abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  # Run all branches, collect evaluations
  let branches = unboxBranches(payload)
  var evals: seq[Eval[T]]
  for b in branches:
    evals.add(interpret(b))

  # Merge: join all truth values
  var merged = evalNeither[T]()
  for ev in evals:
    merged = Eval[T](truth: join(merged.truth, ev.truth),
                      value: if ev.value.isSome: ev.value else: merged.value,
                      error: if ev.error.isSome: ev.error else: merged.error)

  case merged.truth
  of tvTrue: resume(boxValue(merged.value.get))
  of tvFalse: abort(merged.error.get)
  of tvBoth: resume(boxValue(pickFirst(evals)))  # handler decides
  of tvNeither: discard  # implicit suspend — neither resume nor abort called
```
