## Example 02: Async Sleep
##
## Demonstrates how to use sleep and perform asynchronous operations.

import std/times
import rteffects

proc sleepyTask(): Task[string] {.rt.} =
  echo "Starting task..."

  # Sleep for 100 milliseconds
  perform sleep(100.milliseconds)

  echo "Woke up after 100ms"

  # Sleep again
  perform sleep(50.milliseconds)

  echo "Woke up after another 50ms"

  return "Done sleeping!"

# Measure execution time
let startTime = cpuTime()
let result = runDefault(sleepyTask())
let elapsed = cpuTime() - startTime

if result.isOk:
  echo result.ok
  echo "Total time: ", (elapsed * 1000).int, "ms"
else:
  echo "Error: ", result.err

# Output:
# Starting task...
# Woke up after 100ms
# Woke up after another 50ms
# Done sleeping!
# Total time: ~150ms
