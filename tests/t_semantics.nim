## Tests for Belnap 4-valued evaluation semantics.

import std/[unittest, options]
import rteffects/core
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
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for v in values:
      check negate(negate(v)) == v

suite "TruthValue Lattice - meet":
  test "given tvTrue and tvFalse when met then tvNeither":
    check meet(tvTrue, tvFalse) == tvNeither

  test "given tvTrue and tvNeither when met then tvNeither":
    check meet(tvTrue, tvNeither) == tvNeither

  test "given tvFalse and tvNeither when met then tvNeither":
    check meet(tvFalse, tvNeither) == tvNeither

  test "given tvBoth and tvNeither when met then tvNeither":
    check meet(tvBoth, tvNeither) == tvNeither

  test "given tvTrue and tvTrue when met then tvTrue":
    check meet(tvTrue, tvTrue) == tvTrue

  test "given tvFalse and tvFalse when met then tvFalse":
    check meet(tvFalse, tvFalse) == tvFalse

  test "given tvBoth and tvBoth when met then tvBoth":
    check meet(tvBoth, tvBoth) == tvBoth

  test "given tvNeither and tvNeither when met then tvNeither":
    check meet(tvNeither, tvNeither) == tvNeither

  test "given tvBoth and tvTrue when met then tvTrue":
    check meet(tvBoth, tvTrue) == tvTrue

  test "given tvBoth and tvFalse when met then tvFalse":
    check meet(tvBoth, tvFalse) == tvFalse

suite "TruthValue Lattice - algebraic laws":
  test "given join then it is commutative":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        check join(a, b) == join(b, a)

  test "given join then it is associative":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        for c in values:
          check join(a, join(b, c)) == join(join(a, b), c)

  test "given join then it is idempotent":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for v in values:
      check join(v, v) == v

  test "given meet then it is commutative":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        check meet(a, b) == meet(b, a)

  test "given meet then it is associative":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        for c in values:
          check meet(a, meet(b, c)) == meet(meet(a, b), c)

  test "given meet then it is idempotent":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for v in values:
      check meet(v, v) == v

  test "given absorption law then join(a, meet(a, b)) == a":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        check join(a, meet(a, b)) == a

  test "given absorption law then meet(a, join(a, b)) == a":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      for b in values:
        check meet(a, join(a, b)) == a

suite "TruthValue - information ordering":
  test "given tvNeither then it is bottom (leqI all)":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for v in values:
      check leqI(tvNeither, v)

  test "given tvBoth then it is top (all leqI tvBoth)":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for v in values:
      check leqI(v, tvBoth)

  test "given tvTrue and tvFalse then they are incomparable":
    check not leqI(tvTrue, tvFalse)
    check not leqI(tvFalse, tvTrue)

  test "given reflexivity then a leqI a for all":
    let values = [tvTrue, tvFalse, tvBoth, tvNeither]
    for a in values:
      check leqI(a, a)

  test "given transitivity then a leqI b and b leqI c implies a leqI c":
    # (Simplified check via table properties)
    check leqI(tvNeither, tvTrue)
    check leqI(tvTrue, tvBoth)
    check leqI(tvNeither, tvBoth)

suite "Eval[T] Constructors & Basic Properties":
  test "evalTrue(v) produces tvTrue and value":
    let e = evalTrue(10)
    check e.truth == tvTrue
    check e.value.isSome and e.value.get == 10
    check e.error.isNone

  test "evalFalse(err) produces tvFalse and error":
    let err = RtError(kind: ForeignError)
    let e = evalFalse[int](err)
    check e.truth == tvFalse
    check e.error.isSome
    check e.error.get.kind == ForeignError
    check e.value.isNone

  test "evalBoth produces tvBoth with value and error":
    let err = RtError(kind: ForeignError)
    let e = evalBoth(10, err)
    check e.truth == tvBoth
    check e.value.isSome and e.value.get == 10
    check e.error.isSome
    check e.error.get.kind == ForeignError

  test "evalNeither produces tvNeither":
    let e = evalNeither[int]()
    check e.truth == tvNeither
    check e.value.isNone
    check e.error.isNone

suite "Eval[T] Table Operations":
  test "join(e1, e2) correctly joins truths and merges contents":
    let e1 = evalTrue(1)
    let e2 = evalFalse[int](RtError(kind: Cancelled))
    let j = join(e1, e2)
    check j.truth == tvBoth
    check j.value.isSome and j.value.get == 1
    check j.error.isSome
    check j.error.get.kind == Cancelled

  test "meet(e1, e2) correctly meets truths and merges contents":
    let e1 = evalTrue(1)
    let e2 = evalFalse[int](RtError(kind: Cancelled))
    let m = meet(e1, e2)
    check m.truth == tvNeither
    check m.value.isSome and m.value.get == 1
    check m.error.isSome
    check m.error.get.kind == Cancelled

  test "negate(e) negates truth":
    let e = evalTrue(1)
    check negate(e).truth == tvFalse
    check negate(e).value.isSome and negate(e).value.get == 1

  test "map transforms value":
    let e = evalTrue(5)
    let m = e.map(proc(x: int): string = "v:" & $x)
    check m.truth == tvTrue
    check m.value.isSome and m.value.get == "v:5"

  test "flatMap transforms value and joins truths":
    let e = evalTrue(5)
    let f = e.flatMap(proc(x: int): Eval[string] =
      evalBoth("res:" & $x, RtError(kind: ForeignError))
    )
    check f.truth == tvBoth # tvTrue join tvBoth = tvBoth
    check f.value.isSome and f.value.get == "res:5"
    check f.error.isSome
    check f.error.get.kind == ForeignError

suite "Eval[T] toResult (ACL: 4-value to 2-value)":
  test "given evalTrue(42) when toResult then ok(42)":
    let ev = evalTrue(42)
    let r = toResult(ev)
    check r.isOk
    check r.ok == 42

  test "given evalFalse when toResult then err with original error":
    let err = RtError(kind: Cancelled)
    let ev = evalFalse[int](err)
    let r = toResult(ev)
    check not r.isOk
    check r.err.kind == Cancelled

  test "given evalBoth when toResult then err with Contradiction kind":
    let ev = evalBoth(1, RtError(kind: ForeignError))
    let r = toResult(ev)
    check not r.isOk
    check r.err.kind == Contradiction

  test "given evalNeither when toResult then err with Incomplete kind":
    let ev = evalNeither[int]()
    let r = toResult(ev)
    check not r.isOk
    check r.err.kind == Incomplete
