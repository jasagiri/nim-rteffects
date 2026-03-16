## ex17: Parallel branch execution with handler inheritance
##
## Demonstrates the Engine's ability to run multiple independent effectful
## computations in parallel, each with inherited handlers, and collect
## all results after completion.
##
## Key concepts:
##   - Multiple frames in one Engine (parallel scheduling)
##   - Frame.parentFrameId: child frames inherit parent's handlers
##   - bvProgram auto-resolution: andThen chains resolve via child frames
##   - resolveBvPrograms + propagateChildResults in runLoop
##
## Scenario: Weather + Finance parallel data fetch with mock handlers

import rteffects

echo "=== Parallel branch execution ==="

# Define two independent effectful computations
let weatherEff = performHttpGet("https://weather.api/tokyo")
  .map(proc(resp: string): string {.gcsafe.} = "Weather: " & resp)

let financeEff = performHttpGet("https://finance.api/nikkei")
  .map(proc(resp: string): string {.gcsafe.} = "Finance: " & resp)

# Create Engine with mock handler
let engine = newEngine(budget = 200)

# Register both frames — they run in round-robin
let fid0 = engine.newFrame(weatherEff.program, weatherEff.program.entry)
let fid1 = engine.newFrame(financeEff.program, financeEff.program.entry)

# Install mock handler on both frames
let mockHandler = mockHttpGetHandler(@[
  ("weather.api", """{"temp": 22, "condition": "sunny"}"""),
  ("finance.api", """{"index": "Nikkei 225", "value": 38500}"""),
])
engine.frames[fid0].handlers.add(mockHandler)
engine.frames[fid1].handlers.add(mockHandler)

echo "Frames before: ", engine.frames.len

# Run all frames
engine.runLoop()

echo "Frames after: ", engine.frames.len
echo "All done: ", engine.allDone()

# Collect results
for fid in [fid0, fid1]:
  let frame = engine.frames[fid]
  if frame.hasResult:
    echo "  Frame[", fid, "]: ", frame.result.strVal
  elif frame.failed:
    echo "  Frame[", fid, "]: ERROR: ", frame.error.msg

echo ""
echo "=== andThen chain with handler inheritance ==="

# Chained computation: fetch weather, then fetch forecast based on result
let chainedEff = performHttpGet("https://weather.api/tokyo")
  .andThen(proc(resp: string): Eff[string] {.gcsafe.} =
    # Second HTTP call based on first result
    performHttpGet("https://weather.api/forecast?city=tokyo")
      .map(proc(forecast: string): string {.gcsafe.} =
        "Current: " & resp & " | Forecast: " & forecast))

let engine2 = newEngine(budget = 200)
let fid2 = engine2.newFrame(chainedEff.program, chainedEff.program.entry)

# Handler installed on parent — child frames inherit it automatically
let mock2 = mockHttpGetHandler(@[
  ("weather.api/tokyo", """{"temp": 22}"""),
  ("weather.api/forecast", """{"tomorrow": "rain"}"""),
])
engine2.frames[fid2].handlers.add(mock2)

engine2.runLoop()

echo "Chain result: "
if engine2.frames[fid2].hasResult:
  echo "  ", engine2.frames[fid2].result.strVal
echo "All done: ", engine2.allDone()

echo ""
echo "=== Deferred (async) parallel with external resume ==="

let asyncEff0 = performHttpGet("https://slow.api/data1")
let asyncEff1 = performHttpGet("https://slow.api/data2")

let engine3 = newEngine(budget = 200)
let afid0 = engine3.newFrame(asyncEff0.program, asyncEff0.program.entry)
let afid1 = engine3.newFrame(asyncEff1.program, asyncEff1.program.entry)

# Deferred handler: frames suspend immediately
engine3.frames[afid0].handlers.add(deferredHttpGetHandler())
engine3.frames[afid1].handlers.add(deferredHttpGetHandler())

engine3.runLoop()
echo "After initial run: suspended=", engine3.hasSuspended(), " allDone=", engine3.allDone()

# Simulate async I/O completion (e.g., from HTTP callback)
engine3.resumeFrame(afid1, boxStr("data2 arrived first"))
engine3.resumeFrame(afid0, boxStr("data1 arrived second"))
engine3.runLoop()

echo "After resume: allDone=", engine3.allDone()
echo "  Frame[0]: ", engine3.frames[afid0].result.strVal
echo "  Frame[1]: ", engine3.frames[afid1].result.strVal
