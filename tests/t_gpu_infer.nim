## Tests for GPU inference effect handlers.

import std/[unittest, strutils]
import rteffects

suite "GPU Infer Effect":

  test "Given mock handler When performGpuInfer llm Then returns mock response":
    let payload = GpuInferPayload(kind: "llm", priority: gipUserFacing, requestJson: "{}")
    let eff = handle[GpuInferResult](
      performGpuInfer(payload),
      gpuInferTag,
      mockGpuInferHandler(@[("llm", """{"text":"hello"}""")]).impl)
    let result = run[GpuInferResult](eff)
    check result.isOk
    check result.ok.success
    check result.ok.responseJson == """{"text":"hello"}"""

  test "Given mock handler When performGpuInfer vlm Then returns vlm mock":
    let payload = GpuInferPayload(kind: "vlm", priority: gipBackground, requestJson: "{}")
    let eff = handle[GpuInferResult](
      performGpuInfer(payload),
      gpuInferTag,
      mockGpuInferHandler(@[("vlm", """{"scene":"room"}""")]).impl)
    let result = run[GpuInferResult](eff)
    check result.isOk
    check result.ok.responseJson == """{"scene":"room"}"""

  test "Given mock handler When unknown kind Then aborts":
    let payload = GpuInferPayload(kind: "unknown", priority: gipNormal, requestJson: "{}")
    let eff = handle[GpuInferResult](
      performGpuInfer(payload),
      gpuInferTag,
      mockGpuInferHandler(@[("llm", "x")]).impl)
    let result = run[GpuInferResult](eff)
    check not result.isOk
    check "No mock GPU response" in result.err.msg

  test "Given deferred handler When performGpuInfer Then frame suspends":
    let payload = GpuInferPayload(kind: "llm", priority: gipUserFacing, requestJson: "{}")
    let eff = handle[GpuInferResult](
      performGpuInfer(payload),
      gpuInferTag,
      deferredGpuInferHandler().impl)
    let eng = newEngine(budget = 100)
    let fid = eng.newFrame(eff.program, eff.program.entry)
    eng.runLoop()
    check eng.hasSuspended()
    check eng.frames[fid].state == fsSuspended

  test "Given deferred handler When resume with result Then completes":
    let payload = GpuInferPayload(kind: "llm", priority: gipUserFacing, requestJson: "{}")
    let eff = handle[GpuInferResult](
      performGpuInfer(payload),
      gpuInferTag,
      deferredGpuInferHandler().impl)
    let eng = newEngine(budget = 100)
    let fid = eng.newFrame(eff.program, eff.program.entry)
    eng.runLoop()
    check eng.hasSuspended()
    eng.resumeFrame(fid, boxRef(GpuInferResult(success: true, responseJson: """{"ok":true}""")))
    eng.runLoop()
    check eng.allDone()

  test "Given priority enum When comparing Then userFacing > background":
    check ord(gipUserFacing) > ord(gipBackground)
    check ord(gipNormal) > ord(gipBackground)
