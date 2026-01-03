# RTEffects Patterns and Best Practices

## Structured Concurrency

### Basic Nursery Pattern

Use nurseries to ensure all spawned tasks complete before continuing:

```nim
proc fetchAllData(): Task[Unit] =
  nursery(proc(n: Nursery): Task[Unit] {.gcsafe, closure.} =
    andThen(spawnChild(n, fetchUsers()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, fetchProducts()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, fetchOrders()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          pure(unit())
        )
      )
    )
  )
```

### Collecting Results from Children

Use `TypedNursery` to collect results:

```nim
proc fetchAllPrices(productIds: seq[int]): Task[seq[float]] =
  typedNursery[float](proc(n: TypedNursery[float]): Task[Unit] {.gcsafe, closure.} =
    forEachTask(productIds, proc(id: int): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, fetchPrice(id)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        pure(unit())
      )
    )
  )
```

### Error Handling Policies

```nim
# Fail fast - cancel all on first error
let n = newNursery(npFailFast)

# Collect all - run all, then aggregate errors
let n = newNursery(npCollectAll)

# Supervise - errors recorded but parent succeeds
let n = newNursery(npSupervise)
```

---

## Error Handling Patterns

### Recover with Fallback

```nim
proc fetchWithFallback(): Task[Data] =
  let primary = fetchFromPrimary()
  recover(primary, proc(e: RtError): Task[Data] {.gcsafe, closure.} =
    echo "Primary failed: ", e.msg
    fetchFromBackup()
  )
```

### Retry with Exponential Backoff

```nim
proc reliableFetch(): Task[string] =
  retryWithBackoff(
    fetchFromApi(),
    maxAttempts = 5,
    initialDelay = initDuration(milliseconds = 100),
    maxDelay = initDuration(seconds = 5)
  )
```

### Circuit Breaker Pattern

```nim
type CircuitBreaker = ref object
  failures: int
  lastFailure: float
  threshold: int
  resetTime: float

proc withCircuitBreaker[T](cb: CircuitBreaker, task: Task[T]): Task[T] =
  if cb.failures >= cb.threshold:
    if cpuTime() - cb.lastFailure < cb.resetTime:
      return fail[T](foreignError("Circuit breaker open"))
    cb.failures = 0  # Reset

  recover(task, proc(e: RtError): Task[T] {.gcsafe, closure.} =
    cb.failures.inc
    cb.lastFailure = cpuTime()
    fail[T](e)
  )
```

---

## Resource Management

### Database Connection Pattern

```nim
proc withConnection[T](use: proc(conn: Connection): Task[T]): Task[T] =
  bracket(
    openConnection(),
    use,
    closeConnection
  )

# Usage
proc queryUser(id: int): Task[User] =
  withConnection(proc(conn: Connection): Task[User] {.gcsafe, closure.} =
    query(conn, "SELECT * FROM users WHERE id = ?", id)
  )
```

### Connection Pool

```nim
type Pool = ref object
  sem: Semaphore
  connections: seq[Connection]

proc withPooledConnection[T](pool: Pool,
                             use: proc(conn: Connection): Task[T]): Task[T] =
  withSemaphore(pool.sem,
    bracket(
      acquireFromPool(pool),
      use,
      releaseToPool(pool)
    )
  )
```

---

## Concurrency Patterns

### Worker Pool

```nim
proc workerPool[T, R](workers: int, jobs: seq[T],
                      process: proc(t: T): Task[R]): Task[seq[R]] =
  let sem = newSemaphore(workers)
  mapTask(jobs, proc(job: T): Task[R] {.gcsafe, closure.} =
    withSemaphore(sem, process(job))
  )
```

### Fan-Out / Fan-In

```nim
proc fanOutFanIn[T, R](items: seq[T],
                       transform: proc(t: T): Task[R]): Task[seq[R]] =
  all(items.mapIt(transform(it)))
```

### Pipeline

```nim
proc pipeline[A, B, C](input: A,
                       stage1: proc(a: A): Task[B],
                       stage2: proc(b: B): Task[C]): Task[C] =
  andThen(stage1(input), stage2)
```

---

## Rate Limiting

### Token Bucket

```nim
proc rateLimited[T](limiter: RateLimiter, task: Task[T]): Task[T] =
  andThen(waitForToken(limiter), proc(_: Unit): Task[T] {.gcsafe, closure.} =
    task
  )
```

### Batching Requests

```nim
proc batchRequests[T](items: seq[T], batchSize: int,
                      process: proc(batch: seq[T]): Task[Unit]): Task[Unit] =
  var batches: seq[seq[T]] = @[]
  var current: seq[T] = @[]

  for item in items:
    current.add(item)
    if current.len >= batchSize:
      batches.add(current)
      current = @[]
  if current.len > 0:
    batches.add(current)

  forEachTask(batches, process)
```

---

## Channel Patterns

### Producer-Consumer

```nim
proc producerConsumer(): Task[Unit] =
  let ch = newTaskChannel[int](10)  # Bounded buffer

  andThen(spawn(producer(ch)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
    consumer(ch)
  )
```

### Fan-In (Multiple Producers)

```nim
proc fanIn(sources: seq[DataSource]): Task[seq[Data]] =
  let ch = newTaskChannel[Data]()

  # Spawn all producers
  andThen(all(sources.mapIt(spawn(produce(it, ch)))), proc(_: seq[TaskId]): Task[seq[Data]] {.gcsafe, closure.} =
    collectFromChannel(ch, sources.len)
  )
```

### Pub-Sub

```nim
type Topic[T] = ref object
  subscribers: seq[TaskChannel[T]]

proc subscribe[T](topic: Topic[T]): TaskChannel[T] =
  let ch = newTaskChannel[T]()
  topic.subscribers.add(ch)
  ch

proc publish[T](topic: Topic[T], value: T): Task[Unit] =
  all(topic.subscribers.mapIt(send(it, value)))
  andThen(all(topic.subscribers.mapIt(send(it, value))), proc(_: seq[Unit]): Task[Unit] {.gcsafe, closure.} =
    pure(unit())
  )
```

---

## Testing Patterns

### Mocking Tasks

```nim
proc mockFetch(): Task[string] =
  pure("mock data")

# Use dependency injection
proc processData(fetch: proc(): Task[string]): Task[string] =
  andThen(fetch(), transform)

# In tests
let result = runDefault(processData(mockFetch))
```

### Testing with Trace

```nim
proc testWithTrace() =
  proc myTask(): Task[Unit] {.rt.} =
    perform trace("step 1")
    perform sleep(10.milliseconds)
    perform trace("step 2")
    return unit()

  let traced = runDefaultWithTrace(myTask())
  assert traced.trace == @["step 1", "step 2"]
```

---

## Performance Tips

### Avoid Unnecessary Task Creation

```nim
# Bad - creates task for simple value
proc getValue(): Task[int] =
  pure(42)

# Good - only use tasks for async operations
let value = 42
```

### Use Parallel Operations

```nim
# Bad - sequential
for item in items:
  discard runDefault(process(item))

# Good - parallel
discard runDefault(all(items.mapIt(process(it))))
```

### Limit Concurrency

```nim
# Use semaphore to limit concurrent operations
let sem = newSemaphore(10)  # Max 10 concurrent
mapTask(items, proc(item: T): Task[R] {.gcsafe, closure.} =
  withSemaphore(sem, process(item))
)
```

---

## Common Pitfalls

### Forgetting GC-Safety

Always mark closures with `{.gcsafe, closure.}`:

```nim
# Wrong
andThen(task, proc(v: int): Task[int] =
  pure(v * 2)
)

# Correct
andThen(task, proc(v: int): Task[int] {.gcsafe, closure.} =
  pure(v * 2)
)
```

### Blocking the Runtime

Don't use blocking operations inside tasks:

```nim
# Wrong - blocks the runtime
proc badTask(): Task[string] {.rt.} =
  sleep(1000)  # stdlib sleep, not rteffects
  return "done"

# Correct
proc goodTask(): Task[string] {.rt.} =
  perform sleep(1.seconds)
  return "done"
```

### Not Handling Errors

Always handle potential errors:

```nim
# Better
let result = runDefault(task)
if result.isOk:
  processSuccess(result.ok)
else:
  handleError(result.err)
```
