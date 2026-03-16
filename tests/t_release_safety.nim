## Release safety tests — must pass with -d:release (no boundChecks).
##
## These tests exercise scenarios that previously caused undefined behavior
## when bounds checking was off. Run with:
##   nim c -d:release -r tests/t_release_safety.nim
##
## Root cause: seq[Frame] reallocation during newFrame invalidated
## Frame addresses. Fixed by using seq[FrameRef] (heap-allocated frames).

import std/[unittest, random]
import rteffects

suite "Release Safety — seq realloc stress":
  test "PROP: 50 concurrent frames with andThen all resolve":
    ## Stress seq[FrameRef] reallocation — 50 frames forces multiple seq grows.
    let engine = newEngine(budget = 5000)
    var fids: seq[int]
    for i in 0..49:
      let eff = pure[int](i).andThen(proc(x: int): Eff[int] {.gcsafe.} =
        pure[int](x * 2))
      fids.add(engine.newFrame(eff.program, eff.program.entry))
    engine.runLoop()
    for fid in fids:
      check engine.frames[fid].state == fsDone
      check engine.frames[fid].hasResult
    check engine.allDone()

  test "PROP: Nested andThen 5 deep all resolve":
    ## Deep chain forces multiple child frame spawns.
    let eff = pure[int](1)
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    let result = run[int](eff)
    check result.isOk
    check result.ok == 5

  test "PROP: Concurrent frames with perform + handler all resolve":
    let engine = newEngine(budget = 5000)
    var fids: seq[int]
    for i in 0..29:
      let tag = EffectTag("tag:" & $i)
      let eff = perform[string](tag, boxStr("data:" & $i))
      let fid = engine.newFrame(eff.program, eff.program.entry)
      engine.frames[fid].handlers.add(HandlerEntry(tag: tag,
        impl: proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.},
                    a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          r(boxStr("reply:" & p.strVal))))
      fids.add(fid)
    engine.runLoop()
    for fid in fids:
      check engine.frames[fid].state == fsDone
      check engine.frames[fid].hasResult
    check engine.allDone()

  test "PROP: Mixed deferred + immediate in same engine":
    ## Some frames resume immediately, others suspend. Tests frame
    ## indexing stability during mixed execution patterns.
    let engine = newEngine(budget = 2000)
    var immediateFids: seq[int]
    var deferredFids: seq[int]
    var rng = initRand(42)
    for i in 0..19:
      let tag = EffectTag("io:" & $i)
      let eff = perform[string](tag, boxStr($i))
      let fid = engine.newFrame(eff.program, eff.program.entry)
      if rng.rand(1) == 0:
        # Immediate handler
        engine.frames[fid].handlers.add(HandlerEntry(tag: tag,
          impl: proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.},
                      a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
            r(boxStr("immediate"))))
        immediateFids.add(fid)
      else:
        # Deferred handler
        engine.frames[fid].handlers.add(HandlerEntry(tag: tag,
          impl: proc(p: BoxedValue, r: proc(v: BoxedValue) {.gcsafe.},
                      a: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
            discard))
        deferredFids.add(fid)
    engine.runLoop()
    # Immediate should be done
    for fid in immediateFids:
      check engine.frames[fid].state == fsDone
    # Deferred should be suspended
    for fid in deferredFids:
      check engine.frames[fid].state == fsSuspended
    # Resume all deferred
    for fid in deferredFids:
      engine.resumeFrame(fid, boxStr("resumed"))
    engine.runLoop()
    check engine.allDone()
