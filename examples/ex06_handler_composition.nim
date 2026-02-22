## ex06: Handler Composition
##
## Handlers compose by nesting. Inner handlers match first.
## When multiple handlers are installed for the same tag,
## the innermost one wins.

import rteffects/core
import rteffects/algebra
import rteffects/vm/types
import rteffects/vm/engine

proc main() =
  # --- Multiple handlers, innermost wins ---
  let tag = EffectTag("compute")

  let body = perform[int](tag, boxInt(10))

  # Inner handler: add 5
  let withInner = body.handle(tag, proc(payload: BoxedValue,
      resume: proc(v: BoxedValue) {.gcsafe.},
      abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) + 5))  # 10 + 5 = 15
  )

  let result1 = run[int](withInner)
  echo "single handler: 10 + 5 = ", result1.ok  # 15

  # Outer handler added (never reached because inner matches first)
  let withBoth = withInner.handle(tag, proc(payload: BoxedValue,
      resume: proc(v: BoxedValue) {.gcsafe.},
      abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(unboxInt(payload) * 100))  # would give 1000, but never called
  )

  let result2 = run[int](withBoth)
  echo "inner wins: 10 + 5 = ", result2.ok  # still 15

  # --- Handler wrapping a chain ---
  let chain = pure[int](3)
    .andThen(proc(x: int): Eff[int] {.gcsafe.} = pure[int](x * 2))  # 6

  let handledChain = chain.handle(tag, proc(payload: BoxedValue,
      resume: proc(v: BoxedValue) {.gcsafe.},
      abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
    resume(boxInt(99))  # handler exists but no perform in chain
  )

  let result3 = run[int](handledChain)
  echo "handler unused (no perform): 3 * 2 = ", result3.ok  # 6

  # --- Handler that aborts mid-computation ---
  let failTag = EffectTag("validate")
  let validated = perform[int](failTag, boxInt(-1))
    .handle(failTag, proc(payload: BoxedValue,
        resume: proc(v: BoxedValue) {.gcsafe.},
        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let n = unboxInt(payload)
      if n < 0:
        abort(RtError(kind: ForeignError, msg: "negative value: " & $n))
      else:
        resume(boxInt(n))
    )

  let result4 = run[int](validated)
  assert not result4.isOk
  echo "validation abort: ", result4.err.msg  # negative value: -1

  echo "\nAll ex06 checks passed."

main()
