## Cost breakdown: where RTEffects spends time (post-optimization)
##
## Isolates individual costs:
## 1. Table[int, Frame] lookup/write
## 2. Boxing/unboxing
## 3. Closure call overhead
## 4. Eff[T] program construction (andThen mergeProgram)
## 5. Engine.newFrame
## 6. Deque operations
## 7. Full pipelines
##
## Goal: identify remaining cost factors after StateMachine removal.

import std/[monotimes, times, strformat, strutils, stats, tables, deques]
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

const
  Warmup = 200
  Iterations = 50_000
  Repeats = 5

var sink {.volatile.}: int

proc doNotOptimize(x: int) {.noinline.} =
  sink = x

type BenchResult = object
  name: string
  mean: float
  stddev: float
  min: float

proc bench(name: string, iters: int,
           body: proc() {.closure.}): BenchResult =
  for _ in 0 ..< Warmup:
    body()

  var samples: RunningStat
  for _ in 0 ..< Repeats:
    let start = getMonoTime()
    for _ in 0 ..< iters:
      body()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / iters.float
    samples.push(elapsed)

  BenchResult(name: name, mean: samples.mean,
              stddev: samples.standardDeviation, min: samples.min)

proc pad(s: string, w: int, right = false): string =
  if s.len >= w: return s
  let fill = ' '.repeat(w - s.len)
  if right: fill & s else: s & fill

proc report(results: seq[BenchResult]) =
  echo ""
  echo pad("Component", 55) & pad("Mean (ns)", 12, true) &
       pad("StdDev", 10, true) & pad("Min (ns)", 12, true)
  echo "-".repeat(89)
  for r in results:
    echo pad(r.name, 55) &
         pad(&"{r.mean:.1f}", 12, true) &
         pad(&"{r.stddev:.1f}", 10, true) &
         pad(&"{r.min:.1f}", 12, true)
  echo ""

proc main() =
  echo "=========================================="
  echo " RTEffects Cost Breakdown (post-optimization)"
  echo "=========================================="
  echo &" Iterations: {Iterations}, Repeats: {Repeats}"

  var results: seq[BenchResult]

  # --- 1. Table[int, Frame] read + write ---
  block:
    var t = initTable[int, Frame]()
    t[0] = Frame(id: FrameId(0), pc: ContId(0), program: EffProgram(),
                 state: fsReady)
    results.add bench("1. Table[int,Frame] read+write", Iterations,
      proc() =
        var f = t[0]
        f.hasResult = true
        t[0] = f
        doNotOptimize(ord(f.hasResult))
    )

  # --- 2. BoxedValue boxing + unboxing ---
  results.add bench("2. boxInt + unboxInt", Iterations,
    proc() =
      let b = boxInt(42)
      doNotOptimize(unboxInt(b))
  )

  # --- 3. Closure call overhead ---
  block:
    let f = proc(x: int): int {.gcsafe, closure.} = x + 1
    results.add bench("3. Closure call (int -> int)", Iterations,
      proc() = doNotOptimize(f(41))
    )

  # --- 4. Deque push + pop ---
  block:
    var q = initDeque[int]()
    results.add bench("4. Deque addLast + popFirst", Iterations,
      proc() =
        q.addLast(0)
        doNotOptimize(q.popFirst())
    )

  # --- 5. Eff[int] program construction: pure ---
  results.add bench("5. pure[int](42) construction", Iterations,
    proc() =
      let eff = pure[int](42)
      doNotOptimize(eff.program.ops.len)
  )

  # --- 6. Eff[int] construction: andThen (1 step) ---
  results.add bench("6. pure + andThen (1 step) construction", Iterations,
    proc() =
      let eff = pure[int](1)
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
      doNotOptimize(eff.program.ops.len)
  )

  # --- 7. Engine creation ---
  results.add bench("7. newEngine() creation", Iterations,
    proc() =
      let e = newEngine(10000)
      doNotOptimize(e.budget)
  )

  # --- 8. Full: pure[int](42) + run ---
  results.add bench("8. FULL: pure[int](42) + run", Iterations,
    proc() =
      doNotOptimize(run[int](pure[int](42)).ok)
  )

  # --- 9. Full: andThen 5-step + run ---
  results.add bench("9. FULL: andThen 5-step + run", Iterations div 5,
    proc() =
      let eff = pure[int](1)
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 3))
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
        .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x - 1))
      doNotOptimize(run[int](eff).ok)
  )

  # --- 10. Full: perform + handle + run ---
  results.add bench("10. FULL: perform + handle + run", Iterations,
    proc() =
      let tag = EffectTag("double")
      let eff = perform[int](tag, boxInt(21))
        .handle(tag, proc(payload: BoxedValue,
            resume: proc(v: BoxedValue) {.gcsafe.},
            abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
          resume(boxInt(unboxInt(payload) * 2))
        )
      doNotOptimize(run[int](eff).ok)
  )

  # --- Report ---
  echo "\n=========================================="
  echo " Results"
  echo "=========================================="
  report(results)

  # --- Analysis ---
  echo "--- Cost analysis for pure[int](42) + run ---"
  let fullPure = results[7].mean  # #8
  echo &"  Total:                      {fullPure:>8.1f} ns"
  echo &"  = newEngine:                {results[6].mean:>8.1f} ns ({results[6].mean / fullPure * 100:.0f}%)"
  echo &"  + pure construction:        {results[4].mean:>8.1f} ns ({results[4].mean / fullPure * 100:.0f}%)"
  echo &"  + Table read/write:         {results[0].mean:>8.1f} ns ({results[0].mean / fullPure * 100:.0f}%)"
  echo &"  + boxing:                   {results[1].mean:>8.1f} ns ({results[1].mean / fullPure * 100:.0f}%)"
  echo &"  + Deque ops:                {results[3].mean:>8.1f} ns ({results[3].mean / fullPure * 100:.0f}%)"

when isMainModule:
  main()
