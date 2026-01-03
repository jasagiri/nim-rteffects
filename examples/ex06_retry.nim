## Example 06: Retry Pattern
##
## Shows how to retry failed operations with various strategies.

import std/times
import rteffects

var attemptCount = 0

proc unreliableOperation(): Task[string] =
  proc(rt: ptr Runtime, k: Cont[string]) =
    attemptCount.inc
    echo "Attempt #", attemptCount
    if attemptCount < 3:
      k(rt, err[string](foreignError("Network error")))
    else:
      k(rt, ok("Success on attempt " & $attemptCount))

# Example 1: Simple retry
echo "=== Example 1: Simple retry (max 5 attempts) ==="
attemptCount = 0
let result1 = runDefault(retry(unreliableOperation(), 5))
if result1.isOk:
  echo "Result: ", result1.ok
else:
  echo "Failed: ", result1.err.msg

# Example 2: Retry with delay between attempts
echo "\n=== Example 2: Retry with 100ms delay ==="
attemptCount = 0
let result2 = runDefault(retry(unreliableOperation(), 5, initDuration(milliseconds = 100)))
if result2.isOk:
  echo "Result: ", result2.ok
else:
  echo "Failed: ", result2.err.msg

# Example 3: Retry with exponential backoff
echo "\n=== Example 3: Exponential backoff ==="

var backoffAttempts = 0
proc backoffOperation(): Task[int] =
  proc(rt: ptr Runtime, k: Cont[int]) =
    backoffAttempts.inc
    echo "Backoff attempt #", backoffAttempts
    if backoffAttempts < 4:
      k(rt, err[int](foreignError("Service unavailable")))
    else:
      k(rt, ok(42))

let result3 = runDefault(retryWithBackoff(
  backoffOperation(),
  maxAttempts = 5,
  initialDelay = initDuration(milliseconds = 50),
  maxDelay = initDuration(milliseconds = 500)
))
if result3.isOk:
  echo "Result: ", result3.ok
else:
  echo "Failed after all retries: ", result3.err.msg

# Example 4: Retry that fails
echo "\n=== Example 4: Retry that exhausts all attempts ==="

proc alwaysFails(): Task[int] =
  proc(rt: ptr Runtime, k: Cont[int]) =
    echo "Always failing..."
    k(rt, err[int](foreignError("Permanent failure")))

let result4 = runDefault(retry(alwaysFails(), 3))
if result4.isOk:
  echo "Result: ", result4.ok
else:
  echo "Failed after 3 attempts: ", result4.err.msg
