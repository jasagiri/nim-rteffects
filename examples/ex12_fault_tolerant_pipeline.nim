## ex12: Fault-Tolerant Data Processing Pipeline
##
## A 3-stage ETL pipeline (Extract → Transform → Load) modelled with
## Belnap 4-valued logic.  Each stage runs independently as an Eff[string]
## interpreted to Eval[string].  The stages are then chained with flatMap
## on Eval — exactly the property that distinguishes Belnap pipelines from
## exception-based ones:
##
##   tvTrue    → stage completed cleanly
##   tvFalse   → stage failed; downstream stages are skipped via flatMap
##   tvBoth    → stage produced a result AND an error (contradiction)
##               flatMap preserves the tvBoth flag through the chain
##
## Key insight: unlike exception-based pipelines, partial results are never
## discarded.  A tvBoth stage lets the pipeline keep running while recording
## that something was wrong.  toResult at the boundary collapses tvBoth to
## a Contradiction error, making contradictions explicit without hiding the
## partial data.

import std/options
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# ---------------------------------------------------------------------------
# Pipeline stage helpers
# ---------------------------------------------------------------------------

proc runStage(eff: Eff[string]): Eval[string] =
  interpret[string](eff)

proc stageSuccess(label, data: string): Eff[string] =
  pure[string](label & ":" & data)

proc stageFail(label, msg: string): Eff[string] =
  fail[string](RtError(kind: ForeignError, msg: label & " failed - " & msg))

# ---------------------------------------------------------------------------
# Scenario 1: All stages succeed → tvTrue pipeline
# ---------------------------------------------------------------------------
echo "=== Scenario 1: All stages succeed ==="

let extractOk  = runStage(stageSuccess("extract", "raw_rows=100"))
let transformOk = runStage(stageSuccess("transform", "cleaned_rows=98"))
let loadOk     = runStage(stageSuccess("load", "inserted=98"))

let pipeline1 = extractOk
  .flatMap(proc(extractResult: string): Eval[string] =
    transformOk.flatMap(proc(transformResult: string): Eval[string] =
      loadOk.map(proc(loadResult: string): string =
        extractResult & " | " & transformResult & " | " & loadResult
      )
    )
  )

echo "truth:  ", pipeline1.truth           # tvTrue
echo "value:  ", pipeline1.value.get
assert pipeline1.truth == tvTrue
assert pipeline1.value.isSome

let r1 = toResult(pipeline1)
echo "result: isOk=", r1.isOk             # true
assert r1.isOk

# ---------------------------------------------------------------------------
# Scenario 2: Middle stage (transform) fails → tvFalse, but extract ran
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 2: Transform stage fails ==="

let extractOk2   = runStage(stageSuccess("extract", "raw_rows=200"))
let transformFail = runStage(stageFail("transform", "schema mismatch"))
let loadOk2      = runStage(stageSuccess("load", "inserted=200"))

# Track which stages completed by observing when flatMap callbacks fire
var extractRan   = false
var transformRan = false
var loadRan      = false

let pipeline2 = extractOk2
  .flatMap(proc(extractResult: string): Eval[string] =
    extractRan = true                           # extract DID complete
    transformFail.flatMap(proc(_: string): Eval[string] =
      transformRan = true                       # this is NOT reached
      loadRan = true
      loadOk2
    )
  )

echo "truth:       ", pipeline2.truth           # tvFalse
echo "error:       ", pipeline2.error.get.msg
echo "extract ran: ", extractRan               # true
echo "transform ran:", transformRan            # false (flatMap short-circuits on tvFalse)
echo "load ran:    ", loadRan                  # false
assert pipeline2.truth == tvFalse
assert extractRan
assert not transformRan
assert not loadRan

let r2 = toResult(pipeline2)
echo "result: isOk=", r2.isOk, " err=", r2.err.msg
assert not r2.isOk

# ---------------------------------------------------------------------------
# Scenario 3: Extract produces evalBoth (result AND error) → contradiction
#             tracked through the chain; final pipeline is tvBoth
# ---------------------------------------------------------------------------
echo ""
echo "=== Scenario 3: Extract has contradiction (evalBoth) ==="

# A stage that produced partial output but also recorded a warning
let extractBoth = evalBoth[string](
  "extract:raw_rows=50_of_100",
  RtError(kind: ForeignError, msg: "extract: source incomplete, 50 rows missing"),
)

let transformNext = runStage(stageSuccess("transform", "cleaned_rows=48"))
let loadNext      = runStage(stageSuccess("load", "inserted=48"))

# flatMap on tvBoth: the callback IS invoked (value is present), but tvBoth
# is joined into the result truth so the contradiction is never silently dropped
let pipeline3 = extractBoth
  .flatMap(proc(extractResult: string): Eval[string] =
    transformNext.flatMap(proc(transformResult: string): Eval[string] =
      loadNext.map(proc(loadResult: string): string =
        extractResult & " | " & transformResult & " | " & loadResult
      )
    )
  )

echo "truth:  ", pipeline3.truth             # tvBoth — contradiction propagated
echo "value:  ", pipeline3.value.get         # partial result IS present
echo "error:  ", pipeline3.error.get.msg     # original extract warning preserved
assert pipeline3.truth == tvBoth
assert pipeline3.value.isSome               # partial result available despite contradiction

# toResult collapses tvBoth → Contradiction error
let r3 = toResult(pipeline3)
echo "result: isOk=", r3.isOk, " err.kind=", r3.err.kind
assert not r3.isOk
assert r3.err.kind == Contradiction

# ---------------------------------------------------------------------------
# Demonstrate the practical difference
# ---------------------------------------------------------------------------
echo ""
echo "=== Practical insight ==="

echo "Scenario 1 (all ok):          pipeline truth=", pipeline1.truth,
     " | toResult.isOk=", toResult(pipeline1).isOk

echo "Scenario 2 (mid-fail):        pipeline truth=", pipeline2.truth,
     " | toResult.isOk=", toResult(pipeline2).isOk,
     " | partial value present=", pipeline2.value.isSome

echo "Scenario 3 (contradiction):   pipeline truth=", pipeline3.truth,
     " | toResult.isOk=", toResult(pipeline3).isOk,
     " | partial value present=", pipeline3.value.isSome

# Unlike exceptions, tvFalse and tvBoth both carry diagnostic information:
# tvFalse  → value lost, error present        (normal failure, no partial result)
# tvBoth   → value present, error present     (contradiction, partial result survives)
# toResult always produces a clear 2-valued boundary: Ok | Err(Contradiction)

echo ""
echo "All ex12 checks passed."
