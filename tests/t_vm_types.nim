import std/[unittest, hashes]
import rteffects/core
import rteffects/vm/types

suite "ContId":
  test "given ContId when created then distinct int semantics hold":
    let a = ContId(0)
    let b = ContId(1)
    let c = ContId(0)
    check a == c
    check a != b

  test "given ContId when hashed then usable as table key":
    check hash(ContId(42)) == hash(42)

suite "EffectTag":
  test "given EffectTag when created then distinct string semantics hold":
    let a = EffectTag("read")
    let b = EffectTag("write")
    let c = EffectTag("read")
    check a == c
    check a != b

suite "EffOp Construction":
  test "given opPure when created then value is preserved":
    let op = EffOp(kind: opPure, pureValue: boxInt(42))
    check op.kind == opPure
    check unboxInt(op.pureValue) == 42

  test "given opFail when created then error is preserved":
    let err = RtError(kind: Timeout, msg: "t")
    let op = EffOp(kind: opFail, failError: err)
    check op.kind == opFail
    check op.failError.kind == Timeout

  test "given opBind when created then source and next are linked":
    let op = EffOp(kind: opBind, bindSource: ContId(1), bindNext: ContId(2))
    check op.bindSource == ContId(1)
    check op.bindNext == ContId(2)

  test "given opPerform when created then tag and payload are set":
    let op = EffOp(kind: opPerform, performTag: EffectTag("log"))
    check op.performTag == EffectTag("log")

suite "EffProgram":
  test "given empty program when entry set then entry is accessible":
    var prog = EffProgram(entry: ContId(0))
    check prog.entry == ContId(0)
    check prog.ops.len == 0

  test "given program with ops when indexed then ops retrievable":
    var prog = EffProgram(entry: ContId(0))
    prog.ops.add(EffOp(kind: opPure, pureValue: boxInt(1)))
    prog.ops.add(EffOp(kind: opFail, failError: RtError(kind: Cancelled, msg: "c")))
    check prog.ops.len == 2
    check prog.ops[0].kind == opPure
    check prog.ops[1].kind == opFail

suite "BoxedValue":
  test "given int when boxed and unboxed then value preserved":
    let bv = boxInt(42)
    check unboxInt(bv) == 42

  test "given string when boxed and unboxed then value preserved":
    let bv = boxStr("hello")
    check unboxStr(bv) == "hello"

  test "given float when boxed and unboxed then value preserved":
    let bv = boxFloat(3.14)
    check unboxFloat(bv) == 3.14

  test "given bool when boxed and unboxed then value preserved":
    let bv = boxBool(true)
    check unboxBool(bv) == true
    let bv2 = boxBool(false)
    check unboxBool(bv2) == false

  test "given ref when boxed then kind is bvRef":
    let r = new(RootObj)
    let bv = boxRef(r)
    check bv.kind == bvRef
    check bv.refVal == r

  test "given none when boxed then kind is bvNone":
    let bv = boxNone()
    check bv.kind == bvNone

suite "ContId display":
  test "given ContId when converted to string then formatted correctly":
    check $ContId(0) == "ContId(0)"
    check $ContId(42) == "ContId(42)"

suite "EffectTag display":
  test "given EffectTag when converted to string then displays raw string":
    check $EffectTag("read") == "read"
    check $EffectTag("write") == "write"

suite "addOp":
  test "given program when addOp then returns sequential ContIds":
    var prog = EffProgram()
    let id0 = prog.addOp(EffOp(kind: opPure, pureValue: boxInt(1)))
    let id1 = prog.addOp(EffOp(kind: opFail, failError: RtError(kind: Timeout, msg: "t")))
    check id0 == ContId(0)
    check id1 == ContId(1)
    check prog.ops.len == 2
