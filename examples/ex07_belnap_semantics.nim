## ex07: Belnap 4-Valued Semantics
##
## TruthValue has four values forming a De Morgan bilattice:
##   tvTrue    — computation succeeded
##   tvFalse   — computation failed
##   tvBoth    — contradictory (both success and failure)
##   tvNeither — undetermined (neither success nor failure)
##
## Lattice operations: join (LUB), meet (GLB), negate.

import std/options
import rteffects/core
import rteffects/semantics

# --- TruthValue lattice ---
echo "=== Lattice Operations ==="
echo "join(tvTrue, tvFalse) = ", join(tvTrue, tvFalse)    # tvBoth
echo "join(tvTrue, tvNeither) = ", join(tvTrue, tvNeither)  # tvTrue
echo "meet(tvTrue, tvFalse) = ", meet(tvTrue, tvFalse)    # tvNeither
echo "negate(tvTrue) = ", negate(tvTrue)                    # tvFalse
echo "negate(tvBoth) = ", negate(tvBoth)                    # tvBoth

# --- Information ordering ---
echo "\n=== Information Ordering (leqI) ==="
echo "tvNeither <=i tvTrue: ", leqI(tvNeither, tvTrue)    # true (N is bottom)
echo "tvTrue <=i tvBoth: ", leqI(tvTrue, tvBoth)          # true (B is top)
echo "tvTrue <=i tvFalse: ", leqI(tvTrue, tvFalse)        # false (incomparable)

# --- Eval[T] construction ---
echo "\n=== Eval[T] ==="
let evT = evalTrue[int](42)
echo "evalTrue(42): truth=", evT.truth, " value=", evT.value

let evF = evalFalse[int](RtError(kind: Timeout, msg: "t"))
echo "evalFalse: truth=", evF.truth, " error=", evF.error.get.kind

let evB = evalBoth[int](42, RtError(kind: Cancelled, msg: "c"))
echo "evalBoth: truth=", evB.truth, " value=", evB.value, " error=", evB.error.get.kind

let evN = evalNeither[int]()
echo "evalNeither: truth=", evN.truth

# --- Eval map and flatMap ---
echo "\n=== Eval Operations ==="
let mapped = evT.map(proc(x: int): string = "value=" & $x)
echo "evalTrue(42).map(toStr) = ", mapped.value

let chained = evT.flatMap(proc(x: int): Eval[int] = evalTrue(x * 2))
echo "evalTrue(42).flatMap(*2) = ", chained.value

# --- ACL collapse ---
echo "\n=== ACL Collapse (4-value -> 2-value) ==="
echo "evalTrue(42).toResult => isOk=", toResult(evT).isOk
echo "evalFalse.toResult => err=", toResult(evF).err.kind
echo "evalBoth.toResult => err=", toResult(evB).err.kind      # Contradiction
echo "evalNeither.toResult => err=", toResult(evN).err.kind    # Incomplete

echo "\nAll ex07 checks passed."
