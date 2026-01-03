## Example 01: Hello World
##
## This is the simplest example showing how to create and run a task.

import std/times
import rteffects

# Define a simple task using the .rt. macro
proc helloTask(): Task[string] {.rt.} =
  return "Hello, RTEffects!"

# Run the task and get the result
let result = runDefault(helloTask())

if result.isOk:
  echo result.ok
else:
  echo "Error: ", result.err

# Output: Hello, RTEffects!
