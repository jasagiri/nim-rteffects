## ex03: Map — Transform Values
##
## map transforms the value inside an Eff without introducing new effects.
## Unlike andThen, the mapping function returns a plain value, not an Eff.

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# --- Double a value ---
let eff1 = pure[int](5).map(proc(x: int): int {.gcsafe.} = x * 2)
let result1 = run[int](eff1)
echo "5 * 2 = ", result1.ok  # 10

# --- Chain of maps ---
let eff2 = pure[int](3)
  .map(proc(x: int): int {.gcsafe.} = x + 1)   # 4
  .map(proc(x: int): int {.gcsafe.} = x * x)    # 16
let result2 = run[int](eff2)
echo "3 -> +1 -> ^2 = ", result2.ok  # 16

# --- Map failure propagates ---
let eff3 = fail[int](RtError(kind: Cancelled, msg: "cancelled"))
  .map(proc(x: int): int {.gcsafe.} = x * 100)  # never called
let result3 = run[int](eff3)
assert not result3.isOk
echo "fail.map(...) => ", result3.err.kind  # Cancelled

echo "\nAll ex03 checks passed."
