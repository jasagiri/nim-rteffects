## Example 10: Synchronization Primitives
##
## Demonstrates Semaphore and Mutex usage for coordination.

import std/[times, strformat]
import rteffects

# Example 1: Semaphore for limiting concurrency
echo "=== Example 1: Semaphore - Limit Concurrent Access ==="

proc limitedWorker(sem: Semaphore, id: int): Task[Unit] =
  echo fmt"Worker {id}: waiting for semaphore"
  andThen(acquire(sem), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
    echo fmt"Worker {id}: acquired semaphore, working..."
    andThen(sleep(100.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
      echo fmt"Worker {id}: done, releasing"
      release(sem)
    )
  )

proc semaphoreExample(): Task[Unit] =
  # Allow only 2 concurrent workers
  let sem = newSemaphore(2)

  # Spawn 5 workers
  andThen(spawn(limitedWorker(sem, 1)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
    andThen(spawn(limitedWorker(sem, 2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawn(limitedWorker(sem, 3)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawn(limitedWorker(sem, 4)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          andThen(spawn(limitedWorker(sem, 5)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
            # Wait for all to complete
            sleep(600.milliseconds)
          )
        )
      )
    )
  )

discard runDefault(semaphoreExample())

# Example 2: Mutex for exclusive access
echo "\n=== Example 2: Mutex - Exclusive Access ==="

var sharedCounter = 0

proc incrementer(m: Mutex, id: int, times: int): Task[Unit] =
  proc loop(i: int): Task[Unit] =
    if i >= times:
      pure(unit())
    else:
      andThen(lock(m), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        let old = sharedCounter
        # Simulate some work
        andThen(yieldNow(), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          sharedCounter = old + 1
          echo fmt"Worker {id}: {old} -> {sharedCounter}"
          andThen(unlock(m), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
            loop(i + 1)
          )
        )
      )
  loop(0)

proc mutexExample(): Task[int] =
  sharedCounter = 0
  let m = newMutex()

  andThen(spawn(incrementer(m, 1, 3)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
    andThen(spawn(incrementer(m, 2, 3)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
      andThen(sleep(200.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        pure(sharedCounter)
      )
    )
  )

let result2 = runDefault(mutexExample())
echo "Final counter value: ", result2.ok

# Example 3: Using withSemaphore helper
echo "\n=== Example 3: withSemaphore Helper ==="

proc semaphoreHelperExample(): Task[int] =
  let sem = newSemaphore(1)

  proc protectedWork(id: int): Task[int] =
    withSemaphore(sem,
      andThen(sleep(50.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        echo fmt"Protected work {id} completed"
        pure(id)
      )
    )

  andThen(spawn(protectedWork(1)), proc(id1: TaskId): Task[int] {.gcsafe, closure.} =
    andThen(spawn(protectedWork(2)), proc(id2: TaskId): Task[int] {.gcsafe, closure.} =
      andThen(join[int](id1), proc(r1: int): Task[int] {.gcsafe, closure.} =
        andThen(join[int](id2), proc(r2: int): Task[int] {.gcsafe, closure.} =
          pure(r1 + r2)
        )
      )
    )
  )

let result3 = runDefault(semaphoreHelperExample())
echo "Sum of results: ", result3.ok

# Example 4: tryAcquire for non-blocking check
echo "\n=== Example 4: Non-blocking tryAcquire ==="

proc tryAcquireExample(): Task[string] =
  let sem = newSemaphore(1)

  # First acquire
  andThen(acquire(sem), proc(_: Unit): Task[string] {.gcsafe, closure.} =
    echo "First acquire succeeded"

    # Try to acquire again (non-blocking)
    andThen(tryAcquire(sem), proc(got: bool): Task[string] {.gcsafe, closure.} =
      if got:
        echo "Second acquire succeeded (unexpected)"
        pure("both acquired")
      else:
        echo "Second acquire failed (expected - semaphore busy)"
        andThen(release(sem), proc(_: Unit): Task[string] {.gcsafe, closure.} =
          pure("correctly handled busy semaphore")
        )
    )
  )

let result4 = runDefault(tryAcquireExample())
echo "Result: ", result4.ok
