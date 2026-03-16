import std/unittest
import rteffects/core
import rteffects/vm/types
import rteffects/algebra

suite "Eff[T] Construction":
  test "given pure(42) then program has one opPure entry":
    let eff = pure[int](42)
    check eff.program.ops.len == 1
    check eff.program.ops[0].kind == opPure
    check unboxInt(eff.program.ops[0].pureValue) == 42
    check eff.program.entry == ContId(0)

  test "given fail(error) then program has one opFail entry":
    let err = RtError(kind: Timeout, msg: "t")
    let eff = fail[int](err)
    check eff.program.ops.len == 1
    check eff.program.ops[0].kind == opFail
    check eff.program.ops[0].failError.kind == Timeout

  test "given perform then program has one opPerform entry":
    let eff = perform[string](EffectTag("read"), boxStr("/tmp"))
    check eff.program.ops.len == 1
    check eff.program.ops[0].kind == opPerform
    check eff.program.ops[0].performTag == EffectTag("read")

suite "Eff[T] Composition":
  test "given pure(1).andThen(f) then program has opBind chain":
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] =
      pure[int](x + 1)
    )
    # Should have: opBind at entry, opPure(1) as source, and a continuation
    check eff.program.ops[eff.program.entry.int].kind == opBind

  test "given pure(1).map(+1) then program has opMap":
    let eff = pure[int](1).map(proc(x: int): int = x + 1)
    # Should have opMap referencing opPure(1)
    var hasMap = false
    for op in eff.program.ops:
      if op.kind == opMap:
        hasMap = true
    check hasMap

  test "given handle wrapping body then program has opHandle":
    let body = pure[int](42)
    let tag = EffectTag("log")
    let eff = body.handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(payload)
    )
    var hasHandle = false
    for op in eff.program.ops:
      if op.kind == opHandle:
        hasHandle = true
        check op.handleTag == tag
    check hasHandle

suite "Eff[T] Type-specific boxing":
  test "given pure(string) then string value roundtrips":
    let eff = pure[string]("hello")
    check eff.program.ops[0].kind == opPure
    check unboxStr(eff.program.ops[0].pureValue) == "hello"

  test "given pure(float) then float value roundtrips":
    let eff = pure[float](3.14)
    check eff.program.ops[0].kind == opPure
    check unboxFloat(eff.program.ops[0].pureValue) == 3.14

  test "given pure(bool) then bool value roundtrips":
    let eff = pure[bool](true)
    check eff.program.ops[0].kind == opPure
    check unboxBool(eff.program.ops[0].pureValue) == true

  test "given map from int to string then type conversion works":
    let eff = pure[int](42).map(proc(x: int): string {.gcsafe.} = $x)
    check eff.program.ops[eff.program.entry.int].kind == opMap

  test "given map from int to float then type conversion works":
    let eff = pure[int](5).map(proc(x: int): float {.gcsafe.} = float(x) * 1.5)
    check eff.program.ops[eff.program.entry.int].kind == opMap

  test "given map from int to bool then type conversion works":
    let eff = pure[int](1).map(proc(x: int): bool {.gcsafe.} = x > 0)
    check eff.program.ops[eff.program.entry.int].kind == opMap

suite "Eff[T] mergeProgram with all op kinds":
  test "given andThen with perform source then opBind + opPerform merged":
    let tag = EffectTag("eff")
    let eff = perform[int](tag, boxInt(1)).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1)
    )
    # The merged program should have opPerform, opMap/opBind
    var hasPerform = false
    var hasBind = false
    for op in eff.program.ops:
      if op.kind == opPerform: hasPerform = true
      if op.kind == opBind: hasBind = true
    check hasPerform
    check hasBind

  test "given handle with map body then opHandle + opMap merged":
    let tag = EffectTag("eff")
    let body = pure[int](1).map(proc(x: int): int {.gcsafe.} = x * 2)
    let eff = body.handle(tag, proc(p: BoxedValue,
        r: proc(v: BoxedValue) {.gcsafe.},
        a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      r(p)
    )
    var hasHandle = false
    var hasMap = false
    for op in eff.program.ops:
      if op.kind == opHandle: hasHandle = true
      if op.kind == opMap: hasMap = true
    check hasHandle
    check hasMap

suite "Eff[T] non-primitive type (else branch)":
  test "given pure(Unit) then program uses boxNone for non-primitive type":
    let eff = pure[Unit](unit())
    check eff.program.ops.len == 1
    check eff.program.ops[0].kind == opPure
    # Non-primitive types use boxNone
    check eff.program.ops[0].pureValue.kind == bvNone

  test "given fail[Unit] then error is preserved":
    let eff = fail[Unit](foreignError("oops"))
    check eff.program.ops[0].kind == opFail
    check eff.program.ops[0].failError.kind == ForeignError

  test "given andThen from Unit to int then type conversion works":
    let eff = pure[Unit](unit()).andThen(proc(u: Unit): Eff[int] {.gcsafe.} =
      pure[int](42)
    )
    check eff.program.ops[eff.program.entry.int].kind == opBind

  test "given map from Unit to int then type conversion works":
    let eff = pure[Unit](unit()).map(proc(u: Unit): int {.gcsafe.} = 42)
    check eff.program.ops[eff.program.entry.int].kind == opMap
