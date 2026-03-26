## Belnap 4-valued evaluation semantics.
##
## Provides TruthValue {tvTrue, tvFalse, tvBoth, tvNeither} forming
## a bilattice with knowledge and truth orderings.
##
## Eval[T] wraps a computation result with its TruthValue, providing
## the 4-valued evaluation type that collapses to Result[T] at the
## runner boundary.
##
## This module is pure — no side effects, no runtime dependency.

import std/options
import ./core

type
  TruthValue* = enum
    tvTrue    ## Computation succeeded with definite value
    tvFalse   ## Computation failed with definite error
    tvBoth    ## Contradictory: both value and failure exist
    tvNeither ## Undetermined: neither value nor failure yet

# Belnap lattice: information ordering
#
#         tvBoth
#        /      #   tvTrue      tvFalse
#        \      /
#        tvNeither

const joinTable: array[TruthValue, array[TruthValue, TruthValue]] = [
  # tvTrue:
  [tvTrue, tvBoth, tvBoth, tvTrue],
  # tvFalse:
  [tvBoth, tvFalse, tvBoth, tvFalse],
  # tvBoth:
  [tvBoth, tvBoth, tvBoth, tvBoth],
  # tvNeither:
  [tvTrue, tvFalse, tvBoth, tvNeither],
]

const meetTable: array[TruthValue, array[TruthValue, TruthValue]] = [
  # tvTrue:
  [tvTrue, tvNeither, tvTrue, tvNeither],
  # tvFalse:
  [tvNeither, tvFalse, tvFalse, tvNeither],
  # tvBoth:
  [tvTrue, tvFalse, tvBoth, tvNeither],
  # tvNeither:
  [tvNeither, tvNeither, tvNeither, tvNeither],
]

const negateTable: array[TruthValue, TruthValue] = [
  tvFalse,   # negate(tvTrue) = tvFalse
  tvTrue,    # negate(tvFalse) = tvTrue
  tvBoth,    # negate(tvBoth) = tvBoth
  tvNeither, # negate(tvNeither) = tvNeither
]

proc join*(a, b: TruthValue): TruthValue {.raises: [].} =
  ## Least upper bound in information ordering.
  joinTable[a][b]

proc meet*(a, b: TruthValue): TruthValue {.raises: [].} =
  ## Greatest lower bound in information ordering.
  meetTable[a][b]

proc negate*(a: TruthValue): TruthValue {.raises: [].} =
  ## De Morgan negation. negate(negate(a)) == a.
  negateTable[a]

proc leqI*(a, b: TruthValue): bool {.raises: [].} =
  ## Information ordering: a <=i b iff join(a, b) == b.
  join(a, b) == b

# --- Eval[T]: 4-valued evaluation result ---

type
  Eval*[T] = object
    ## A computation result with 4-valued truth.
    ## Invariants:
    ##   tvTrue    → value.isSome, error.isNone
    ##   tvFalse   → value.isNone, error.isSome
    ##   tvBoth    → value.isSome, error.isSome
    ##   tvNeither → value.isNone, error.isNone
    truth*: TruthValue
    value*: Option[T]
    error*: Option[RtError]

proc evalTrue*[T](v: T): Eval[T] {.raises: [].} =
  Eval[T](truth: tvTrue, value: some(v), error: none(RtError))

proc evalFalse*[T](e: RtError): Eval[T] {.raises: [].} =
  Eval[T](truth: tvFalse, value: none(T), error: some(e))

proc evalBoth*[T](v: T, e: RtError): Eval[T] {.raises: [].} =
  Eval[T](truth: tvBoth, value: some(v), error: some(e))

proc evalNeither*[T](): Eval[T] {.raises: [].} =
  Eval[T](truth: tvNeither, value: none(T), error: none(RtError))

proc map*[T, U](ev: Eval[T], f: proc(v: T): U): Eval[U] =
  ## Transform the value if present (tvTrue or tvBoth).
  ## Error and truth are preserved.
  case ev.truth
  of tvTrue:
    evalTrue(f(ev.value.get))
  of tvFalse:
    evalFalse[U](ev.error.get)
  of tvBoth:
    evalBoth(f(ev.value.get), ev.error.get)
  of tvNeither:
    evalNeither[U]()

proc flatMap*[T, U](ev: Eval[T], f: proc(v: T): Eval[U]): Eval[U] =
  ## Chain evaluation. Only invokes f when value is present (tvTrue or tvBoth).
  ## For tvBoth, the inner result's truth is joined with tvBoth.
  case ev.truth
  of tvTrue:
    f(ev.value.get)
  of tvFalse:
    evalFalse[U](ev.error.get)
  of tvBoth:
    let inner = f(ev.value.get)
    # Preserve the contradictory nature: join truth values
    Eval[U](
      truth: join(tvBoth, inner.truth),
      value: inner.value,
      error: if inner.error.isSome: inner.error else: ev.error,
    )
  of tvNeither:
    evalNeither[U]()

proc join*[T](a, b: Eval[T]): Eval[T] {.raises: [].} =
  ## Join two evaluations in the information lattice.
  ## Values and errors are merged. If both have values/errors,
  ## b's value/error wins unless special logic (like validation) is needed.
  Eval[T](
    truth: join(a.truth, b.truth),
    value: if b.value.isSome: b.value else: a.value,
    error: if b.error.isSome: b.error else: a.error
  )

proc joinValidation*[T](a, b: Eval[T]): Eval[T] {.raises: [].} =
  ## Specialized join for validation that aggregates errors instead of replacing them.
  let mergedTruth = join(a.truth, b.truth)
  let mergedValue = if b.value.isSome: b.value else: a.value
  
  var errors: seq[RtError] = @[]
  if a.error.isSome:
    if a.error.get.kind == AggregateError:
      errors.add(a.error.get.children)
    else:
      errors.add(a.error.get)
  if b.error.isSome:
    if b.error.get.kind == AggregateError:
      errors.add(b.error.get.children)
    else:
      errors.add(b.error.get)
      
  let mergedError = if errors.len == 0: none(RtError)
                    elif errors.len == 1: some(errors[0])
                    else: some(aggregateError(errors))
                    
  Eval[T](truth: mergedTruth, value: mergedValue, error: mergedError)

proc toResult*[T](ev: Eval[T]): Result[T] {.raises: [].} =
  ## ACL: collapse 4-valued Eval to 2-valued Result.
  ## This is the EXIT of the effects system.
  case ev.truth
  of tvTrue:
    ok[T](ev.value.get)
  of tvFalse:
    err[T](ev.error.get)
  of tvBoth:
    err[T](RtError(kind: Contradiction, msg: "contradictory evaluation"))
  of tvNeither:
    err[T](RtError(kind: Incomplete, msg: "incomplete evaluation"))
