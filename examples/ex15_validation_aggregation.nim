## ex15: Validation Result Aggregation via Belnap 4-Valued Logic
##
## A form validation system where multiple independent validators check
## different aspects of input data. Instead of short-circuiting on the
## first failure (classical approach), Belnap logic accumulates ALL
## validation knowledge and surfaces contradictions explicitly.
##
## Each validator is an Eff[string] that either succeeds with "ok"
## or fails with a domain-specific RtError. After interpreting each
## validator to Eval[string], their truth values are combined with `join`
## (least upper bound in information ordering), which accumulates knowledge
## rather than masking it.
##
## KEY INSIGHT: tvBoth does not mean "give up". It means
##   "we have positive evidence from at least one validator AND
##    negative evidence from at least one validator."
##   Classical logic collapses this to "invalid" and loses the positive
##   signal. Belnap logic preserves both sides so the caller can report
##   which specific fields are valid and which are not.
##
## join lattice (information ordering — accumulates knowledge):
##   tvNeither + anything  → anything   (no-op: adds nothing)
##   tvTrue    + tvTrue    → tvTrue     (unanimous pass)
##   tvFalse   + tvFalse   → tvFalse    (unanimous fail)
##   tvTrue    + tvFalse   → tvBoth     (contradiction: partial validity)
##
## meet lattice (truth ordering — consensus):
##   tvTrue    meet tvTrue  → tvTrue    (all agree: pass)
##   tvTrue    meet tvFalse → tvNeither (no consensus: inconclusive)
##   tvFalse   meet tvFalse → tvFalse   (all agree: fail)

import std/options
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# ---------------------------------------------------------------------------
# Validator helpers
# ---------------------------------------------------------------------------

proc validatorPass(label: string): Eff[string] =
  ## A validator that passes, carrying its label as the success value.
  pure[string](label & ": ok")

proc validatorFail(label: string, reason: string): Eff[string] =
  ## A validator that fails with a descriptive ForeignError.
  fail[string](RtError(kind: ForeignError, msg: label & ": " & reason))

# ---------------------------------------------------------------------------
# Aggregate a sequence of Eval[string] results.
# join accumulates knowledge across ALL validators.
# ---------------------------------------------------------------------------

proc aggregateValidations(evals: seq[Eval[string]]): Eval[string] {.raises: [].} =
  ## Fold all validation Evals using join.
  ## Starts from tvNeither (the bottom of the information lattice — "no info").
  ## Each eval contributes whatever it knows; nothing is discarded.
  result = evalNeither[string]()
  for ev in evals:
    let combinedTruth = join(result.truth, ev.truth)
    # Value: keep the first success message encountered
    let combinedValue = if result.value.isSome: result.value else: ev.value
    # Error: keep the first failure encountered
    let combinedError = if result.error.isSome: result.error else: ev.error
    result = Eval[string](
      truth: combinedTruth,
      value: combinedValue,
      error: combinedError,
    )

proc consensusValidations(evals: seq[Eval[string]]): Eval[string] {.raises: [].} =
  ## Fold all validation Evals using meet (consensus).
  ## Starts from tvBoth (the top — "all information, wait for consensus to reduce it").
  ## Only survives as tvTrue if EVERY validator passes; any failure degrades it.
  result = evalBoth[string]("", RtError(kind: ForeignError, msg: "initial"))
  for ev in evals:
    let combinedTruth = meet(result.truth, ev.truth)
    let combinedValue = if ev.value.isSome: ev.value else: result.value
    let combinedError = if ev.error.isSome: ev.error else: result.error
    result = Eval[string](
      truth: combinedTruth,
      value: combinedValue,
      error: combinedError,
    )

# ---------------------------------------------------------------------------
# Scenario 1: all validators pass → tvTrue (unanimous pass)
# ---------------------------------------------------------------------------
echo "=== Scenario 1: all validators pass ==="

let ev1a = interpret[string](validatorPass("email"))
let ev1b = interpret[string](validatorPass("username"))
let ev1c = interpret[string](validatorPass("password"))

echo "email:    truth=", ev1a.truth
echo "username: truth=", ev1b.truth
echo "password: truth=", ev1c.truth

let agg1 = aggregateValidations(@[ev1a, ev1b, ev1c])
echo "aggregate truth=", agg1.truth   # tvTrue

assert agg1.truth == tvTrue, "all pass → tvTrue"
assert agg1.value.isSome
let res1 = toResult(agg1)
assert res1.isOk
echo "toResult: isOk=", res1.isOk, " (all clear)"

# ---------------------------------------------------------------------------
# Scenario 2: mixed pass and fail → tvBoth (contradictory: partial validity)
# ---------------------------------------------------------------------------
echo "\n=== Scenario 2: some pass, some fail ==="

let ev2a = interpret[string](validatorPass("email"))
let ev2b = interpret[string](validatorFail("username", "already taken"))
let ev2c = interpret[string](validatorPass("password"))
let ev2d = interpret[string](validatorFail("age", "must be >= 18"))

echo "email:    truth=", ev2a.truth
echo "username: truth=", ev2b.truth, " error=", ev2b.error.get.msg
echo "password: truth=", ev2c.truth
echo "age:      truth=", ev2d.truth, " error=", ev2d.error.get.msg

let agg2 = aggregateValidations(@[ev2a, ev2b, ev2c, ev2d])
echo "aggregate truth=", agg2.truth   # tvBoth

assert agg2.truth == tvBoth, "mixed → tvBoth (contradiction)"
assert agg2.value.isSome,  "partial value from passing validators preserved"
assert agg2.error.isSome,  "error from failing validators preserved"

let res2 = toResult(agg2)
assert not res2.isOk
assert res2.err.kind == Contradiction
echo "toResult: err.kind=", res2.err.kind,
     " — contradiction: report specific failures, acknowledge partial validity"

# ---------------------------------------------------------------------------
# Scenario 3: all validators fail → tvFalse (totally invalid)
# ---------------------------------------------------------------------------
echo "\n=== Scenario 3: all validators fail ==="

let ev3a = interpret[string](validatorFail("email", "invalid format"))
let ev3b = interpret[string](validatorFail("username", "too short"))
let ev3c = interpret[string](validatorFail("password", "too weak"))

echo "email:    truth=", ev3a.truth
echo "username: truth=", ev3b.truth
echo "password: truth=", ev3c.truth

let agg3 = aggregateValidations(@[ev3a, ev3b, ev3c])
echo "aggregate truth=", agg3.truth   # tvFalse

assert agg3.truth == tvFalse, "all fail → tvFalse"
assert agg3.value.isNone
assert agg3.error.isSome

let res3 = toResult(agg3)
assert not res3.isOk
echo "toResult: err.kind=", res3.err.kind, " (totally invalid)"

# ---------------------------------------------------------------------------
# Scenario 4: some validators skipped (tvNeither) → tvNeither contributes nothing
# ---------------------------------------------------------------------------
echo "\n=== Scenario 4: skipped validators (tvNeither) contribute nothing ==="

# Simulate validators that could not run (dependent field missing, etc.)
# We construct evalNeither directly to represent "no information yet".
let evSkip1 = evalNeither[string]()
let evSkip2 = evalNeither[string]()
let ev4pass = interpret[string](validatorPass("email"))

echo "skip1: truth=", evSkip1.truth, " (no info)"
echo "skip2: truth=", evSkip2.truth, " (no info)"
echo "email: truth=", ev4pass.truth

let agg4 = aggregateValidations(@[evSkip1, evSkip2, ev4pass])
echo "aggregate truth=", agg4.truth   # tvTrue (only the passing validator contributed)

assert agg4.truth == tvTrue,
  "tvNeither adds no information; single passing validator wins"
assert agg4.value.isSome

let res4 = toResult(agg4)
assert res4.isOk
echo "toResult: isOk=", res4.isOk, " (skipped validators silent; email passes)"

# ---------------------------------------------------------------------------
# join vs meet: what do they answer?
# ---------------------------------------------------------------------------
echo "\n=== join vs meet: accumulation vs consensus ==="

let evPass = interpret[string](validatorPass("field-a"))
let evFail = interpret[string](validatorFail("field-b", "invalid"))

# join: "what do we know overall?" — accumulates ALL information
let joined = aggregateValidations(@[evPass, evFail])
echo "join(tvTrue, tvFalse) = ", joined.truth   # tvBoth

# meet: "what do ALL validators agree on?" — consensus
let met = consensusValidations(@[evPass, evFail])
echo "meet(tvTrue, tvFalse) = ", met.truth       # tvNeither (no consensus)

assert joined.truth == tvBoth,    "join: contradiction detected"
assert met.truth    == tvNeither, "meet: no consensus — inconclusive"

# When all agree:
let evPass2 = interpret[string](validatorPass("field-c"))
let metAll  = consensusValidations(@[evPass, evPass2])
echo "meet(tvTrue, tvTrue) = ", metAll.truth     # tvTrue

assert metAll.truth == tvTrue, "meet: unanimous pass"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "\n=== Summary ==="
echo "join = accumulate knowledge — 'what signals do we have?'"
echo "  tvNeither + X  → X          (adds nothing)"
echo "  tvTrue  + tvTrue  → tvTrue  (unanimous pass)"
echo "  tvFalse + tvFalse → tvFalse (unanimous fail)"
echo "  tvTrue  + tvFalse → tvBoth  (contradiction: partial validity)"
echo ""
echo "meet = consensus — 'what do ALL validators agree on?'"
echo "  tvTrue  meet tvTrue  → tvTrue    (all agree: pass)"
echo "  tvFalse meet tvFalse → tvFalse   (all agree: fail)"
echo "  tvTrue  meet tvFalse → tvNeither (disagree: inconclusive)"
echo ""
echo "tvBoth at ACL boundary → Contradiction error"
echo "  classical: binary valid/invalid (information lost)"
echo "  Belnap:    contradiction surfaced → caller reports which fields fail"

echo "\nAll ex15 checks passed."
