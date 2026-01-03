## Example 08: Nursery (Structured Concurrency)
##
## Shows how to use nurseries for structured concurrency patterns.

import std/[times, strformat, sequtils]
import rteffects

proc worker(id: int, workTime: int): Task[Unit] {.rt.} =
  echo fmt"Worker {id} starting (will take {workTime}ms)"
  perform sleep(workTime.milliseconds)
  echo fmt"Worker {id} completed"
  return unit()

proc failingWorker(id: int): Task[Unit] {.rt.} =
  echo fmt"Worker {id} starting (will fail)"
  perform sleep(50.milliseconds)
  return await fail[Unit](foreignError(fmt"Worker {id} failed"))

# Example 1: FailFast policy - cancel all on first failure
echo "=== Example 1: FailFast Policy ==="
proc failFastDemo(): Task[Unit] =
  let n = newNursery(npFailFast)
  andThen(spawnChild(n, worker(1, 200)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
    andThen(spawnChild(n, failingWorker(2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, worker(3, 150)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        joinAll(n)
      )
    )
  )

let result1 = runDefault(failFastDemo())
if result1.isOk:
  echo "All completed successfully"
else:
  echo "Nursery failed: ", result1.err.msg

# Example 2: CollectAll policy - run all, then report errors
echo "\n=== Example 2: CollectAll Policy ==="
proc collectAllDemo(): Task[Unit] =
  let n = newNursery(npCollectAll)
  andThen(spawnChild(n, worker(1, 100)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
    andThen(spawnChild(n, failingWorker(2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, failingWorker(3)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        joinAll(n)
      )
    )
  )

let result2 = runDefault(collectAllDemo())
if result2.isOk:
  echo "All completed"
else:
  echo "Errors collected: ", result2.err.msg

# Example 3: Supervise policy - errors recorded but don't fail parent
echo "\n=== Example 3: Supervise Policy ==="
proc superviseDemo(): Task[seq[RtError]] =
  let n = newNursery(npSupervise)
  andThen(spawnChild(n, worker(1, 50)), proc(_: TaskId): Task[seq[RtError]] {.gcsafe, closure.} =
    andThen(spawnChild(n, failingWorker(2)), proc(_: TaskId): Task[seq[RtError]] {.gcsafe, closure.} =
      andThen(spawnChild(n, worker(3, 75)), proc(_: TaskId): Task[seq[RtError]] {.gcsafe, closure.} =
        andThen(joinAll(n), proc(_: Unit): Task[seq[RtError]] {.gcsafe, closure.} =
          pure(n.errors)
        )
      )
    )
  )

let result3 = runDefault(superviseDemo())
if result3.isOk:
  echo "Nursery succeeded"
  echo "Recorded errors: ", result3.ok.len
  for e in result3.ok:
    echo "  - ", e.msg

# Example 4: TypedNursery - collect results from children
echo "\n=== Example 4: TypedNursery - Collecting Results ==="
proc typedWorker(id: int, value: int): Task[int] {.rt.} =
  perform sleep(50.milliseconds)
  return value * id

proc typedNurseryDemo(): Task[seq[int]] =
  typedNursery[int](proc(n: TypedNursery[int]): Task[Unit] {.gcsafe, closure.} =
    andThen(spawnChild(n, typedWorker(1, 10)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, typedWorker(2, 10)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, typedWorker(3, 10)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          pure(unit())
        )
      )
    )
  )

let result4 = runDefault(typedNurseryDemo())
if result4.isOk:
  echo "Results: ", result4.ok
  echo "Sum: ", result4.ok.foldl(a + b, 0)
