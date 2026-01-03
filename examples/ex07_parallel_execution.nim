## Example 07: Parallel Execution
##
## Demonstrates running multiple tasks in parallel using all, race, and allSettled.

import std/[times, strformat]
import rteffects

proc fetchData(source: string, delay: int): Task[string] {.rt.} =
  echo fmt"Fetching from {source}..."
  perform sleep(delay.milliseconds)
  echo fmt"Got data from {source}"
  return fmt"Data from {source}"

proc fetchWithError(source: string): Task[string] {.rt.} =
  echo fmt"Fetching from {source}..."
  perform sleep(50.milliseconds)
  return await fail[string](foreignError(fmt"{source} unavailable"))

# Example 1: Using `all` - wait for all to complete
echo "=== Example 1: all() - Wait for all tasks ==="
proc fetchAll(): Task[seq[string]] =
  all(@[
    fetchData("API-A", 100),
    fetchData("API-B", 50),
    fetchData("API-C", 75)
  ])

let result1 = runDefault(fetchAll())
if result1.isOk:
  echo "All results:"
  for r in result1.ok:
    echo "  - ", r
else:
  echo "Error: ", result1.err.msg

# Example 2: Using `race` - first one wins
echo "\n=== Example 2: race() - First to complete wins ==="
proc raceApis(): Task[string] =
  race(@[
    fetchData("SlowAPI", 200),
    fetchData("FastAPI", 50),
    fetchData("MediumAPI", 100)
  ])

let result2 = runDefault(raceApis())
if result2.isOk:
  echo "Winner: ", result2.ok
else:
  echo "Error: ", result2.err.msg

# Example 3: Using `allSettled` - collect all results including failures
echo "\n=== Example 3: allSettled() - Collect all (including failures) ==="
proc fetchAllSettled(): Task[seq[Result[string]]] =
  allSettled(@[
    fetchData("GoodAPI-1", 50),
    fetchWithError("BadAPI"),
    fetchData("GoodAPI-2", 75)
  ])

let result3 = runDefault(fetchAllSettled())
if result3.isOk:
  echo "All settled results:"
  for i, r in result3.ok:
    if r.isOk:
      echo fmt"  [{i}] Success: {r.ok}"
    else:
      echo fmt"  [{i}] Failed: {r.err.msg}"

# Example 4: all() fails fast on first error
echo "\n=== Example 4: all() fails fast ==="
proc failFastDemo(): Task[seq[string]] =
  all(@[
    fetchData("SlowGood", 200),
    fetchWithError("FastBad"),
    fetchData("MediumGood", 100)
  ])

let result4 = runDefault(failFastDemo())
if result4.isOk:
  echo "Results: ", result4.ok
else:
  echo "Failed fast: ", result4.err.msg
