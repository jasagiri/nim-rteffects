## ex09: Speculative Execution via Belnap 4-Valued Logic
##
## Run two independent strategies for the same computation.
## Combine their Eval[T] results using lattice `join` to accumulate knowledge.
##
## Scenarios:
##   fast path succeeds, slow path fails  → join(tvTrue, tvFalse)  = tvBoth  (contradiction)
##   both strategies succeed              → join(tvTrue, tvTrue)   = tvTrue
##   both strategies fail                 → join(tvFalse, tvFalse) = tvFalse
##   one succeeds, other incomplete       → join(tvTrue, tvNeither) = tvTrue  (we have info)
##
## The contradiction case (tvBoth) is meaningful: two authoritative sources
## disagree. The system can detect this and escalate rather than silently
## picking one answer.

import std/options
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# ---------------------------------------------------------------------------
# Helper: combine two Eval[T] results using knowledge-ordering join.
# When both carry a value, we keep the first strategy's value (fast path wins)
# but still record the contradiction in the truth dimension.
# ---------------------------------------------------------------------------

proc combineEval[T](a, b: Eval[T]): Eval[T] {.raises: [].} =
  ## Accumulate knowledge from two independent evaluations.
  ## Truth is joined (LUB in information ordering).
  ## Value comes from whichever side has one (a preferred over b).
  ## Error comes from whichever side has one (a preferred over b).
  let combinedTruth = join(a.truth, b.truth)
  let combinedValue = if a.value.isSome: a.value else: b.value
  let combinedError = if a.error.isSome: a.error else: b.error
  Eval[T](truth: combinedTruth, value: combinedValue, error: combinedError)

# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# Strategy A: fast path — pure computation, always succeeds with 42
let strategyA: Eff[int] = pure[int](42)

# Strategy B: slow path — always fails with Timeout
let strategyB: Eff[int] = fail[int](RtError(kind: Timeout, msg: "slow path timed out"))

# ---------------------------------------------------------------------------
# Scenario 1: fast path succeeds, slow path fails
# Expected: join(tvTrue, tvFalse) = tvBoth  → contradiction detected
# ---------------------------------------------------------------------------
echo "=== Scenario 1: fast path OK, slow path Timeout ==="

let evA1 = interpret[int](strategyA)
let evB1 = interpret[int](strategyB)
let combined1 = combineEval(evA1, evB1)

echo "strategyA: truth=", evA1.truth, " value=", evA1.value
echo "strategyB: truth=", evB1.truth, " error=", evB1.error.get.kind
echo "combined:  truth=", combined1.truth   # tvBoth

assert combined1.truth == tvBoth, "expected contradiction (tvBoth)"
assert combined1.value.isSome,    "value from fast path preserved"
assert combined1.error.isSome,    "error from slow path preserved"

let result1 = toResult(combined1)
assert not result1.isOk
assert result1.err.kind == Contradiction
echo "toResult: err.kind=", result1.err.kind, " (contradiction detected — escalate!)"

# ---------------------------------------------------------------------------
# Scenario 2: both strategies succeed (same value)
# Expected: join(tvTrue, tvTrue) = tvTrue  → confident answer
# ---------------------------------------------------------------------------
echo "\n=== Scenario 2: both strategies succeed ==="

let strategyC: Eff[int] = pure[int](42)   # independent confirmation

let evA2 = interpret[int](strategyA)
let evC2 = interpret[int](strategyC)
let combined2 = combineEval(evA2, evC2)

echo "strategyA: truth=", evA2.truth, " value=", evA2.value
echo "strategyC: truth=", evC2.truth, " value=", evC2.value
echo "combined:  truth=", combined2.truth  # tvTrue

assert combined2.truth == tvTrue
assert combined2.value == some(42)

let result2 = toResult(combined2)
assert result2.isOk
echo "toResult: isOk=", result2.isOk, " ok=", result2.ok, " (confident!)"

# ---------------------------------------------------------------------------
# Scenario 3: both strategies fail
# Expected: join(tvFalse, tvFalse) = tvFalse  → definite failure
# ---------------------------------------------------------------------------
echo "\n=== Scenario 3: both strategies fail ==="

let strategyD: Eff[int] = fail[int](RtError(kind: Cancelled, msg: "cancelled"))

let evB3 = interpret[int](strategyB)   # Timeout
let evD3 = interpret[int](strategyD)   # Cancelled
let combined3 = combineEval(evB3, evD3)

echo "strategyB: truth=", evB3.truth, " error=", evB3.error.get.kind
echo "strategyD: truth=", evD3.truth, " error=", evD3.error.get.kind
echo "combined:  truth=", combined3.truth  # tvFalse

assert combined3.truth == tvFalse
assert combined3.value.isNone

let result3 = toResult(combined3)
assert not result3.isOk
echo "toResult: err.kind=", result3.err.kind, " (definite failure)"

# ---------------------------------------------------------------------------
# Scenario 4: one succeeds, other incomplete (tvNeither — e.g. still running)
# Expected: join(tvTrue, tvNeither) = tvTrue  → partial info is enough
# ---------------------------------------------------------------------------
echo "\n=== Scenario 4: fast path OK, slow path incomplete ==="

# tvNeither represents a computation that has not yet produced any result
# (e.g. waiting on I/O). We construct it directly to simulate that state.
let evIncomplete = evalNeither[int]()

let evA4 = interpret[int](strategyA)
let combined4 = combineEval(evA4, evIncomplete)

echo "strategyA:   truth=", evA4.truth,       " value=", evA4.value
echo "incomplete:  truth=", evIncomplete.truth
echo "combined:    truth=", combined4.truth    # tvTrue

assert combined4.truth == tvTrue
assert combined4.value == some(42)

let result4 = toResult(combined4)
assert result4.isOk
echo "toResult: isOk=", result4.isOk, " ok=", result4.ok,
     " (fast path wins; slow path still pending)"

# ---------------------------------------------------------------------------
# Summary: Belnap truth lattice drives speculative execution policy
# ---------------------------------------------------------------------------
echo "\n=== Policy summary ==="
echo "tvTrue    → use the value with confidence"
echo "tvFalse   → all paths failed; propagate error"
echo "tvBoth    → contradiction; escalate / raise alarm"
echo "tvNeither → no information yet; wait or time out"

echo "\nAll ex09 checks passed."
