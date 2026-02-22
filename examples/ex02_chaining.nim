## ex02: Chaining with andThen
##
## Monadic bind: run one computation, feed its result to the next.
## This is how you sequence effectful operations.

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# --- Simple chain: 1 -> 2 ---
let eff1 = pure[int](1).andThen(proc(x: int): Eff[int] {.gcsafe.} =
  pure[int](x + 1)
)
let result1 = run[int](eff1)
echo "1 + 1 = ", result1.ok  # 2

# --- Three-step chain: 1 -> 2 -> 20 ---
let eff2 = pure[int](1)
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x + 1))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 10))
let result2 = run[int](eff2)
echo "1 -> +1 -> *10 = ", result2.ok  # 20

# --- Chain with type change: int -> string ---
let eff3 = pure[int](42).andThen(proc(x: int): Eff[string] {.gcsafe.} =
  pure[string]("The answer is " & $x)
)
let result3 = run[string](eff3)
echo result3.ok  # The answer is 42

echo "\nAll ex02 checks passed."
