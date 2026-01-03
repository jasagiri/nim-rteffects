## Example 05: Timeout
##
## Shows how to add timeouts to tasks.

import std/times
import rteffects

proc slowOperation(): Task[string] {.rt.} =
  echo "Starting slow operation..."
  perform sleep(500.milliseconds)
  echo "Slow operation completed!"
  return "Slow result"

proc fastOperation(): Task[string] {.rt.} =
  echo "Starting fast operation..."
  perform sleep(50.milliseconds)
  echo "Fast operation completed!"
  return "Fast result"

# Example 1: Task completes before timeout
echo "=== Example 1: Fast task with timeout ==="
let result1 = runDefault(withTimeout(200.milliseconds, fastOperation()))
if result1.isOk:
  echo "Result: ", result1.ok
else:
  echo "Timed out or error: ", result1.err.kind

# Example 2: Task times out
echo "\n=== Example 2: Slow task with timeout ==="
let result2 = runDefault(withTimeout(100.milliseconds, slowOperation()))
if result2.isOk:
  echo "Result: ", result2.ok
else:
  echo "Timed out: ", result2.err.kind

# Example 3: Timeout with fallback value
echo "\n=== Example 3: Timeout with fallback ==="
proc withFallback(): Task[string] =
  let task = withTimeout(100.milliseconds, slowOperation())
  recoverWith(task, "Fallback value (timed out)")

let result3 = runDefault(withFallback())
echo "Result: ", result3.ok

# Output:
# === Example 1: Fast task with timeout ===
# Starting fast operation...
# Fast operation completed!
# Result: Fast result
#
# === Example 2: Slow task with timeout ===
# Starting slow operation...
# Timed out: Timeout
#
# === Example 3: Timeout with fallback ===
# Starting slow operation...
# Result: Fallback value (timed out)
