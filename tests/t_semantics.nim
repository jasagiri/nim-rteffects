import std/unittest
import rteffects/semantics

suite "TruthValue Lattice - join":
  test "given tvTrue and tvFalse when joined then tvBoth":
    check join(tvTrue, tvFalse) == tvBoth

  test "given tvTrue and tvNeither when joined then tvTrue":
    check join(tvTrue, tvNeither) == tvTrue

  test "given tvFalse and tvNeither when joined then tvFalse":
    check join(tvFalse, tvNeither) == tvFalse

  test "given tvBoth and tvNeither when joined then tvBoth":
    check join(tvBoth, tvNeither) == tvBoth

  test "given tvTrue and tvTrue when joined then tvTrue":
    check join(tvTrue, tvTrue) == tvTrue

  test "given tvFalse and tvFalse when joined then tvFalse":
    check join(tvFalse, tvFalse) == tvFalse

  test "given tvBoth and tvBoth when joined then tvBoth":
    check join(tvBoth, tvBoth) == tvBoth

  test "given tvNeither and tvNeither when joined then tvNeither":
    check join(tvNeither, tvNeither) == tvNeither

suite "TruthValue Lattice - negate":
  test "given tvTrue when negated then tvFalse":
    check negate(tvTrue) == tvFalse

  test "given tvFalse when negated then tvTrue":
    check negate(tvFalse) == tvTrue

  test "given tvBoth when negated then tvBoth":
    check negate(tvBoth) == tvBoth

  test "given tvNeither when negated then tvNeither":
    check negate(tvNeither) == tvNeither

  test "given any value when negated twice then original":
    for v in TruthValue:
      check negate(negate(v)) == v

suite "TruthValue Lattice - algebraic laws":
  test "given join then it is commutative":
    for a in TruthValue:
      for b in TruthValue:
        check join(a, b) == join(b, a)

  test "given join then it is associative":
    for a in TruthValue:
      for b in TruthValue:
        for c in TruthValue:
          check join(a, join(b, c)) == join(join(a, b), c)

  test "given join then it is idempotent":
    for a in TruthValue:
      check join(a, a) == a

  test "given meet then it is commutative":
    for a in TruthValue:
      for b in TruthValue:
        check meet(a, b) == meet(b, a)

  test "given meet then it is associative":
    for a in TruthValue:
      for b in TruthValue:
        for c in TruthValue:
          check meet(a, meet(b, c)) == meet(meet(a, b), c)

  test "given meet then it is idempotent":
    for a in TruthValue:
      check meet(a, a) == a

  # Note: De Morgan laws hold for TRUTH ordering operations (disjunction/conjunction),
  # NOT for knowledge ordering operations (join/meet).
  # negate is logical negation; join/meet are knowledge lattice operations.
  # This is a fundamental property of Belnap's bilattice FOUR.

  test "given absorption law then join(a, meet(a, b)) == a":
    for a in TruthValue:
      for b in TruthValue:
        check join(a, meet(a, b)) == a

  test "given absorption law then meet(a, join(a, b)) == a":
    for a in TruthValue:
      for b in TruthValue:
        check meet(a, join(a, b)) == a

suite "TruthValue - information ordering":
  test "given tvNeither then it is bottom (leqI all)":
    for v in TruthValue:
      check leqI(tvNeither, v)

  test "given tvBoth then it is top (all leqI tvBoth)":
    for v in TruthValue:
      check leqI(v, tvBoth)

  test "given tvTrue and tvFalse then they are incomparable":
    check not leqI(tvTrue, tvFalse)
    check not leqI(tvFalse, tvTrue)

  test "given reflexivity then a leqI a for all":
    for v in TruthValue:
      check leqI(v, v)

  test "given transitivity then a leqI b and b leqI c implies a leqI c":
    for a in TruthValue:
      for b in TruthValue:
        for c in TruthValue:
          if leqI(a, b) and leqI(b, c):
            check leqI(a, c)
