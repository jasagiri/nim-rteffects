## Tests for standard I/O handlers.

import std/unittest
import rteffects

suite "Handlers — typed perform wrappers":
  test "Given performHttpGet When mock handler Then returns response":
    let eff = performHttpGet("https://api.test/data")
    let handled = handle[string](eff, httpGetTag,
      mockHttpGetHandler(@[("api.test", "{\"ok\":true}")]).impl)
    let result = run[string](handled)
    check result.isOk
    check result.ok == "{\"ok\":true}"

  test "Given performFileRead When mock handler Then returns content":
    let eff = performFileRead("/etc/test.conf")
    let handled = handle[string](eff, fileReadTag,
      mockFileReadHandler(@[("test.conf", "key=value")]).impl)
    let result = run[string](handled)
    check result.isOk
    check result.ok == "key=value"

  test "Given performHttpPost When mock handler Then URL contains path":
    let eff = performHttpPost("https://api.test/submit", "{\"data\":1}")
    # Verify payload format
    let handled = handle[string](eff, httpPostTag,
      proc(payload: BoxedValue,
           resume: proc(v: BoxedValue) {.gcsafe.},
           abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
        check payload.kind == bvRef
        let data = cast[HttpPostPayload](payload.refVal)
        check data.url == "https://api.test/submit"
        check data.body == "{\"data\":1}"
        resume(boxStr("201 Created")))
    let result = run[string](handled)
    check result.isOk
    check result.ok == "201 Created"

suite "Handlers — mock matching":
  test "Given multiple mocks When URL matches second Then returns second":
    let handler = mockHttpGetHandler(@[
      ("weather.api", "sunny"),
      ("stock.api", "up 2%")])
    let eff = handle[string](performHttpGet("https://stock.api/today"), httpGetTag, handler.impl)
    let result = run[string](eff)
    check result.isOk
    check result.ok == "up 2%"

  test "Given no matching mock When perform Then aborts":
    # Use a URL that does NOT contain the mock pattern as substring
    let handler = mockHttpGetHandler(@[("exact-match.example.com", "ok")])
    let eff = handle[string](performHttpGet("https://totally-different.test"), httpGetTag, handler.impl)
    let result = run[string](eff)
    check not result.isOk

suite "Handlers — deferred (async pattern)":
  test "Given deferredHttpGetHandler When perform Then suspends":
    let eff = handle[string](performHttpGet("https://slow.api"), httpGetTag,
      deferredHttpGetHandler().impl)
    let engine = newEngine(budget = 100)
    let fid = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    check engine.frames[fid].state == fsSuspended
    check engine.hasSuspended()

  test "Given deferred + resumeFrame When resume Then completes":
    let eff = handle[string](performHttpGet("https://api.test"), httpGetTag,
      deferredHttpGetHandler().impl)
    let engine = newEngine(budget = 100)
    let fid = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    check engine.hasSuspended()
    engine.resumeFrame(fid, boxStr("deferred response"))
    engine.runLoop()
    check engine.allDone()
    check engine.frames[fid].result.strVal == "deferred response"

  test "Given deferredFileReadHandler When perform Then suspends":
    let eff = handle[string](performFileRead("/data/big.csv"), fileReadTag,
      deferredFileReadHandler().impl)
    let engine = newEngine(budget = 100)
    let fid = engine.newFrame(eff.program, eff.program.entry)
    engine.runLoop()
    check engine.frames[fid].state == fsSuspended

suite "Handlers — andThen composition with mock":
  test "Given httpGet andThen map When mock Then chained result":
    let eff = performHttpGet("https://api.test").map(
      proc(resp: string): string {.gcsafe.} = "parsed:" & resp)
    let handled = handle[string](eff, httpGetTag,
      mockHttpGetHandler(@[("api.test", "raw")]).impl)
    let result = run[string](handled)
    check result.isOk
    check result.ok == "parsed:raw"
