## ex08: Runner ACL — interpret vs run
##
## interpret[T] returns Eval[T] (4-valued: True/False/Both/Neither).
## run[T] returns Result[T] (2-valued: Ok/Err).
##
## The runner is the ACL (Anti-Corruption Layer) that collapses
## 4-valued evaluation to 2-valued result — the EXIT of the effects system.

import std/options
import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine
import rteffects/semantics

# --- interpret: see the 4-valued evaluation ---
echo "=== interpret (Eval[T]) ==="

let ev1 = interpret[int](pure[int](42))
echo "pure(42): truth=", ev1.truth, " value=", ev1.value  # tvTrue, some(42)

let ev2 = interpret[int](fail[int](RtError(kind: Timeout, msg: "t")))
echo "fail: truth=", ev2.truth, " error=", ev2.error.get.kind  # tvFalse, Timeout

# Unhandled effect produces tvFalse (not tvNeither)
let ev3 = interpret[int](perform[int](EffectTag("unhandled")))
echo "unhandled: truth=", ev3.truth  # tvFalse

# --- run: collapsed to Result[T] ---
echo "\n=== run (Result[T]) ==="

let r1 = run[int](pure[int](42))
echo "pure(42): isOk=", r1.isOk, " ok=", r1.ok  # true, 42

let r2 = run[int](fail[int](RtError(kind: Cancelled, msg: "c")))
echo "fail: isOk=", r2.isOk, " err=", r2.err.kind  # false, Cancelled

# --- Chain with handler, then run ---
echo "\n=== Full pipeline ==="

let tag = EffectTag("increment")
let eff = perform[int](tag, boxInt(10))
  .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))
  .handle(tag, proc(payload: BoxedValue,
      resume: proc(v: BoxedValue) {.gcsafe.},
      abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) + 1))
  )

# interpret sees full evaluation
let ev = interpret[int](eff)
echo "interpret: truth=", ev.truth, " value=", ev.value

# run collapses to Result
let r = run[int](eff)
echo "run: isOk=", r.isOk, " ok=", r.ok  # (10+1)*2 = 22

echo "\nAll ex08 checks passed."
