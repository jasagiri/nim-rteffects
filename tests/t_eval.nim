import std/[unittest, options]
import rteffects/core
import rteffects/semantics

suite "Eval[T] Construction":
  test "given evalTrue(42) then truth is tvTrue and value is present":
    let ev = evalTrue(42)
    check ev.truth == tvTrue
    check ev.value == some(42)
    check ev.error.isNone

  test "given evalFalse(error) then truth is tvFalse and error is present":
    let err = RtError(kind: Timeout, msg: "timed out")
    let ev = evalFalse[int](err)
    check ev.truth == tvFalse
    check ev.value.isNone
    check ev.error.isSome
    check ev.error.get.kind == Timeout

  test "given evalBoth(42, error) then truth is tvBoth with both present":
    let err = RtError(kind: Cancelled, msg: "cancelled")
    let ev = evalBoth(42, err)
    check ev.truth == tvBoth
    check ev.value == some(42)
    check ev.error.isSome
    check ev.error.get.kind == Cancelled

  test "given evalNeither then truth is tvNeither with nothing present":
    let ev = evalNeither[int]()
    check ev.truth == tvNeither
    check ev.value.isNone
    check ev.error.isNone

suite "Eval[T] map":
  test "given evalTrue(1) when mapped with +1 then evalTrue(2)":
    let ev = evalTrue(1)
    let mapped = ev.map(proc(x: int): int = x + 1)
    check mapped.truth == tvTrue
    check mapped.value == some(2)

  test "given evalFalse when mapped then unchanged":
    let ev = evalFalse[int](RtError(kind: Timeout, msg: "t"))
    let mapped = ev.map(proc(x: int): int = x + 1)
    check mapped.truth == tvFalse
    check mapped.value.isNone
    check mapped.error.isSome
    check mapped.error.get.kind == Timeout

  test "given evalBoth when mapped then value transformed error preserved":
    let ev = evalBoth(10, RtError(kind: Cancelled, msg: "c"))
    let mapped = ev.map(proc(x: int): int = x * 2)
    check mapped.truth == tvBoth
    check mapped.value == some(20)
    check mapped.error.isSome
    check mapped.error.get.kind == Cancelled

  test "given evalNeither when mapped then unchanged":
    let ev = evalNeither[int]()
    let mapped = ev.map(proc(x: int): int = x + 1)
    check mapped.truth == tvNeither
    check mapped.value.isNone

suite "Eval[T] flatMap":
  test "given evalTrue when flatMapped to evalTrue then evalTrue":
    let ev = evalTrue(1)
    let result = ev.flatMap(proc(x: int): Eval[string] = evalTrue($x))
    check result.truth == tvTrue
    check result.value == some("1")

  test "given evalTrue when flatMapped to evalFalse then evalFalse":
    let ev = evalTrue(1)
    let result = ev.flatMap(proc(x: int): Eval[string] =
      evalFalse[string](RtError(kind: Timeout, msg: "t"))
    )
    check result.truth == tvFalse
    check result.error.isSome
    check result.error.get.kind == Timeout

  test "given evalFalse when flatMapped then short-circuits":
    let ev = evalFalse[int](RtError(kind: Timeout, msg: "t"))
    var called = false
    let result = ev.flatMap(proc(x: int): Eval[string] =
      called = true
      evalTrue($x)
    )
    check result.truth == tvFalse
    check not called

  test "given evalNeither when flatMapped then short-circuits":
    let ev = evalNeither[int]()
    var called = false
    let result = ev.flatMap(proc(x: int): Eval[string] =
      called = true
      evalTrue($x)
    )
    check result.truth == tvNeither
    check not called

  test "given evalBoth when flatMapped to evalTrue then truth is tvBoth and outer error preserved":
    let ev = evalBoth(1, RtError(kind: Cancelled, msg: "c"))
    let result = ev.flatMap(proc(x: int): Eval[string] =
      evalTrue($x)  # inner has no error
    )
    # join(tvBoth, tvTrue) == tvBoth
    check result.truth == tvBoth
    check result.value == some("1")
    # inner.error.isNone → outer error preserved
    check result.error.isSome
    check result.error.get.kind == Cancelled

  test "given evalBoth when flatMapped to evalFalse then truth is tvBoth and inner error used":
    let ev = evalBoth(1, RtError(kind: Cancelled, msg: "outer"))
    let result = ev.flatMap(proc(x: int): Eval[string] =
      evalFalse[string](RtError(kind: Timeout, msg: "inner"))
    )
    # join(tvBoth, tvFalse) == tvBoth
    check result.truth == tvBoth
    # inner.error.isSome → inner error used
    check result.error.isSome
    check result.error.get.kind == Timeout

  test "given evalBoth when flatMapped to evalBoth then truth is tvBoth":
    let ev = evalBoth(1, RtError(kind: Cancelled, msg: "outer"))
    let result = ev.flatMap(proc(x: int): Eval[string] =
      evalBoth($x, RtError(kind: Timeout, msg: "inner"))
    )
    check result.truth == tvBoth
    check result.value == some("1")
    check result.error.isSome
    check result.error.get.kind == Timeout

  test "given evalBoth when flatMapped to evalNeither then truth is tvBoth":
    let ev = evalBoth(1, RtError(kind: Cancelled, msg: "outer"))
    let result = ev.flatMap(proc(x: int): Eval[string] =
      evalNeither[string]()
    )
    # join(tvBoth, tvNeither) == tvBoth
    check result.truth == tvBoth

suite "Eval[T] toResult (ACL: 4-value to 2-value)":
  test "given evalTrue(42) when toResult then ok(42)":
    let ev = evalTrue(42)
    let res = ev.toResult()
    check res.isOk
    check res.ok == 42

  test "given evalFalse when toResult then err with original error":
    let ev = evalFalse[int](RtError(kind: Timeout, msg: "timed out"))
    let res = ev.toResult()
    check not res.isOk
    check res.err.kind == Timeout

  test "given evalBoth when toResult then err with Contradiction kind":
    let ev = evalBoth(42, RtError(kind: Cancelled, msg: "c"))
    let res = ev.toResult()
    check not res.isOk
    check res.err.kind == Contradiction

  test "given evalNeither when toResult then err with Incomplete kind":
    let ev = evalNeither[int]()
    let res = ev.toResult()
    check not res.isOk
    check res.err.kind == Incomplete
