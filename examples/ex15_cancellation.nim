## Example 15: Cancellation
##
## Demonstrates task cancellation and cooperative cancellation checking.

import std/[times, strformat]
import rteffects

# Example 1: Basic cancellation
echo "=== Example 1: Basic Cancellation ==="

proc longRunningTask(): Task[string] {.rt.} =
  echo "Long task: starting..."
  perform sleep(500.milliseconds)
  echo "Long task: completed (shouldn't see this)"
  return "completed"

proc cancelAfterDelay(): Task[string] =
  andThen(spawn(longRunningTask()), proc(taskId: TaskId): Task[string] {.gcsafe, closure.} =
    andThen(sleep(100.milliseconds), proc(_: Unit): Task[string] {.gcsafe, closure.} =
      echo "Cancelling the long task..."
      andThen(cancel(taskId), proc(_: Unit): Task[string] {.gcsafe, closure.} =
        andThen(joinResult[string](taskId), proc(result: Result[string]): Task[string] {.gcsafe, closure.} =
          if result.isOk:
            pure(result.ok)
          else:
            pure(fmt"Task was cancelled: {result.err.kind}")
        )
      )
    )
  )

let result1 = runDefault(cancelAfterDelay())
echo "Result: ", result1.ok

# Example 2: Cooperative cancellation with checkCancelled
echo "\n=== Example 2: Cooperative Cancellation ==="

proc cooperativeTask(): Task[int] {.rt.} =
  var count = 0
  while count < 100:
    # Check if we've been cancelled
    perform checkCancelled()

    count.inc
    if count mod 10 == 0:
      echo fmt"Progress: {count}%"
    perform sleep(10.milliseconds)

  return count

proc cancelCooperative(): Task[Result[int]] =
  andThen(spawn(cooperativeTask()), proc(taskId: TaskId): Task[Result[int]] {.gcsafe, closure.} =
    andThen(sleep(55.milliseconds), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
      echo "Requesting cancellation..."
      andThen(cancel(taskId), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
        joinResult[int](taskId)
      )
    )
  )

let result2 = runDefault(cancelCooperative())
if result2.isOk:
  if result2.ok.isOk:
    echo "Task completed: ", result2.ok.ok
  else:
    echo "Task cancelled at checkpoint"

# Example 3: Checking cancellation status
echo "\n=== Example 3: Checking Cancellation Status ==="

proc taskWithCancelCheck(): Task[string] {.rt.} =
  perform sleep(50.milliseconds)

  let cancelled = await isCancelled()
  if cancelled:
    return "Was cancelled"
  else:
    return "Not cancelled"

let result3a = runDefault(taskWithCancelCheck())
echo "Without cancellation: ", result3a.ok

# Example 4: Cancellation propagation to children
echo "\n=== Example 4: Cancellation Propagation ==="

proc childTask(id: int): Task[string] {.rt.} =
  echo fmt"Child {id}: starting"
  perform sleep(200.milliseconds)
  echo fmt"Child {id}: completed"
  return fmt"Child {id} result"

proc parentWithChildren(): Task[string] {.rt.} =
  echo "Parent: spawning children"
  let child1 = await spawn(childTask(1))
  let child2 = await spawn(childTask(2))

  echo "Parent: sleeping before join"
  perform sleep(300.milliseconds)

  let r1 = await join[string](child1)
  let r2 = await join[string](child2)
  return fmt"{r1}, {r2}"

proc cancelParent(): Task[Result[string]] =
  andThen(spawn(parentWithChildren()), proc(parentId: TaskId): Task[Result[string]] {.gcsafe, closure.} =
    andThen(sleep(100.milliseconds), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
      echo "Cancelling parent (should propagate to children)..."
      andThen(cancel(parentId), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
        andThen(sleep(50.milliseconds), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
          joinResult[string](parentId)
        )
      )
    )
  )

let result4 = runDefault(cancelParent())
if result4.isOk:
  if result4.ok.isOk:
    echo "Parent completed: ", result4.ok.ok
  else:
    echo "Parent cancelled: ", result4.ok.err.kind

# Example 5: Cancellation with cleanup
echo "\n=== Example 5: Cancellation with Cleanup ==="

var resourceCleaned = false

proc taskWithCleanup(): Task[string] =
  let work = andThen(sleep(200.milliseconds), proc(_: Unit): Task[string] {.gcsafe, closure.} =
    pure("work done")
  )

  ensure(work, proc(rt: ptr Runtime, k: Cont[Unit]) =
    resourceCleaned = true
    echo "Cleanup executed!"
    k(rt, ok(unit()))
  )

proc cancelWithCleanup(): Task[Result[string]] =
  resourceCleaned = false
  andThen(spawn(taskWithCleanup()), proc(taskId: TaskId): Task[Result[string]] {.gcsafe, closure.} =
    andThen(sleep(50.milliseconds), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
      echo "Cancelling task with cleanup..."
      andThen(cancel(taskId), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
        andThen(sleep(50.milliseconds), proc(_: Unit): Task[Result[string]] {.gcsafe, closure.} =
          joinResult[string](taskId)
        )
      )
    )
  )

let result5 = runDefault(cancelWithCleanup())
if result5.isOk:
  echo "Resource cleaned: ", resourceCleaned
