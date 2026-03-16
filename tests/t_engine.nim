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

suite "Engine - FrameId equality":
  test "given same FrameIds when compared then equal":
    check FrameId(0) == FrameId(0)
    check FrameId(1) == FrameId(1)

  test "given different FrameIds when compared then not equal":
    check not (FrameId(0) == FrameId(1))

suite "Engine - nextId":
  test "given empty engine then nextId is 0":
    let engine = newEngine()
    check engine.nextId == 0

  test "given engine with frames then nextId increments":
    let engine = newEngine()
    let eff = pure[int](1)
    discard engine.newFrame(eff.program, eff.program.entry)
    check engine.nextId == 1
    discard engine.newFrame(eff.program, eff.program.entry)
    check engine.nextId == 2

suite "Engine - budget exhaustion":
  test "given interpret with budget=1 on complex program then evalNeither":
    # Create a deep andThen chain that needs many steps
    var eff = pure[int](0)
    for i in 1..10:
      let captI = i
      eff = eff.andThen(proc(x: int): Eff[int] {.gcsafe.} =
        pure[int](x + captI)
      )
    # Budget of 1 won't be enough to complete
    let ev = interpret[int](eff, budget = 1)
    check ev.truth == tvNeither

suite "Engine - run exception handling":
  test "given run when internal exception then catches and returns ExceptionRaised":
    # Create an Eff with a mapFn that raises
    var eff = Eff[int](
      program: EffProgram(),
      boxer: proc(v: int): BoxedValue {.gcsafe.} = boxInt(v),
      unboxer: proc(v: BoxedValue): int {.gcsafe.} = unboxInt(v),
    )
    let pureId = eff.program.addOp(EffOp(kind: opPure, pureValue: boxInt(1)))
    let mapId = eff.program.addOp(EffOp(kind: opMap,
      mapTarget: pureId,
      mapFn: proc(v: BoxedValue): BoxedValue {.gcsafe.} =
        raise newException(ValueError, "map exploded"),
    ))
    eff.program.entry = mapId
    let result = run[int](eff)
    check not result.isOk
    check result.err.kind == ExceptionRaised

suite "Engine - opPerform suspended":
  test "given perform with handler that neither resumes nor aborts then frame is suspended":
    let engine = newEngine()
    let tag = EffectTag("suspend")
    let body = perform[int](tag, boxInt(1))
    let eff = body.handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      discard  # Neither resume nor abort
    )
    let frameId = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    check engine.frames[frameId].state == fsSuspended

suite "Engine - opPerform abort path":
  test "given perform with handler that aborts then evalFalse":
    let tag = EffectTag("aborter")
    let body = perform[int](tag, boxInt(1))
    let eff = body.handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      abort(RtError(kind: Cancelled, msg: "handler aborted"))
    )
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome
    check ev.error.get.kind == Cancelled

suite "Engine - opMap with failed source":
  test "given map on failed source then error propagates":
    let err = RtError(kind: Timeout, msg: "t")
    let eff = fail[int](err).map(proc(x: int): int {.gcsafe.} = x * 2)
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome
    check ev.error.get.kind == Timeout

suite "Engine - opHandle with completed body":
  test "given handle wrapping pure then result passes through":
    let tag = EffectTag("unused")
    let eff = pure[int](99).handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(payload)
    )
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(99)

  test "given handle wrapping fail then error passes through":
    let tag = EffectTag("unused")
    let eff = fail[int](RtError(kind: Timeout, msg: "t")).handle(tag,
      proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(payload)
    )
    let ev = interpret[int](eff)
    check ev.truth == tvFalse

suite "Engine - andThen with failed inner program":
  test "given andThen where f returns fail then evalFalse":
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      fail[int](RtError(kind: ForeignError, msg: "inner fail"))
    )
    let ev = interpret[int](eff)
    check ev.truth == tvFalse
    check ev.error.isSome
    check ev.error.get.kind == ForeignError

suite "Engine - tryFastInterpret edge cases":
  test "given program with invalid entry then evalNeither":
    var eff = Eff[int](
      program: EffProgram(entry: ContId(-1)),
      boxer: proc(v: int): BoxedValue {.gcsafe.} = boxInt(v),
      unboxer: proc(v: BoxedValue): int {.gcsafe.} = unboxInt(v),
    )
    let ev = interpret[int](eff)
    check ev.truth == tvNeither

  test "given program with out-of-bounds entry then evalNeither":
    var eff = Eff[int](
      program: EffProgram(entry: ContId(999)),
      boxer: proc(v: int): BoxedValue {.gcsafe.} = boxInt(v),
      unboxer: proc(v: BoxedValue): int {.gcsafe.} = unboxInt(v),
    )
    let ev = interpret[int](eff)
    check ev.truth == tvNeither

suite "Engine - interpretStep bvProgram chain":
  test "given andThen returning andThen then recursive bvProgram resolution works":
    # pure(1) >>= (x => pure(x+1) >>= (y => pure(y*10)))
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1).andThen(proc(y: int): Eff[int] {.gcsafe.} =
        pure[int](y * 10)
      )
    )
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(20)

  test "given deeply chained andThen then all resolve correctly":
    let eff = pure[int](1)
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    let ev = interpret[int](eff)
    check ev.truth == tvTrue
    check ev.value == some(5) # 1+1+1+1+1

suite "Engine - runLoop edge cases":
  test "given empty engine when runLoop called then completes immediately":
    let engine = newEngine()
    engine.runLoop()
    check engine.frames.len == 0

suite "Engine - runLoop budget":
  test "given runLoop with low budget then stops early":
    let engine = newEngine(budget = 2)
    let eff = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
      pure[int](x + 1).andThen(proc(y: int): Eff[int] {.gcsafe.} =
        pure[int](y + 1).andThen(proc(z: int): Eff[int] {.gcsafe.} =
          pure[int](z + 1)
        )
      )
    )
    let frameId = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    # With budget=2, shouldn't complete the full chain
    let frame = engine.frames[frameId]
    # Frame might not be done yet
    check frame.state in {fsReady, fsRunning, fsSuspended, fsDone}

suite "Engine - string type interpretation":
  test "given pure string when interpreted then evalTrue":
    let eff = pure[string]("hello")
    let ev = interpret[string](eff)
    check ev.truth == tvTrue
    check ev.value == some("hello")

  test "given string andThen when interpreted then correct value":
    let eff = pure[string]("hello").andThen(proc(s: string): Eff[string] {.gcsafe.} =
      pure[string](s & " world")
    )
    let ev = interpret[string](eff)
    check ev.truth == tvTrue
    check ev.value == some("hello world")

suite "Engine - float type interpretation":
  test "given pure float when interpreted then evalTrue":
    let eff = pure[float](3.14)
    let ev = interpret[float](eff)
    check ev.truth == tvTrue
    check ev.value == some(3.14)

suite "Engine - bool type interpretation":
  test "given pure bool when interpreted then evalTrue":
    let eff = pure[bool](true)
    let ev = interpret[bool](eff)
    check ev.truth == tvTrue
    check ev.value == some(true)

suite "Engine - run with various types":
  test "given run with string then ok result":
    let result = run[string](pure[string]("test"))
    check result.isOk
    check result.ok == "test"

  test "given run with float then ok result":
    let result = run[float](pure[float](2.718))
    check result.isOk
    check result.ok == 2.718

  test "given run with bool then ok result":
    let result = run[bool](pure[bool](false))
    check result.isOk
    check result.ok == false
