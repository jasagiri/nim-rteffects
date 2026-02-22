## Belnap 4-valued evaluation semantics.
##
## Provides TruthValue {tvTrue, tvFalse, tvBoth, tvNeither} forming
## a De Morgan lattice with information ordering.
##
## This module is pure math — no side effects, no runtime dependency.

type
  TruthValue* = enum
    tvTrue    ## Computation succeeded with definite value
    tvFalse   ## Computation failed with definite error
    tvBoth    ## Contradictory: both value and failure exist
    tvNeither ## Undetermined: neither value nor failure yet

# Belnap lattice: information ordering
#
#         tvBoth
#        /      \
#   tvTrue      tvFalse
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
