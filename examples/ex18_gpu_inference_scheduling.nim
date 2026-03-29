## ex18: GPU inference scheduling with priority dispatch
##
## Demonstrates how to use the gpu:infer effect to model GPU-bound
## inference operations (LLM, VLM, TTS) as algebraic effects with
## priority-based scheduling.
##
## Key concepts:
##   - GpuInferPayload: kind + priority + serialized request
##   - GpuInferPriority: Background < Normal < UserFacing
##   - Deferred handler: frame suspends until GPU scheduler resumes
##   - Mock handler: testing without GPU hardware
##   - Priority queue: user-facing requests preempt background work
##
## Scenario: A probe system processes camera frames (VLM, background)
## and user chat (LLM, user-facing). User chat must preempt VLM.

import std/strutils
import rteffects
import rteffects/handlers
import rteffects/vm/engine
import rteffects/vm/types

echo "=== GPU inference scheduling ==="

# ─── 1. Mock handler: test without GPU ───

echo "\n--- Mock handler (testing) ---"

let llmEff = performGpuInfer(GpuInferPayload(
  kind: "llm",
  priority: gipUserFacing,
  requestJson: """{"messages":[{"role":"user","content":"hello"}]}""",
))
let llmResult = run[GpuInferResult](handle[GpuInferResult](
  llmEff, gpuInferTag,
  mockGpuInferHandler(@[
    ("llm", """{"response":"Hi there!"}"""),
    ("vlm", """{"scene":"A room with a TV."}"""),
  ]).impl))

assert llmResult.isOk
assert llmResult.ok.success
assert "Hi there!" in llmResult.ok.responseJson
echo "LLM mock: ", llmResult.ok.responseJson

# ─── 2. Deferred handler: async scheduling ───

echo "\n--- Deferred handler (async GPU scheduler) ---"

let eng = newEngine(budget = 500)

# Submit VLM (background) and LLM (user-facing) requests
let vlmPayload = GpuInferPayload(
  kind: "vlm", priority: gipBackground,
  requestJson: """{"image":"base64...","prompt":"describe"}""")
let llmPayload = GpuInferPayload(
  kind: "llm", priority: gipUserFacing,
  requestJson: """{"messages":[{"role":"user","content":"what's on TV?"}]}""")

let vlmEff = handle[GpuInferResult](
  performGpuInfer(vlmPayload), gpuInferTag, deferredGpuInferHandler().impl)
let llmEff2 = handle[GpuInferResult](
  performGpuInfer(llmPayload), gpuInferTag, deferredGpuInferHandler().impl)

let vlmFid = eng.newFrame(vlmEff.program, vlmEff.program.entry)
let llmFid = eng.newFrame(llmEff2.program, llmEff2.program.entry)

eng.runLoop()
assert eng.hasSuspended()
echo "Both frames suspended — waiting for GPU"

# ─── 3. Priority dispatch: resume LLM first ───

# A real GPU scheduler would sort by priority and dispatch highest first.
# Here we simulate: LLM (priority=10) runs before VLM (priority=0).

# Simulate: LLM completes first (user-facing priority)
eng.resumeFrame(llmFid, boxRef(GpuInferResult(
  success: true,
  responseJson: """{"response":"The TV shows a drama."}""")))
eng.runLoop()

echo "LLM done: ", eng.frames[llmFid].state
assert eng.frames[llmFid].state == fsDone

# VLM still suspended
assert eng.frames[vlmFid].state == fsSuspended
echo "VLM still waiting (lower priority)"

# Now resume VLM (background)
eng.resumeFrame(vlmFid, boxRef(GpuInferResult(
  success: true,
  responseJson: """{"scene":"Indoor, person watching TV with subtitles."}""")))
eng.runLoop()

assert eng.allDone()
echo "VLM done: all frames completed"

# ─── 4. Chaining GPU inference with post-processing ───

echo "\n--- Effect chaining (GPU infer → post-process) ---"

let pipeline = performGpuInfer(GpuInferPayload(
  kind: "vlm", priority: gipBackground,
  requestJson: """{"image":"..."}""",
)).map(proc(r: GpuInferResult): string {.gcsafe.} =
  if r.success: "Scene: " & r.responseJson
  else: "VLM failed: " & r.error
)

let pipeResult = run[string](handle[string](
  pipeline, gpuInferTag,
  mockGpuInferHandler(@[("vlm", """{"description":"a park"}""")]).impl))

assert pipeResult.isOk
assert "a park" in pipeResult.ok
echo "Pipeline: ", pipeResult.ok

echo "\n=== All GPU scheduling examples passed ==="
