## ex01: Pure Values and Running
##
## The simplest usage: create pure values and failures,
## then run them to get Result[T].

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# --- Pure value ---
let eff1 = pure[int](42)
let result1 = run[int](eff1)
assert result1.isOk
echo "pure(42) => ", result1.ok  # 42

# --- Pure string ---
let eff2 = pure[string]("hello")
let result2 = run[string](eff2)
assert result2.isOk
echo "pure(\"hello\") => ", result2.ok  # hello

# --- Failure ---
let err = RtError(kind: Timeout, msg: "connection timed out")
let eff3 = fail[int](err)
let result3 = run[int](eff3)
assert not result3.isOk
echo "fail(Timeout) => ", result3.err.kind, ": ", result3.err.msg

echo "\nAll ex01 checks passed."
