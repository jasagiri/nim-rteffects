## ex11: Sensor Fusion with Belnap 4-Valued Logic
##
## Multiple sensors measure the same quantity. They may agree, contradict
## each other, go offline, or all fail. Belnap logic tracks the information
## state across all outcomes without discarding data.
##
## Each sensor reading is an Eff[int] (temperature in celsius).
## interpret returns Eval[int] carrying TruthValue alongside the reading.
## Fusing readings means combining their TruthValues via lattice operations:
##
##   join (LUB) — "what do we know when combining information sources?"
##   meet (GLB) — "what is common knowledge across all sources?"
##   leqI       — information ordering: tvNeither <=i tvTrue/tvFalse <=i tvBoth
##
## The bilattice encodes:
##   tvTrue    — sensor succeeded, value is reliable
##   tvFalse   — sensor failed with a definite error
##   tvBoth    — value present but a contradiction / fault also observed
##   tvNeither — sensor offline; no information at all

import std/options
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# ---------------------------------------------------------------------------
# Sensor abstraction
# ---------------------------------------------------------------------------

let sensorTag = EffectTag("sensor.read")

proc sensorRead(sensorId: int): Eff[int] =
  ## Request a temperature reading from the given sensor.
  perform[int](sensorTag, boxInt(sensorId))

proc withSensor(eff: Eff[int], sensorId: int,
                reading: int): Eff[int] =
  ## Handler: sensor always succeeds and returns `reading`.
  eff.handle(sensorTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      if unboxInt(payload) == sensorId:
        resume(boxInt(reading))
      else:
        abort(RtError(kind: ForeignError,
          msg: "sensor " & $unboxInt(payload) & " not available"))
  )

proc withSensorFault(eff: Eff[int], sensorId: int): Eff[int] =
  ## Handler: sensor is present but faults on every read.
  eff.handle(sensorTag,
    proc(payload: BoxedValue,
         resume: proc(v: BoxedValue) {.gcsafe.},
         abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      if unboxInt(payload) == sensorId:
        abort(RtError(kind: ForeignError,
          msg: "sensor " & $sensorId & " hardware fault"))
      else:
        abort(RtError(kind: ForeignError,
          msg: "sensor " & $unboxInt(payload) & " not available"))
  )

# ---------------------------------------------------------------------------
# Confidence assessment
# ---------------------------------------------------------------------------

type Confidence = enum
  cNone       ## No information — sensor offline
  cDegraded   ## Definite failure, system degraded
  cFull       ## Clean success, high confidence
  cAmbiguous  ## Contradictory signal, investigation needed

proc assessConfidence(tv: TruthValue): Confidence =
  ## Map a TruthValue to an operational confidence level.
  case tv
  of tvNeither: cNone
  of tvFalse:   cDegraded
  of tvTrue:    cFull
  of tvBoth:    cAmbiguous

# ---------------------------------------------------------------------------
# Fusion helpers
# ---------------------------------------------------------------------------

proc fuseReadings(a, b: Eval[int]): TruthValue =
  ## Combine two sensor evaluations via information join.
  ## join gives the LUB: captures everything known from both sources.
  join(a.truth, b.truth)

proc commonKnowledge(a, b: Eval[int]): TruthValue =
  ## Common knowledge via information meet.
  ## meet gives the GLB: only what both sources agree on.
  meet(a.truth, b.truth)

# ---------------------------------------------------------------------------
# Scenario 1: two sensors agree at 25°C  →  tvTrue + tvTrue = tvTrue
# ---------------------------------------------------------------------------

echo "=== Scenario 1: Both sensors agree ==="
let s1a = sensorRead(1).withSensor(1, 25)
let s1b = sensorRead(2).withSensor(2, 25)

let ev1a = interpret[int](s1a)
let ev1b = interpret[int](s1b)

echo "sensor 1: truth=", ev1a.truth, " value=", ev1a.value
echo "sensor 2: truth=", ev1b.truth, " value=", ev1b.value

let fused1 = fuseReadings(ev1a, ev1b)
let common1 = commonKnowledge(ev1a, ev1b)
echo "fused (join):          ", fused1          # tvTrue
echo "common (meet):         ", common1          # tvTrue
echo "confidence:            ", assessConfidence(fused1)

assert ev1a.truth == tvTrue
assert ev1a.value == some(25)
assert ev1b.truth == tvTrue
assert fused1 == tvTrue
assert common1 == tvTrue
assert assessConfidence(fused1) == cFull

# ---------------------------------------------------------------------------
# Scenario 2: one sensor reads 30°C, the other faults  →  join(tvTrue, tvFalse) = tvBoth
# ---------------------------------------------------------------------------

echo "\n=== Scenario 2: One reading, one fault ==="
let s2ok    = sensorRead(1).withSensor(1, 30)
let s2fault = sensorRead(2).withSensorFault(2)

let ev2ok    = interpret[int](s2ok)
let ev2fault = interpret[int](s2fault)

echo "sensor 1 (ok):    truth=", ev2ok.truth,    " value=", ev2ok.value
echo "sensor 2 (fault): truth=", ev2fault.truth,  " error=", ev2fault.error

let fused2  = fuseReadings(ev2ok, ev2fault)
let common2 = commonKnowledge(ev2ok, ev2fault)
echo "fused (join):  ", fused2           # tvBoth — value present, fault also known
echo "common (meet): ", common2          # tvNeither — only what both share: nothing
echo "confidence:    ", assessConfidence(fused2)

assert ev2ok.truth == tvTrue
assert ev2fault.truth == tvFalse
assert fused2 == tvBoth     # join(tvTrue, tvFalse) = tvBoth
assert common2 == tvNeither # meet(tvTrue, tvFalse) = tvNeither
assert assessConfidence(fused2) == cAmbiguous

# ---------------------------------------------------------------------------
# Scenario 3: sensor offline (unhandled effect) → tvFalse (ForeignError)
# ---------------------------------------------------------------------------

echo "\n=== Scenario 3: Sensor offline (no handler) ==="
# perform with no matching handler produces tvFalse + ForeignError
let s3offline = sensorRead(99)  # no handler installed

let ev3 = interpret[int](s3offline)
echo "sensor 99 (offline): truth=", ev3.truth, " error=", ev3.error

assert ev3.truth == tvFalse
assert ev3.error.isSome
echo "confidence: ", assessConfidence(ev3.truth)
assert assessConfidence(ev3.truth) == cDegraded

# ---------------------------------------------------------------------------
# Scenario 4: all sensors fail  →  tvFalse + tvFalse = tvFalse
# ---------------------------------------------------------------------------

echo "\n=== Scenario 4: All sensors fail ==="
let s4a = sensorRead(1).withSensorFault(1)
let s4b = sensorRead(2).withSensorFault(2)

let ev4a = interpret[int](s4a)
let ev4b = interpret[int](s4b)

echo "sensor 1 (fault): truth=", ev4a.truth
echo "sensor 2 (fault): truth=", ev4b.truth

let fused4  = fuseReadings(ev4a, ev4b)
let common4 = commonKnowledge(ev4a, ev4b)
echo "fused (join):  ", fused4      # tvFalse — both failed
echo "common (meet): ", common4     # tvFalse — both agree on failure
echo "confidence:    ", assessConfidence(fused4)

assert ev4a.truth == tvFalse
assert ev4b.truth == tvFalse
assert fused4  == tvFalse
assert common4 == tvFalse
assert assessConfidence(fused4) == cDegraded

# ---------------------------------------------------------------------------
# Information ordering: leqI
# ---------------------------------------------------------------------------

echo "\n=== Information Ordering ==="
# tvNeither is the bottom: no info is less than any info
echo "tvNeither <=i tvTrue:    ", leqI(tvNeither, tvTrue)    # true
echo "tvNeither <=i tvFalse:   ", leqI(tvNeither, tvFalse)   # true
echo "tvNeither <=i tvBoth:    ", leqI(tvNeither, tvBoth)    # true
# tvBoth is the top: having both signals is more informative than either
echo "tvTrue    <=i tvBoth:    ", leqI(tvTrue, tvBoth)       # true
echo "tvFalse   <=i tvBoth:    ", leqI(tvFalse, tvBoth)      # true
# tvTrue and tvFalse are incomparable (different kinds of information)
echo "tvTrue    <=i tvFalse:   ", leqI(tvTrue, tvFalse)      # false
echo "tvFalse   <=i tvTrue:    ", leqI(tvFalse, tvTrue)      # false

assert leqI(tvNeither, tvTrue)
assert leqI(tvNeither, tvFalse)
assert leqI(tvNeither, tvBoth)
assert leqI(tvTrue,    tvBoth)
assert leqI(tvFalse,   tvBoth)
assert not leqI(tvTrue,  tvFalse)
assert not leqI(tvFalse, tvTrue)

# ---------------------------------------------------------------------------
# Demonstrate: meet gives common knowledge in a multi-sensor array
# ---------------------------------------------------------------------------

echo "\n=== Common Knowledge Across Sensor Array ==="
# Three sensors: two succeed, one faults.
# Meet of all three gives what every source agrees on.
let arr1 = interpret[int](sensorRead(1).withSensor(1, 20))   # tvTrue
let arr2 = interpret[int](sensorRead(2).withSensor(2, 20))   # tvTrue
let arr3 = interpret[int](sensorRead(3).withSensorFault(3))  # tvFalse

let meetAll = meet(meet(arr1.truth, arr2.truth), arr3.truth)
echo "meet(tvTrue, tvTrue, tvFalse) = ", meetAll  # tvNeither
echo "confidence: ", assessConfidence(meetAll)

assert meetAll == tvNeither  # no universal agreement; sensor fault breaks consensus

echo "\nAll ex11 checks passed."
