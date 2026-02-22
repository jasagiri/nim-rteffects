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
