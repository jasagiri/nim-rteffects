## ex16: Knowledge Lattice — Belnap Epistemic Reasoning
##
## Models a knowledge base that ingests facts from multiple independent sources.
## Sources may agree, contradict each other, or simply have no opinion.
## The system tracks the epistemic state of each proposition using TruthValue
## without prematurely collapsing contradictions.
##
## TruthValue as epistemic state:
##   tvTrue    — known to be true   (≥1 source asserts, none denies)
##   tvFalse   — known to be false  (≥1 source denies,  none asserts)
##   tvBoth    — contradictory      (some assert, others deny)
##   tvNeither — unknown            (no source has an opinion)
##
## Knowledge accumulation is monotone in the information ordering:
##   tvNeither ≤i tvTrue ≤i tvBoth   (information only grows, never shrinks)
##   tvNeither ≤i tvFalse ≤i tvBoth
##
## This example does not need the effects engine — TruthValue operations are
## pure functions from rteffects/semantics.

import std/tables
import rteffects/semantics

# ---------------------------------------------------------------------------
# KnowledgeBase: a map from proposition name to its current TruthValue.
# The bottom element tvNeither ("we know nothing") is the implicit default.
# ---------------------------------------------------------------------------

type
  KnowledgeBase* = Table[string, TruthValue]

proc initKnowledgeBase*(): KnowledgeBase {.raises: [].} =
  ## Return an empty knowledge base.
  ## Every proposition starts at tvNeither (unknown).
  initTable[string, TruthValue]()

proc addFact*(kb: var KnowledgeBase; prop: string; evidence: TruthValue) {.raises: [].} =
  ## Integrate a new piece of evidence for `prop` using information join.
  ## Join is the least upper bound in the information ordering, so knowledge
  ## can only grow: tvNeither → tvTrue/tvFalse → tvBoth.
  let current = kb.getOrDefault(prop, tvNeither)
  kb[prop] = join(current, evidence)

proc query*(kb: KnowledgeBase; prop: string): TruthValue {.raises: [].} =
  ## Return the current epistemic state of `prop`.
  ## Returns tvNeither when no evidence has been collected.
  kb.getOrDefault(prop, tvNeither)

proc queryNot*(kb: KnowledgeBase; prop: string): TruthValue {.raises: [].} =
  ## Return the epistemic state of the negation of `prop`.
  ## Uses De Morgan negation: negate(tvBoth) = tvBoth (contradiction persists).
  negate(query(kb, prop))

proc consistency*(kb: KnowledgeBase): TruthValue {.raises: [].} =
  ## Compute the meet of all known propositions.
  ## Meet is the greatest lower bound; it expresses "what all sources agree on".
  ## Returns tvNeither for an empty knowledge base (vacuously, no common ground).
  result = tvNeither
  var first = true
  for tv in kb.values:
    if first:
      result = tv
      first = false
    else:
      result = meet(result, tv)

# ---------------------------------------------------------------------------
# Scenario
# ---------------------------------------------------------------------------

echo "=== ex16: Knowledge Lattice ==="

var kb = initKnowledgeBase()

# --- Proposition: "sky is blue" ---
echo "\n--- Proposition: \"sky is blue\" ---"

# Source A asserts it is true.
kb.addFact("sky is blue", tvTrue)
echo "After Source A asserts (tvTrue):  ", query(kb, "sky is blue")   # tvTrue
assert query(kb, "sky is blue") == tvTrue

# Source B independently also asserts it — consistent with A.
kb.addFact("sky is blue", tvTrue)
echo "After Source B asserts (tvTrue):  ", query(kb, "sky is blue")   # tvTrue
assert query(kb, "sky is blue") == tvTrue, "two agreeing assertions stay tvTrue"

# Source C contradicts: asserts it is false.
kb.addFact("sky is blue", tvFalse)
echo "After Source C denies  (tvFalse): ", query(kb, "sky is blue")   # tvBoth
assert query(kb, "sky is blue") == tvBoth, "contradiction produces tvBoth"
echo "Contradiction detected! Sources disagree about \"sky is blue\"."

# --- Proposition: "grass is green" — no evidence yet ---
echo "\n--- Proposition: \"grass is green\" (no evidence) ---"
echo "query result: ", query(kb, "grass is green")   # tvNeither
assert query(kb, "grass is green") == tvNeither, "unknown proposition is tvNeither"

# --- Negation ---
echo "\n--- Negation ---"

# negate(tvTrue) = tvFalse: if we know P is true, ¬P is false.
var kb2 = initKnowledgeBase()
kb2.addFact("it is raining", tvTrue)
echo "\"it is raining\" = ", query(kb2, "it is raining")          # tvTrue
echo "\"it is NOT raining\" = ", queryNot(kb2, "it is raining")  # tvFalse
assert queryNot(kb2, "it is raining") == tvFalse

# negate(tvBoth) = tvBoth: contradiction is a fixed point under negation.
kb2.addFact("it is raining", tvFalse)   # introduce contradiction
echo "After contradiction: \"it is raining\" = ", query(kb2, "it is raining")       # tvBoth
echo "Negating contradiction: \"it is NOT raining\" = ", queryNot(kb2, "it is raining") # tvBoth
assert queryNot(kb2, "it is raining") == tvBoth,
  "negating a contradiction yields another contradiction"
echo "Contradiction is inescapable: negate(tvBoth) = tvBoth."

# negate(tvNeither) = tvNeither: ignorance is symmetric.
var kb3 = initKnowledgeBase()
echo "Negating unknown: ", queryNot(kb3, "unicorns exist")   # tvNeither
assert queryNot(kb3, "unicorns exist") == tvNeither

# --- Consistency ---
echo "\n--- Consistency (meet of all facts) ---"

var kb4 = initKnowledgeBase()
kb4.addFact("A", tvTrue)
kb4.addFact("B", tvTrue)
let cons1 = consistency(kb4)
echo "kb with two tvTrue facts — consistency: ", cons1   # tvTrue
assert cons1 == tvTrue

kb4.addFact("C", tvFalse)
let cons2 = consistency(kb4)
echo "After adding a tvFalse fact — consistency: ", cons2   # tvNeither (no common ground)
assert cons2 == tvNeither,
  "meet(tvTrue, tvFalse) = tvNeither: sources share no common ground"

# --- Information ordering: tvNeither ≤i tvTrue ≤i tvBoth ---
echo "\n--- Information Ordering (leqI) ---"
echo "tvNeither <=i tvTrue:  ", leqI(tvNeither, tvTrue)   # true
echo "tvTrue    <=i tvBoth:  ", leqI(tvTrue, tvBoth)      # true
echo "tvNeither <=i tvBoth:  ", leqI(tvNeither, tvBoth)   # true  (transitive)
echo "tvTrue    <=i tvFalse: ", leqI(tvTrue, tvFalse)     # false (incomparable)
echo "tvFalse   <=i tvTrue:  ", leqI(tvFalse, tvTrue)     # false (incomparable)

assert leqI(tvNeither, tvTrue),  "unknown < definite-true"
assert leqI(tvTrue, tvBoth),     "definite-true < contradictory"
assert leqI(tvNeither, tvBoth),  "unknown < contradictory (transitive)"
assert not leqI(tvTrue, tvFalse), "true and false are incomparable"
assert not leqI(tvFalse, tvTrue), "false and true are incomparable"

# --- Demonstrate monotone accumulation step by step ---
echo "\n--- Monotone Accumulation ---"
var kb5 = initKnowledgeBase()
let prop = "the door is locked"

let s0 = query(kb5, prop)
kb5.addFact(prop, tvTrue)
let s1 = query(kb5, prop)
kb5.addFact(prop, tvFalse)
let s2 = query(kb5, prop)

echo "Before any evidence:   ", s0   # tvNeither
echo "After one assertion:   ", s1   # tvTrue
echo "After contradiction:   ", s2   # tvBoth

assert leqI(s0, s1), "knowledge grew: tvNeither ≤i tvTrue"
assert leqI(s1, s2), "knowledge grew: tvTrue ≤i tvBoth"
echo "Knowledge growth is monotone: tvNeither ≤i tvTrue ≤i tvBoth."

echo "\nAll ex16 checks passed."
