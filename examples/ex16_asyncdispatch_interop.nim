## Example 16: AsyncDispatch Interoperability
##
## Shows how to integrate with Nim's asyncdispatch for I/O operations.

import std/[times, asyncdispatch]
import rteffects

# Example 1: Awaiting an asyncdispatch Future
echo "=== Example 1: Awaiting asyncdispatch Futures ==="

proc asyncOperation(): Future[string] {.async.} =
  echo "Async operation starting..."
  await sleepAsync(100)
  echo "Async operation completed"
  return "Hello from asyncdispatch!"

proc useAsyncFuture(): Task[string] {.rt.} =
  let fut = asyncOperation()
  return await awaitFuture(fut)

let result1 = runDefault(useAsyncFuture())
if result1.isOk:
  echo "Result: ", result1.ok
else:
  echo "Error: ", result1.err

# Example 2: Converting Task to Future
echo "\n=== Example 2: Converting Task to Future ==="

proc rteffectsTask(): Task[int] {.rt.} =
  perform sleep(50.milliseconds)
  return 42

# Run rteffects task from asyncdispatch context
proc asyncMain() {.async.} =
  echo "Async main starting..."

  # Convert Task to Future
  let fut = toFuture(rteffectsTask())

  echo "Waiting for rteffects task..."
  let result = await fut

  echo "Got result from rteffects: ", result

waitFor asyncMain()

# Example 3: Handling Future failures
echo "\n=== Example 3: Handling Future Failures ==="

proc failingAsyncOp(): Future[int] {.async.} =
  await sleepAsync(50)
  raise newException(ValueError, "Async operation failed!")

proc handleAsyncFailure(): Task[string] {.rt.} =
  let fut = failingAsyncOp()
  let result = await awaitFuture(fut)
  return "Got: " & $result

let result3 = runDefault(handleAsyncFailure())
if result3.isOk:
  echo "Success: ", result3.ok
else:
  echo "Caught error: ", result3.err.kind, " - ", result3.err.msg

# Example 4: Using AsyncEvent for I/O readiness
echo "\n=== Example 4: AsyncEvent for I/O ==="

proc waitForEvent(): Task[string] {.rt.} =
  let ev = newAsyncEvent()

  # Schedule the event to trigger after 100ms
  let timer = sleepAsync(100)
  timer.addCallback(proc() = trigger(ev))

  echo "Waiting for event..."
  perform awaitIO(ev)

  close(ev)
  return "Event received!"

let result4 = runDefault(waitForEvent())
if result4.isOk:
  echo "Result: ", result4.ok
else:
  echo "Error: ", result4.err

# Example 5: Timeout on async operations
echo "\n=== Example 5: Timeout on Async Operations ==="

proc slowAsyncOp(): Future[string] {.async.} =
  await sleepAsync(500)
  return "Slow result"

proc timedAsyncOp(): Task[string] {.rt.} =
  return await awaitFuture(slowAsyncOp())

let result5 = runDefault(withTimeout(100.milliseconds, timedAsyncOp()))
if result5.isOk:
  echo "Got result: ", result5.ok
else:
  echo "Timed out: ", result5.err.kind
