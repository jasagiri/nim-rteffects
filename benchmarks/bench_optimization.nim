## Benchmark: RTEffects optimization strategies
##
## Compares:
## A. Baseline:      build Eff[T] + new Engine every time (current `run`)
## B. Reuse Program: build Eff[T] once, new Engine every run
## C. Reuse Engine:  build Eff[T] every time, reuse Engine (reset between runs)
## D. Reuse Both:    build Eff[T] once, reuse Engine (reset between runs)

import std/[monotimes, times, strformat, strutils, stats, tables, deques]
import rteffects/core
import rteffects/algebra
import rteffects/semantics
import rteffects/vm/types
import rteffects/vm/engine

const
  Warmup = 100
  Iterations = 10_000
  Repeats = 5

# ---------------------------------------------------------------------------
# Anti-optimization
# ---------------------------------------------------------------------------

var sink {.volatile.}: int

proc doNotOptimize(x: int) {.noinline.} =
  sink = x

# ---------------------------------------------------------------------------
# Engine reset: clear frames/queue, keep the object
# ---------------------------------------------------------------------------

proc reset(engine: Engine) =
  engine.frames.clear()
  engine.readyQ = initDeque[int]()
  engine.nextId = 0

# ---------------------------------------------------------------------------
# Low-level run that accepts a pre-existing engine
# ---------------------------------------------------------------------------

proc runWith[T](eff: Eff[T], engine: Engine): Result[T] =
  try:
    let res = engine.interpretProgram(eff.program, eff.program.entry)
    if res.failed:
      let ev = evalFalse[T](res.error)
      toResult(ev)
    elif res.hasResult:
      let ev = evalTrue(eff.unboxer(res.result))
      toResult(ev)
    else:
      let ev = evalNeither[T]()
      toResult(ev)
  except Exception as e:
    err[T](RtError(kind: ExceptionRaised, msg: e.msg))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type BenchResult = object
  name: string
  mean: float
  stddev: float
  min: float
  max: float

proc bench(name: string, warmup, iters, repeats: int,
           body: proc() {.closure.}): BenchResult =
  for _ in 0 ..< warmup:
    body()

  var samples: RunningStat
  for _ in 0 ..< repeats:
    let start = getMonoTime()
    for _ in 0 ..< iters:
      body()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / iters.float
    samples.push(elapsed)

  BenchResult(
    name: name,
    mean: samples.mean,
    stddev: samples.standardDeviation,
    min: samples.min,
    max: samples.max,
  )

proc pad(s: string, w: int, right = false): string =
  if s.len >= w: return s
  let fill = ' '.repeat(w - s.len)
  if right: fill & s else: s & fill

proc report(results: seq[BenchResult]) =
  echo ""
  echo pad("Benchmark", 55) & pad("Mean (ns)", 12, true) &
       pad("StdDev", 10, true) & pad("Min", 12, true) & pad("Max", 12, true)
  echo "-".repeat(101)
  for r in results:
    echo pad(r.name, 55) &
         pad(&"{r.mean:.1f}", 12, true) &
         pad(&"{r.stddev:.1f}", 10, true) &
         pad(&"{r.min:.1f}", 12, true) &
         pad(&"{r.max:.1f}", 12, true)
  echo ""

proc speedup(baseline, optimized: BenchResult): string =
  if optimized.mean < 0.1: return "N/A"
  &"{baseline.mean / optimized.mean:.2f}x faster"

# ---------------------------------------------------------------------------
# Eff[T] builders (extracted to avoid measuring build cost in wrong places)
# ---------------------------------------------------------------------------

proc buildPure(): Eff[int] {.noinline.} =
  pure[int](42)

proc buildChain5(): Eff[int] {.noinline.} =
  pure[int](1)
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 3))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x - 1))

proc buildEffect(): Eff[int] {.noinline.} =
  let tag = EffectTag("double")
  perform[int](tag, boxInt(21))
    .handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      resume(boxInt(unboxInt(payload) * 2))
    )

proc buildMap3(): Eff[int] {.noinline.} =
  pure[int](1)
    .map(proc(x: int): int {.gcsafe.} = x + 1)
    .map(proc(x: int): int {.gcsafe.} = x * 2)
    .map(proc(x: int): int {.gcsafe.} = x + 3)

proc buildDeep(depth: int): Eff[int] =
  var eff = pure[int](0)
  for i in 0 ..< depth:
    eff = eff.andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
  eff

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc runScenario(label: string, build: proc(): Eff[int] {.closure.},
                 budget: int = 10000) =
  echo &"\n--- {label} ---"

  var results: seq[BenchResult]

  # A. Baseline: build + new engine every time
  let a = bench("A. baseline (build + new engine)", Warmup, Iterations, Repeats,
    proc() =
      let eff = build()
      doNotOptimize(run[int](eff, budget).ok)
  )
  results.add(a)

  # B. Reuse program: build once, new engine every run
  let cachedEff = build()
  let b = bench("B. reuse program (new engine)", Warmup, Iterations, Repeats,
    proc() =
      doNotOptimize(run[int](cachedEff, budget).ok)
  )
  results.add(b)

  # C. Reuse engine: build every time, reset engine
  let engineC = newEngine(budget)
  let c = bench("C. reuse engine (build every time)", Warmup, Iterations, Repeats,
    proc() =
      engineC.reset()
      let eff = build()
      doNotOptimize(runWith[int](eff, engineC).ok)
  )
  results.add(c)

  # D. Reuse both: build once, reset engine
  let cachedEffD = build()
  let engineD = newEngine(budget)
  let d = bench("D. reuse both (program + engine)", Warmup, Iterations, Repeats,
    proc() =
      engineD.reset()
      doNotOptimize(runWith[int](cachedEffD, engineD).ok)
  )
  results.add(d)

  report(results)

  echo "  vs baseline:"
  echo &"    B (reuse program): {speedup(a, b)}"
  echo &"    C (reuse engine):  {speedup(a, c)}"
  echo &"    D (reuse both):    {speedup(a, d)}"

proc main() =
  echo "=========================================="
  echo " RTEffects Optimization Benchmark"
  echo "=========================================="
  echo &" Iterations: {Iterations}"
  echo &" Repeats:    {Repeats}"
  echo &" Warmup:     {Warmup}"

  runScenario("1. Pure value",
    proc(): Eff[int] = buildPure())
  runScenario("2. andThen 5-step chain",
    proc(): Eff[int] = buildChain5())
  runScenario("3. perform + handle",
    proc(): Eff[int] = buildEffect())
  runScenario("4. map 3-step chain",
    proc(): Eff[int] = buildMap3())
  runScenario("5. Deep chain (depth=10)",
    proc(): Eff[int] = buildDeep(10), 1000)
  runScenario("6. Deep chain (depth=50)",
    proc(): Eff[int] = buildDeep(50), 5000)

when isMainModule:
  main()
