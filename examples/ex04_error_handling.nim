## ex04: Error Handling
##
## Errors short-circuit through andThen chains.
## The first failure stops the chain — subsequent steps are skipped.

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# --- Failure short-circuits the chain ---
let err = RtError(kind: ForeignError, msg: "database connection failed")
let eff1 = fail[int](err)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    echo "This should NOT print"
    pure[int](x + 1)
  )
let result1 = run[int](eff1)
assert not result1.isOk
echo "Short-circuit: ", result1.err.msg

# --- Failure mid-chain ---
let eff2 = pure[int](1)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    fail[int](RtError(kind: Timeout, msg: "step 2 timed out"))
  )
  .andThen(proc(x: int): Eff[int] {.gcsafe.} =
    echo "This should NOT print either"
    pure[int](x * 100)
  )
let result2 = run[int](eff2)
assert not result2.isOk
echo "Mid-chain failure: ", result2.err.kind, " - ", result2.err.msg

# --- Success flows through normally ---
let eff3 = pure[int](10)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 5))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
let result3 = run[int](eff3)
assert result3.isOk
echo "Success chain: 10 -> +5 -> *2 = ", result3.ok  # 30

echo "\nAll ex04 checks passed."
