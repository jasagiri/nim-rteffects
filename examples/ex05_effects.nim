## ex05: Algebraic Effects — perform and handle
##
## perform requests an effect identified by a tag.
## handle installs a handler that interprets the effect.
## The handler receives the payload and resume/abort closures.

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

# --- Define effect tags ---
let doubleTag = EffectTag("double")
let greetTag = EffectTag("greet")

# --- perform + handle: double a number ---
let body1 = perform[int](doubleTag, boxInt(21))
let eff1 = body1.handle(doubleTag, proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  let n = unboxInt(payload)
  resume(boxInt(n * 2))
)
let result1 = run[int](eff1)
echo "double(21) = ", result1.ok  # 42

# --- Handler that aborts ---
let body2 = perform[int](greetTag, boxStr("world"))
let eff2 = body2.handle(greetTag, proc(payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
  abort(RtError(kind: ForeignError, msg: "greet not supported"))
)
let result2 = run[int](eff2)
assert not result2.isOk
echo "abort handler: ", result2.err.msg

# --- Unhandled effect ---
let eff3 = perform[int](EffectTag("missing"))
let result3 = run[int](eff3)
assert not result3.isOk
echo "unhandled: ", result3.err.msg  # "unhandled effect: missing"

echo "\nAll ex05 checks passed."
