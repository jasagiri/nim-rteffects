## ex14: Async I/O patterns — deferred handlers and Engine resume/abort API
##
## Demonstrates how the Engine supports non-blocking I/O by suspending
## frames when a handler does not call resume immediately.  An external
## caller (representing an I/O callback) later resumes or aborts each
## suspended frame.
##
## Key concepts:
##   deferredHttpGetHandler() — installs a no-op handler so the frame
##     transitions to fsSuspended rather than completing synchronously.
##   engine.resumeFrame(fid, value) — deliver a success result from outside.
##   engine.abortFrame(fid, error)  — deliver a failure from outside.
##   engine.hasSuspended()          — true when any frame awaits a callback.
##   engine.allDone()               — true when all frames have finished.
##
## Scenarios:
##   1. Single request: submit → runLoop → fsSuspended → resumeFrame → done
##   2. Request failure: same flow but abortFrame → failed frame
##   3. Concurrent requests: two frames both suspend, resumed in reverse order
##   4. State queries at each step confirm hasSuspended / allDone

import rteffects

# ── Scenario 1: single HTTP GET that suspends then succeeds ─────────────────

echo "=== Scenario 1: single request ==="

let req1 = performHttpGet("https://api.example.com/data")
           .handle(httpGetTag, deferredHttpGetHandler().impl)

let engine1 = newEngine(budget = 200)
let fid1 = engine1.newFrame(req1.program, req1.program.entry)

# No frames are done yet; the engine just registered the frame.
echo "after newFrame: allDone=", engine1.allDone()  # false

engine1.runLoop()

# The deferred handler did not call resume, so the frame is suspended.
echo "after runLoop:  state=",        engine1.frames[fid1].state        # fsSuspended
echo "after runLoop:  hasSuspended=", engine1.hasSuspended()            # true
echo "after runLoop:  allDone=",      engine1.allDone()                 # false

# Simulate async I/O callback delivering the response.
engine1.resumeFrame(fid1, boxStr("{\"status\":\"ok\"}"))
engine1.runLoop()

echo "after resume:   state=",  engine1.frames[fid1].state              # fsDone
echo "after resume:   failed=", engine1.frames[fid1].failed             # false
echo "after resume:   result=", engine1.frames[fid1].result.strVal      # {"status":"ok"}
echo "after resume:   allDone=",engine1.allDone()                       # true

assert engine1.frames[fid1].state == fsDone
assert not engine1.frames[fid1].failed
assert engine1.frames[fid1].result.strVal == "{\"status\":\"ok\"}"
assert engine1.allDone()

# ── Scenario 2: request that times out (abortFrame) ─────────────────────────

echo "\n=== Scenario 2: request failure ==="

let req2 = performHttpGet("https://api.example.com/slow")
           .handle(httpGetTag, deferredHttpGetHandler().impl)

let engine2 = newEngine(budget = 200)
let fid2 = engine2.newFrame(req2.program, req2.program.entry)

engine2.runLoop()
echo "after runLoop:  state=", engine2.frames[fid2].state               # fsSuspended

# Simulate a timeout arriving before the response.
engine2.abortFrame(fid2, exceptionError("timeout after 30s"))
engine2.runLoop()

echo "after abort:    state=",  engine2.frames[fid2].state              # fsDone
echo "after abort:    failed=", engine2.frames[fid2].failed             # true
echo "after abort:    error=",  engine2.frames[fid2].error.msg          # timeout after 30s
echo "after abort:    allDone=",engine2.allDone()                       # true

assert engine2.frames[fid2].state == fsDone
assert engine2.frames[fid2].failed
assert engine2.frames[fid2].error.msg == "timeout after 30s"
assert engine2.allDone()

# ── Scenario 3: two concurrent requests ─────────────────────────────────────

echo "\n=== Scenario 3: concurrent requests ==="

let reqA = performHttpGet("https://api.example.com/a")
           .handle(httpGetTag, deferredHttpGetHandler().impl)
let reqB = performHttpGet("https://api.example.com/b")
           .handle(httpGetTag, deferredHttpGetHandler().impl)

let engine3 = newEngine(budget = 400)
let fidA = engine3.newFrame(reqA.program, reqA.program.entry)
let fidB = engine3.newFrame(reqB.program, reqB.program.entry)

engine3.runLoop()

echo "both submitted:  hasSuspended=", engine3.hasSuspended()           # true
echo "both submitted:  allDone=",      engine3.allDone()                # false
echo "frame A state=", engine3.frames[fidA].state                       # fsSuspended
echo "frame B state=", engine3.frames[fidB].state                       # fsSuspended

assert engine3.frames[fidA].state == fsSuspended
assert engine3.frames[fidB].state == fsSuspended
assert engine3.hasSuspended()
assert not engine3.allDone()

# Resume in reverse order — B completes before A.
engine3.resumeFrame(fidB, boxStr("response-B"))
engine3.resumeFrame(fidA, boxStr("response-A"))
engine3.runLoop()

echo "after both resumes: frame A state=", engine3.frames[fidA].state   # fsDone
echo "after both resumes: frame B state=", engine3.frames[fidB].state   # fsDone
echo "frame A result=", engine3.frames[fidA].result.strVal              # response-A
echo "frame B result=", engine3.frames[fidB].result.strVal              # response-B
echo "allDone=", engine3.allDone()                                      # true

assert engine3.frames[fidA].state == fsDone
assert engine3.frames[fidB].state == fsDone
assert engine3.frames[fidA].result.strVal == "response-A"
assert engine3.frames[fidB].result.strVal == "response-B"
assert not engine3.frames[fidA].failed
assert not engine3.frames[fidB].failed
assert engine3.allDone()

# ── Scenario 4: state queries at each step ──────────────────────────────────

echo "\n=== Scenario 4: state queries ==="

let req4 = performHttpGet("https://api.example.com/check")
           .handle(httpGetTag, deferredHttpGetHandler().impl)

let engine4 = newEngine(budget = 200)

# Before any frame: engine is idle and considered done (nothing pending).
echo "empty engine: hasSuspended=", engine4.hasSuspended()              # false
echo "empty engine: allDone=",      engine4.allDone()                   # true

assert not engine4.hasSuspended()
assert engine4.allDone()

let fid4 = engine4.newFrame(req4.program, req4.program.entry)
echo "after newFrame: allDone=", engine4.allDone()                      # false

engine4.runLoop()

echo "suspended:  hasSuspended=", engine4.hasSuspended()                # true
echo "suspended:  allDone=",      engine4.allDone()                     # false
echo "suspended:  state=",        engine4.frames[fid4].state            # fsSuspended

assert engine4.hasSuspended()
assert not engine4.allDone()
assert engine4.frames[fid4].state == fsSuspended

engine4.resumeFrame(fid4, boxStr("pong"))
engine4.runLoop()

echo "done:       hasSuspended=", engine4.hasSuspended()                # false
echo "done:       allDone=",      engine4.allDone()                     # true
echo "done:       state=",        engine4.frames[fid4].state            # fsDone

assert not engine4.hasSuspended()
assert engine4.allDone()
assert engine4.frames[fid4].state == fsDone

echo "\nAll ex14 checks passed."
