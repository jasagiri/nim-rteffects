## Benchmark: Nim exceptions vs rteffects algebraic effects
##
## Compares performance of:
## 1. Pure value wrapping/unwrapping
## 2. Sequential chaining (andThen vs procedural)
## 3. Error propagation (fail short-circuit vs exception throw)
## 4. Effect handling (perform/handle vs exception dispatch)
## 5. Deep chains (scaling behavior)
## 6. Map chains (functor overhead)

import std/[monotimes, times, strformat, strutils, stats]
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

const
  Warmup = 100
  Iterations = 10_000
  Repeats = 5

# ---------------------------------------------------------------------------
# Anti-optimization: prevent dead code elimination
# ---------------------------------------------------------------------------

var sink {.volatile.}: int
var sinkStr {.volatile.}: cstring

proc doNotOptimize(x: int) {.noinline.} =
  sink = x

proc doNotOptimize(x: string) {.noinline.} =
  sinkStr = cstring(x)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type BenchResult = object
  name: string
  mean: float  # ns per iteration
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
  echo pad("Benchmark", 50) & pad("Mean (ns)", 12, true) &
       pad("StdDev", 10, true) & pad("Min", 12, true) & pad("Max", 12, true)
  echo "-".repeat(96)
  for r in results:
    echo pad(r.name, 50) &
         pad(&"{r.mean:.1f}", 12, true) &
         pad(&"{r.stddev:.1f}", 10, true) &
         pad(&"{r.min:.1f}", 12, true) &
         pad(&"{r.max:.1f}", 12, true)
  echo ""

proc ratio(a, b: BenchResult): string =
  if b.mean < 0.1: return "N/A"
  &"{a.mean / b.mean:.1f}x"

# ---------------------------------------------------------------------------
# 1. Pure value: wrap and unwrap
# ---------------------------------------------------------------------------

proc benchPureException(): int {.noinline.} =
  try:
    return 42
  except CatchableError:
    return -1

proc benchPureRteffects(): int {.noinline.} =
  let r = run[int](pure[int](42))
  r.ok

# ---------------------------------------------------------------------------
# 2. Sequential chaining (5 steps)
# ---------------------------------------------------------------------------

proc benchChainException(): int {.noinline.} =
  var x = 1
  x = x + 1
  x = x * 2
  x = x + 3
  x = x * 2
  x = x - 1
  x

proc benchChainRteffects(): int {.noinline.} =
  let eff = pure[int](1)
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 3))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x - 1))
  let r = run[int](eff)
  r.ok

# ---------------------------------------------------------------------------
# 3. Error propagation (fail at step 2, skip remaining 3 steps)
# ---------------------------------------------------------------------------

type BenchError = object of CatchableError

proc benchErrorException(): string {.noinline.} =
  try:
    discard 1 + 1
    raise newException(BenchError, "err")
  except BenchError as e:
    return e.msg

proc benchErrorRteffects(): string {.noinline.} =
  let eff = pure[int](1)
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} =
      fail[int](RtError(kind: ForeignError, msg: "err")))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 3))
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 4))
  let r = run[int](eff)
  r.err.msg

# ---------------------------------------------------------------------------
# 4. Effect handling (perform + handle vs throw + catch)
# ---------------------------------------------------------------------------

proc benchEffectException(): int {.noinline.} =
  try:
    raise newException(BenchError, "21")
  except BenchError as e:
    return parseInt(e.msg) * 2

proc benchEffectRteffects(): int {.noinline.} =
  let tag = EffectTag("double")
  let eff = perform[int](tag, boxInt(21))
    .handle(tag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let n = unboxInt(payload)
      resume(boxInt(n * 2))
    )
  let r = run[int](eff)
  r.ok

# ---------------------------------------------------------------------------
# 5. Deep chain (N sequential steps)
# ---------------------------------------------------------------------------

proc benchDeepException(depth: int): int {.noinline.} =
  var x = 0
  try:
    for i in 0 ..< depth:
      x = x + 1
    return x
  except CatchableError:
    return -1

proc benchDeepRteffects(depth: int): int {.noinline.} =
  var eff = pure[int](0)
  for i in 0 ..< depth:
    eff = eff.andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
  let r = run[int](eff, budget = depth * 10 + 1000)
  r.ok

# ---------------------------------------------------------------------------
# 6. Map chain (pure transformation, no effects)
# ---------------------------------------------------------------------------

proc benchMapException(): int {.noinline.} =
  var x = 1
  x = x + 1
  x = x * 2
  x = x + 3
  x

proc benchMapRteffects(): int {.noinline.} =
  let eff = pure[int](1)
    .map(proc(x: int): int {.gcsafe.} = x + 1)
    .map(proc(x: int): int {.gcsafe.} = x * 2)
    .map(proc(x: int): int {.gcsafe.} = x + 3)
  let r = run[int](eff)
  r.ok

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() =
  echo "=========================================="
  echo " Exception vs RTEffects Benchmark"
  echo "=========================================="
  echo &" Iterations: {Iterations}"
  echo &" Repeats:    {Repeats}"
  echo &" Warmup:     {Warmup}"
  echo &" Compile:    -d:release -d:danger --opt:speed"

  var results: seq[BenchResult]

  # --- 1. Pure value ---
  echo "\n--- 1. Pure value wrap/unwrap ---"

  let pureExc = bench("exception: pure return", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchPureException()))

  let pureRte = bench("rteffects: pure[int] + run", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchPureRteffects()))

  results.add(pureExc)
  results.add(pureRte)
  report(@[pureExc, pureRte])
  echo &"  Ratio (rteffects / exception): {ratio(pureRte, pureExc)}"

  # --- 2. Sequential chaining ---
  echo "\n--- 2. Sequential chaining (5 steps) ---"

  let chainExc = bench("exception: sequential 5-step", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchChainException()))

  let chainRte = bench("rteffects: andThen 5-step", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchChainRteffects()))

  results.add(chainExc)
  results.add(chainRte)
  report(@[chainExc, chainRte])
  echo &"  Ratio (rteffects / exception): {ratio(chainRte, chainExc)}"

  # --- 3. Error propagation ---
  echo "\n--- 3. Error propagation (fail at step 2 of 5) ---"

  let errExc = bench("exception: throw + catch", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchErrorException()))

  let errRte = bench("rteffects: fail short-circuit", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchErrorRteffects()))

  results.add(errExc)
  results.add(errRte)
  report(@[errExc, errRte])
  echo &"  Ratio (rteffects / exception): {ratio(errRte, errExc)}"

  # --- 4. Effect handling ---
  echo "\n--- 4. Effect handling (perform/handle vs throw/catch) ---"

  let effExc = bench("exception: throw + catch dispatch", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchEffectException()))

  let effRte = bench("rteffects: perform + handle", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchEffectRteffects()))

  results.add(effExc)
  results.add(effRte)
  report(@[effExc, effRte])
  echo &"  Ratio (rteffects / exception): {ratio(effRte, effExc)}"

  # --- 5. Deep chain ---
  echo "\n--- 5. Deep chain scaling ---"

  for depth in [10, 50, 100]:
    let deepExc = bench(&"exception: depth={depth}", Warmup, Iterations div 10, Repeats,
      proc() = doNotOptimize(benchDeepException(depth)))

    let deepRte = bench(&"rteffects: depth={depth}", Warmup, Iterations div 10, Repeats,
      proc() = doNotOptimize(benchDeepRteffects(depth)))

    results.add(deepExc)
    results.add(deepRte)
    report(@[deepExc, deepRte])
    echo &"  Ratio (rteffects / exception): {ratio(deepRte, deepExc)}"

  # --- 6. Map chain ---
  echo "\n--- 6. Map chain (3 pure transforms) ---"

  let mapExc = bench("exception: direct computation", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchMapException()))

  let mapRte = bench("rteffects: map chain", Warmup, Iterations, Repeats,
    proc() = doNotOptimize(benchMapRteffects()))

  results.add(mapExc)
  results.add(mapRte)
  report(@[mapExc, mapRte])
  echo &"  Ratio (rteffects / exception): {ratio(mapRte, mapExc)}"

  # --- Summary ---
  echo "\n=========================================="
  echo " Summary (all benchmarks)"
  echo "=========================================="
  report(results)

when isMainModule:
  main()
