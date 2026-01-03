## Example 04: Error Handling
##
## Demonstrates various error handling patterns.

import std/times
import rteffects

# Task that might fail
proc riskyOperation(shouldFail: bool): Task[int] {.rt.} =
  if shouldFail:
    raise newException(ValueError, "Operation failed!")
  return 42

# Task that returns an error
proc failingTask(): Task[int] {.rt.} =
  return await fail[int](foreignError("Something went wrong"))

# Example 1: Catching exceptions
proc example1(): Task[string] {.rt.} =
  let result = runDefault(riskyOperation(true))
  if result.isOk:
    return "Success: " & $result.ok
  else:
    return "Caught error: " & result.err.msg

# Example 2: Using recover
proc example2(): Task[int] =
  let task = fail[int](foreignError("initial error"))
  recover(task, proc(e: RtError): Task[int] {.gcsafe, closure.} =
    echo "Recovering from: ", e.msg
    pure(99)  # Return default value
  )

# Example 3: Using recoverWith for simple default
proc example3(): Task[int] =
  let task = fail[int](foreignError("error"))
  recoverWith(task, -1)  # Simply return -1 on error

# Example 4: Using catchError
proc example4(): Task[int] =
  let task = fail[int](foreignError("caught error"))
  catchError(task, proc(e: RtError): int {.gcsafe, closure.} =
    echo "Caught: ", e.msg
    0
  )

# Example 5: Error chaining
proc example5(): Task[Unit] {.rt.} =
  let innerError = foreignError("database connection failed")
  let outerError = foreignError("user lookup failed").withCause(innerError)

  echo "Error: ", outerError.msg
  echo "Root cause: ", rootCause(outerError).msg

  return unit()

echo "=== Example 1: Exception handling ==="
echo runDefault(example1()).ok

echo "\n=== Example 2: Using recover ==="
echo "Result: ", runDefault(example2()).ok

echo "\n=== Example 3: Using recoverWith ==="
echo "Result: ", runDefault(example3()).ok

echo "\n=== Example 4: Using catchError ==="
echo "Result: ", runDefault(example4()).ok

echo "\n=== Example 5: Error chaining ==="
discard runDefault(example5())
