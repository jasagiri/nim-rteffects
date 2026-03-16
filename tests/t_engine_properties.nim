## Property-based tests for Engine invariants.
##
## Verifies structural guarantees that must hold regardless of
## specific test data. No hand-picked examples — properties are
## checked over randomly generated inputs.

import std/[unittest, random, strutils]
import rteffects

var rng = initRand(42)

# ── Property helpers ───────────────────────────────────────────────

proc randomTag(): EffectTag =
  EffectTag("tag:" & $rng.rand(100))

proc randomUrl(): string =
  let domains = ["alpha.test", "beta.test", "gamma.test", "delta.test"]
  "https://" & domains[rng.rand(domains.high)] & "/" & $rng.rand(9999)

proc distinctUrl(avoid: seq[string]): string =
  ## Generate a URL that does NOT contain any avoid string as substring.
  for _ in 0..100:
    let url = randomUrl()
    var ok = true
    for a in avoid:
      if a in url: ok = false; break
    if ok: return url
  "https://zzz-unique-" & $rng.rand(999999) & ".test"

# ── Engine invariants ──────────────────────────────────────────────

suite "Engine Properties — frame lifecycle":
  test "PROP: Any frame reaches fsDone or fsSuspended after runLoop":
    ## Every frame must terminate or explicitly suspend.
    ## No frame should stay in fsReady or fsRunning after runLoop.
    for _ in 0..20:
      let tag = randomTag()
      let eff = handle[string](perform[string](tag, boxStr("x")), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          if rng.rand(1) == 0: r(boxStr("ok")) else: discard)
      let engine = newEngine(budget = 50)
      let fid = engine.newFrame(eff.program, eff.program.entry)
      engine.runLoop()
      check engine.frames[fid].state in {fsDone, fsSuspended}

  test "PROP: Resumed frame always reaches fsDone":
    ## After resumeFrame, running the engine must reach fsDone.
    for _ in 0..20:
      let tag = randomTag()
      let eff = handle[string](perform[string](tag, boxStr("x")), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          discard)  # always suspend
      let engine = newEngine(budget = 50)
      let fid = engine.newFrame(eff.program, eff.program.entry)
      engine.runLoop()
      check engine.frames[fid].state == fsSuspended
      engine.resumeFrame(fid, boxStr("value-" & $rng.rand(999)))
      engine.runLoop()
      check engine.frames[fid].state == fsDone
      check engine.frames[fid].hasResult

  test "PROP: Aborted frame always reaches fsDone with failed=true":
    for _ in 0..20:
      let tag = randomTag()
      let eff = handle[string](perform[string](tag, boxStr("x")), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          discard)
      let engine = newEngine(budget = 50)
      let fid = engine.newFrame(eff.program, eff.program.entry)
      engine.runLoop()
      engine.abortFrame(fid, exceptionError("err-" & $rng.rand(999)))
      engine.runLoop()
      check engine.frames[fid].state == fsDone
      check engine.frames[fid].failed

suite "Engine Properties — multi-frame":
  test "PROP: N independent frames all complete independently":
    let n = rng.rand(2..8)
    let engine = newEngine(budget = n * 20)
    var fids: seq[int]
    for i in 0..<n:
      let tag = EffectTag("tag:" & $i)
      let eff = handle[string](perform[string](tag, boxStr($i)), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          discard)
      fids.add(engine.newFrame(eff.program, eff.program.entry))
    engine.runLoop()
    # All should be suspended
    for fid in fids:
      check engine.frames[fid].state == fsSuspended
    # Resume all in random order
    var order = fids
    rng.shuffle(order)
    for fid in order:
      engine.resumeFrame(fid, boxStr("done:" & $fid))
    engine.runLoop()
    for fid in fids:
      check engine.frames[fid].state == fsDone
    check engine.allDone()

  test "PROP: Partial resume leaves unresolved frames suspended":
    let engine = newEngine(budget = 200)
    var fids: seq[int]
    for i in 0..3:
      let tag = EffectTag("t:" & $i)
      let eff = handle[string](perform[string](tag, boxStr($i)), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          discard)
      fids.add(engine.newFrame(eff.program, eff.program.entry))
    engine.runLoop()
    # Resume only first two
    engine.resumeFrame(fids[0], boxStr("a"))
    engine.resumeFrame(fids[1], boxStr("b"))
    engine.runLoop()
    check engine.frames[fids[0]].state == fsDone
    check engine.frames[fids[1]].state == fsDone
    check engine.frames[fids[2]].state == fsSuspended
    check engine.frames[fids[3]].state == fsSuspended
    check engine.hasSuspended()
    check not engine.allDone()

suite "Engine Properties — handler abort propagation":
  test "PROP: Handler abort always produces failed frame via run":
    ## Core invariant: if handler calls abort, run returns isOk=false.
    for _ in 0..20:
      let tag = randomTag()
      let errMsg = "error-" & $rng.rand(99999)
      let eff = handle[string](perform[string](tag, boxStr("x")), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          {.cast(gcsafe).}: a(exceptionError(errMsg)))
      let result = run[string](eff)
      check not result.isOk

  test "PROP: Handler resume always produces ok frame via run":
    for _ in 0..20:
      let tag = randomTag()
      let val = "val-" & $rng.rand(99999)
      let eff = handle[string](perform[string](tag, boxStr("x")), tag,
        proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          {.cast(gcsafe).}: r(boxStr(val)))
      let result = run[string](eff)
      check result.isOk

suite "Engine Properties — mock handler correctness":
  test "PROP: mockHttpGetHandler matches only when pattern is substring":
    for _ in 0..30:
      let pattern = "unique-" & $rng.rand(99999) & ".test"
      let matchUrl = "https://" & pattern & "/path"
      let noMatchUrl = distinctUrl(@[pattern])

      let handler = mockHttpGetHandler(@[(pattern, "found")])

      # Match case
      let effMatch = handle[string](performHttpGet(matchUrl), httpGetTag, handler.impl)
      let resMatch = run[string](effMatch)
      check resMatch.isOk
      check resMatch.ok == "found"

      # No-match case
      let effNoMatch = handle[string](performHttpGet(noMatchUrl), httpGetTag, handler.impl)
      let resNoMatch = run[string](effNoMatch)
      check not resNoMatch.isOk

  test "PROP: allDone iff no suspended and no queued":
    let engine = newEngine(budget = 100)
    check engine.allDone()  # empty engine
    let tag = EffectTag("t")
    let eff = handle[string](perform[string](tag, boxStr("x")), tag,
      proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.}, a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
        discard)
    let fid = engine.newFrame(eff.program, eff.program.entry)
    check not engine.allDone()  # queued
    engine.runLoop()
    check not engine.allDone()  # suspended
    engine.resumeFrame(fid, boxStr("ok"))
    engine.runLoop()
    check engine.allDone()  # done
