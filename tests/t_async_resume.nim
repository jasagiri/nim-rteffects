## Tests for async resume/abort API.
## Verifies that handlers can defer resume to external callbacks.

import std/[unittest]
import rteffects

suite "Async Resume — suspend and external resume":
  test "Given perform with non-resuming handler When resumeFrame Then completes":
    let httpTag = EffectTag("http:get")
    var savedFrameId = -1

    # Build: perform http:get → map result
    let eff = perform[string](httpTag, boxStr("https://example.com"))

    # Install handler that does NOT call resume (simulates async I/O)
    let handled = handle[string](eff, httpTag,
      proc(payload: BoxedValue,
           resume: proc(v: BoxedValue) {.gcsafe.},
           abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
        # Save frame context for later resume — but don't call resume now
        discard  # In real use, we'd save resume callback
    )

    let engine = newEngine(budget = 100)
    let fid = engine.newFrame(handled.program, handled.program.entry)
    savedFrameId = fid

    # Step until suspended
    engine.runLoop()
    check engine.frames[fid].state == fsSuspended

    # External resume (simulating async I/O completion)
    engine.resumeFrame(fid, boxStr("HTTP 200 OK"))
    engine.runLoop()

    check engine.frames[fid].state == fsDone
    check engine.frames[fid].hasResult == true
    check engine.frames[fid].result.strVal == "HTTP 200 OK"

  test "Given perform When abortFrame Then fails":
    let httpTag = EffectTag("http:get")
    let eff = perform[string](httpTag, boxStr("https://fail.com"))
    let handled = handle[string](eff, httpTag,
      proc(payload: BoxedValue,
           resume: proc(v: BoxedValue) {.gcsafe.},
           abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
        discard  # suspend
    )

    let engine = newEngine(budget = 100)
    let fid = engine.newFrame(handled.program, handled.program.entry)
    engine.runLoop()
    check engine.frames[fid].state == fsSuspended

    engine.abortFrame(fid, exceptionError("connection failed"))
    engine.runLoop()

    check engine.frames[fid].state == fsDone
    check engine.frames[fid].failed == true
    check engine.frames[fid].error.msg == "connection failed"

  test "Given two suspended frames When resume both Then both complete":
    let tagA = EffectTag("io:a")
    let tagB = EffectTag("io:b")
    let effA = handle[string](perform[string](tagA), tagA,
      proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} = discard)
    let effB = handle[string](perform[string](tagB), tagB,
      proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} = discard)

    let engine = newEngine(budget = 200)
    let fidA = engine.newFrame(effA.program, effA.program.entry)
    let fidB = engine.newFrame(effB.program, effB.program.entry)
    engine.runLoop()

    check engine.frames[fidA].state == fsSuspended
    check engine.frames[fidB].state == fsSuspended
    check engine.hasSuspended() == true
    check engine.allDone() == false

    # Resume in reverse order
    engine.resumeFrame(fidB, boxStr("B done"))
    engine.resumeFrame(fidA, boxStr("A done"))
    engine.runLoop()

    check engine.frames[fidA].result.strVal == "A done"
    check engine.frames[fidB].result.strVal == "B done"
    check engine.allDone() == true

  test "Given no suspended frames When hasSuspended Then false":
    let engine = newEngine()
    check engine.hasSuspended() == false
    check engine.allDone() == true
