import std/[unittest, options, tables]
import rteffects/core
import rteffects/semantics
import rteffects/vm/types
import rteffects/algebra
import rteffects/vm/engine

suite "Engine - pure/fail interpretation":
  test "given pure(42) when interpreted then evalTrue(42)":
    let eff = pure[int](42)
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(42)

  test "given fail(err) when interpreted then evalFalse(err)":
    let err = RtError(kind: Timeout, msg: "t")
    let eff = fail[int](err)
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome
    check ev.error.get.kind == Timeout

suite "Engine - andThen interpretation":
  test "given pure(1).andThen(x => pure(x+1)) when interpreted then evalTrue(2)":
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1)
    )
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(2)

  test "given fail.andThen(f) when interpreted then short-circuits":
    let err = RtError(kind: Cancelled, msg: "c")
    let eff = fail[int](err).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1)
    )
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome

  test "given chain of 3 pure values when interpreted then all execute":
    let eff = pure[int](1)
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 10))
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(20)

suite "Engine - map interpretation":
  test "given pure(5).map(*2) when interpreted then evalTrue(10)":
    let eff = pure[int](5).map(proc(x: int): int {.gcsafe.} = x * 2)
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(10)

suite "Engine - perform/handle interpretation":
  test "given perform with matching handler then handler value returned":
    let tag = EffectTag("double")
    let body = perform[int](tag, boxInt(21))
    let eff = body.handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxInt(unboxInt(payload) * 2))
    )
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(42)

  test "given perform without handler then evalFalse(unhandled)":
    let eff = perform[int](EffectTag("missing"))
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome
    check ev.error.get.kind == ForeignError

suite "Runner ACL":
  test "given pure(42) when run then ok(42)":
    let result = run[int](pure[int](42))
    check result.isOk
    check result.ok == 42

  test "given fail when run then err":
    let result = run[int](fail[int](RtError(kind: Timeout, msg: "t")))
    check not result.isOk
    check result.err.kind == Timeout

  test "given chain when run then final value":
    let eff = pure[int](1)
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    let result = run[int](eff)
    check result.isOk
    check result.ok == 3

  test "given perform+handle when run then handler result":
    let tag = EffectTag("inc")
    let body = perform[int](tag, boxInt(10))
    let eff = body.handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxInt(unboxInt(payload) + 1))
    )
    let result = run[int](eff)
    check result.isOk
    check result.ok == 11

suite "Engine - frame state tracking":
  test "given pure(42) then frame ends in fsDone":
    let engine = newEngine()
    let eff = pure[int](42)
    let frameId = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    let frame = engine.frames[frameId]
    check frame.state == fsDone

  test "given map chain then frame ends in fsDone":
    let engine = newEngine()
    let eff = pure[int](5).map(proc(x: int): int {.gcsafe.} = x * 2)
    let frameId = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    let frame = engine.frames[frameId]
    check frame.state == fsDone
    check frame.hasResult
    check unboxInt(frame.result) == 10

  test "given andThen then frame ends in fsDone with correct value":
    let engine = newEngine()
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1)
    )
    let frameId = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    let frame = engine.frames[frameId]
    check frame.state == fsDone
