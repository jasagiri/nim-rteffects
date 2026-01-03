## Example 03: Spawn and Join
##
## Shows how to spawn child tasks and wait for their results.

import std/times
import rteffects

proc worker(id: int, workTime: int): Task[string] {.rt.} =
  echo "Worker ", id, " starting..."
  perform sleep(workTime.milliseconds)
  echo "Worker ", id, " finished!"
  return "Result from worker " & $id

proc coordinator(): Task[seq[string]] {.rt.} =
  var results: seq[string] = @[]

  # Spawn three workers
  let id1 = await spawn(worker(1, 100))
  let id2 = await spawn(worker(2, 50))
  let id3 = await spawn(worker(3, 75))

  echo "All workers spawned, waiting for results..."

  # Join all workers and collect results
  results.add(await join[string](id1))
  results.add(await join[string](id2))
  results.add(await join[string](id3))

  return results

let result = runDefault(coordinator())

if result.isOk:
  echo "\nAll results:"
  for r in result.ok:
    echo "  - ", r
else:
  echo "Error: ", result.err

# Output:
# Worker 1 starting...
# Worker 2 starting...
# Worker 3 starting...
# All workers spawned, waiting for results...
# Worker 2 finished!
# Worker 3 finished!
# Worker 1 finished!
#
# All results:
#   - Result from worker 1
#   - Result from worker 2
#   - Result from worker 3
