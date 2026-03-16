## ex10: Policy Engine — Belnap 4-Valued Logic for Access Control
##
## An access control system where multiple rules may contradict each other.
## Classical (2-valued) logic forces picking one winner when rules conflict.
## Belnap 4-valued logic preserves the contradiction (tvBoth) so the system
## can detect and escalate policy conflicts rather than silently choosing.
##
## TruthValue semantics in this context:
##   tvTrue    — all consulted rules permit access (consistent ALLOW)
##   tvFalse   — all consulted rules deny access (consistent DENY)
##   tvBoth    — at least one rule allows AND at least one denies (CONFLICT)
##   tvNeither — no rule has an opinion yet (UNDECIDED / needs more info)

import std/options
import std/strutils
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# ---------------------------------------------------------------------------
# Policy rule primitives
#
# Each rule is modelled as an Eff[bool] that either:
#   - succeeds (pure(true))  → the rule allows the request
#   - fails    (fail(...))   → the rule denies the request
# Interpreting the Eff[bool] yields an Eval[bool] with a TruthValue.
# ---------------------------------------------------------------------------

proc rulePermit(): Eff[bool] =
  ## A rule that explicitly permits.
  pure[bool](true)

proc ruleBlock(): Eff[bool] =
  ## A rule that explicitly denies.
  fail[bool](RtError(kind: ForeignError, msg: "rule: access denied"))

proc ruleNoOpinion(): Eff[bool] =
  ## A rule that defers to another handler (no opinion).
  ## Without a handler installed the effect is unhandled → tvFalse in the
  ## engine, but we want tvNeither here, so we represent it as an unhandled
  ## perform and then recover: if the Eval is tvFalse due to ForeignError we
  ## treat it as tvNeither when combining.
  perform[bool](EffectTag("policy.abstain"))

# ---------------------------------------------------------------------------
# Combine two Eval[bool] results using Belnap join on their TruthValues.
# The bool payload is secondary; what matters is the truth lattice position.
# ---------------------------------------------------------------------------

proc combineRules(a, b: Eval[bool]): Eval[bool] =
  ## Merge two rule evaluations using the information join (least upper bound).
  ## join(tvTrue,    tvTrue)    = tvTrue    (both allow)
  ## join(tvFalse,   tvFalse)   = tvFalse   (both deny)
  ## join(tvTrue,    tvFalse)   = tvBoth    (conflict)
  ## join(tvNeither, tvTrue)    = tvTrue    (one has opinion)
  ## join(tvNeither, tvFalse)   = tvFalse   (one has opinion)
  ## join(tvNeither, tvNeither) = tvNeither (no opinion yet)
  let combined = join(a.truth, b.truth)
  case combined
  of tvTrue:
    evalTrue[bool](true)
  of tvFalse:
    let e = if a.error.isSome: a.error.get
            else: b.error.get(RtError(kind: ForeignError, msg: "denied"))
    evalFalse[bool](e)
  of tvBoth:
    let e = a.error.get(
      b.error.get(RtError(kind: Contradiction, msg: "policy conflict")))
    evalBoth[bool](true, e)
  of tvNeither:
    evalNeither[bool]()

# ---------------------------------------------------------------------------
# resolvePolicy: map TruthValue → human-readable decision string
# ---------------------------------------------------------------------------

proc resolvePolicy(ev: Eval[bool]): string =
  case ev.truth
  of tvTrue:    "ALLOW  — all rules agree: access granted"
  of tvFalse:   "DENY   — all rules agree: access denied"
  of tvBoth:    "CONFLICT — rules contradict; escalate to administrator"
  of tvNeither: "UNDECIDED — no rule has rendered a verdict yet"

# ---------------------------------------------------------------------------
# Helper: evaluate a rule Eff[bool], mapping tvFalse-from-unhandled to
# tvNeither so that abstaining rules don't pollute the join.
# ---------------------------------------------------------------------------

proc evalRule(eff: Eff[bool]): Eval[bool] =
  let ev = interpret[bool](eff)
  # An unhandled perform returns tvFalse with ForeignError containing
  # "unhandled effect:" — we reclassify that as tvNeither (no opinion).
  if ev.truth == tvFalse and ev.error.isSome and
      ev.error.get.kind == ForeignError and
      ev.error.get.msg.startsWith("unhandled effect:"):
    evalNeither[bool]()
  else:
    ev

# ---------------------------------------------------------------------------
# Demonstration
# ---------------------------------------------------------------------------

echo "=== Policy Engine: Belnap 4-Valued Access Control ==="

# --- Scenario 1: Both rules allow → tvTrue (consistent ALLOW) ---
echo "\n-- Scenario 1: Rule A = ALLOW, Rule B = ALLOW --"
let evA1 = evalRule(rulePermit())
let evB1 = evalRule(rulePermit())
let combined1 = combineRules(evA1, evB1)
echo "Rule A truth:    ", evA1.truth           # tvTrue
echo "Rule B truth:    ", evB1.truth           # tvTrue
echo "Combined truth:  ", combined1.truth      # tvTrue
echo "Decision:        ", resolvePolicy(combined1)
assert combined1.truth == tvTrue

# --- Scenario 2: Both rules deny → tvFalse (consistent DENY) ---
echo "\n-- Scenario 2: Rule A = DENY, Rule B = DENY --"
let evA2 = evalRule(ruleBlock())
let evB2 = evalRule(ruleBlock())
let combined2 = combineRules(evA2, evB2)
echo "Rule A truth:    ", evA2.truth           # tvFalse
echo "Rule B truth:    ", evB2.truth           # tvFalse
echo "Combined truth:  ", combined2.truth      # tvFalse
echo "Decision:        ", resolvePolicy(combined2)
assert combined2.truth == tvFalse

# --- Scenario 3: Rule A allows, Rule B denies → tvBoth (CONFLICT) ---
echo "\n-- Scenario 3: Rule A = ALLOW, Rule B = DENY --"
let evA3 = evalRule(rulePermit())
let evB3 = evalRule(ruleBlock())
let combined3 = combineRules(evA3, evB3)
echo "Rule A truth:    ", evA3.truth           # tvTrue
echo "Rule B truth:    ", evB3.truth           # tvFalse
echo "Combined truth:  ", combined3.truth      # tvBoth
echo "Decision:        ", resolvePolicy(combined3)
assert combined3.truth == tvBoth

# --- Scenario 4: One rule abstains, other allows → tvTrue ---
echo "\n-- Scenario 4: Rule A = NO OPINION, Rule B = ALLOW --"
let evA4 = evalRule(ruleNoOpinion())
let evB4 = evalRule(rulePermit())
let combined4 = combineRules(evA4, evB4)
echo "Rule A truth:    ", evA4.truth           # tvNeither
echo "Rule B truth:    ", evB4.truth           # tvTrue
echo "Combined truth:  ", combined4.truth      # tvTrue (join(N,T)=T)
echo "Decision:        ", resolvePolicy(combined4)
assert combined4.truth == tvTrue

# --- Scenario 5: Both rules abstain → tvNeither (UNDECIDED) ---
echo "\n-- Scenario 5: Rule A = NO OPINION, Rule B = NO OPINION --"
let evA5 = evalRule(ruleNoOpinion())
let evB5 = evalRule(ruleNoOpinion())
let combined5 = combineRules(evA5, evB5)
echo "Rule A truth:    ", evA5.truth           # tvNeither
echo "Rule B truth:    ", evB5.truth           # tvNeither
echo "Combined truth:  ", combined5.truth      # tvNeither
echo "Decision:        ", resolvePolicy(combined5)
assert combined5.truth == tvNeither

# --- Scenario 6: Three rules — demonstrate chained join ---
echo "\n-- Scenario 6: Three rules: ALLOW + DENY + NO OPINION --"
let evC1 = evalRule(rulePermit())   # tvTrue
let evC2 = evalRule(ruleBlock())    # tvFalse
let evC3 = evalRule(ruleNoOpinion()) # tvNeither
let step1 = combineRules(evC1, evC2)  # tvBoth (conflict detected)
let final6 = combineRules(step1, evC3) # join(tvBoth, tvNeither) = tvBoth
echo "After join(ALLOW, DENY):           ", step1.truth  # tvBoth
echo "After join(tvBoth, NO OPINION):    ", final6.truth # tvBoth
echo "Decision:                          ", resolvePolicy(final6)
assert final6.truth == tvBoth

# --- Scenario 7: Demonstrate ACL collapse via toResult ---
echo "\n-- Scenario 7: ACL collapse (4-value -> 2-value) --"
let r_allow   = toResult(combined1)  # tvTrue  → isOk=true
let r_deny    = toResult(combined2)  # tvFalse → isOk=false
let r_conflict = toResult(combined3) # tvBoth  → isOk=false, Contradiction
let r_undecided = toResult(combined5) # tvNeither → isOk=false, Incomplete
echo "ALLOW collapsed:     isOk=", r_allow.isOk         # true
echo "DENY collapsed:      isOk=", r_deny.isOk          # false
echo "CONFLICT collapsed:  err=", r_conflict.err.kind   # Contradiction
echo "UNDECIDED collapsed: err=", r_undecided.err.kind  # Incomplete
assert r_allow.isOk
assert not r_deny.isOk
assert r_conflict.err.kind == Contradiction
assert r_undecided.err.kind == Incomplete

echo "\nAll ex10 checks passed."
