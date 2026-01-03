# RTEffects API Reference

## Core Types

### Task[T]

```nim
type Task*[T] = proc(rt: ptr Runtime, k: Cont[T])
```

Represents an asynchronous computation that produces a value of type `T`.

### Result[T]

```nim
type Result*[T] = object
  isOk*: bool
  ok*: T
  err*: RtError
```

Represents either a successful value or an error.

### RtError

```nim
type RtError* = object
  kind*: RtErrorKind
  msg*: string
  cause*: ref RtError       # Optional cause for error chaining
  stackTrace*: string       # Optional stack trace
  children*: seq[RtError]   # For AggregateError
```

### RtErrorKind

```nim
type RtErrorKind* = enum
  Timeout,
  Cancelled,
  ExceptionRaised,
  ForeignError,
  AggregateError
```

### TaskId / TypedTaskId[T]

```nim
type TaskId* = distinct int
type TypedTaskId*[T] = object
  id*: TaskId
```

Handle for referencing spawned tasks.

### Unit

```nim
type Unit* = object
```

Represents void/no value. Use `unit()` to create.

---

## Running Tasks

### runDefault

```nim
proc runDefault*[T](t: Task[T]): Result[T]
```

Runs a task to completion and returns its result.

### runDefaultWithTrace

```nim
proc runDefaultWithTrace*[T](t: Task[T], hook: TraceHook = nil): TracedResult[T]
```

Runs a task with tracing support.

### start

```nim
proc start*[T](t: Task[T]): TaskId
```

Starts a task and returns its ID. Creates a new runtime.

---

## Creating Tasks

### pure

```nim
proc pure*[T](v: T): Task[T]
```

Creates a task that immediately returns the given value.

### fail

```nim
proc fail*[T](e: RtError): Task[T]
```

Creates a task that immediately fails with the given error.

### .rt. macro

```nim
proc myTask(): Task[T] {.rt.} =
  # Use await, perform, return inside
```

Transforms a proc into a CPS-style task.

---

## Task Operations

### spawn / spawnTyped

```nim
proc spawn*[T](t: Task[T]): Task[TaskId]
proc spawnTyped*[T](t: Task[T]): Task[TypedTaskId[T]]
```

Spawns a child task and returns its ID.

### join / joinTyped

```nim
proc join*[T](id: TaskId): Task[T]
proc joinTyped*[T](id: TypedTaskId[T]): Task[T]
```

Waits for a task to complete and returns its result.

### joinResult / joinTypedResult

```nim
proc joinResult*[T](id: TaskId): Task[Result[T]]
proc joinTypedResult*[T](id: TypedTaskId[T]): Task[Result[T]]
```

Waits for a task and returns its result wrapped in Result.

### cancel / cancelTyped

```nim
proc cancel*(id: TaskId): Task[Unit]
proc cancelTyped*[T](id: TypedTaskId[T]): Task[Unit]
```

Cancels a running task.

### isCancelled

```nim
proc isCancelled*(): Task[bool]
```

Checks if the current task has been cancelled.

### checkCancelled

```nim
proc checkCancelled*(): Task[Unit]
```

Checks if cancelled and returns error if so.

---

## Combinators

### andThen / flatMap

```nim
proc andThen*[T, U](t: Task[T], f: proc(v: T): Task[U]): Task[U]
proc flatMap*[T, U](t: Task[T], f: proc(v: T): Task[U]): Task[U]
```

Chains tasks. If `t` succeeds, calls `f` with the result.

### map

```nim
proc map*[T, U](t: Task[T], f: proc(v: T): U): Task[U]
```

Transforms a successful result.

### recover

```nim
proc recover*[T](t: Task[T], f: proc(e: RtError): Task[T]): Task[T]
```

Recovers from errors by providing an alternative task.

### recoverWith

```nim
proc recoverWith*[T](t: Task[T], default: T): Task[T]
```

Recovers with a default value.

### catchError

```nim
proc catchError*[T](t: Task[T], f: proc(e: RtError): T): Task[T]
```

Catches errors and provides a fallback value.

### ensure

```nim
proc ensure*[T](t: Task[T], finalizer: Task[Unit]): Task[T]
```

Always runs finalizer, whether success or failure.

---

## Parallel Execution

### all

```nim
proc all*[T](tasks: seq[Task[T]]): Task[seq[T]]
```

Runs all tasks in parallel, fails fast on first error.

### allSettled

```nim
proc allSettled*[T](tasks: seq[Task[T]]): Task[seq[Result[T]]]
```

Runs all tasks, collects all results including failures.

### race / any

```nim
proc race*[T](tasks: seq[Task[T]]): Task[T]
proc any*[T](tasks: seq[Task[T]]): Task[T]
```

Returns the first task to complete, cancels others.

---

## Retry

### retry

```nim
proc retry*[T](t: Task[T], maxAttempts: int, delay = Duration.default): Task[T]
```

Retries a task up to `maxAttempts` times.

### retryWithBackoff

```nim
proc retryWithBackoff*[T](t: Task[T], maxAttempts: int,
                          initialDelay: Duration,
                          maxDelay = initDuration(seconds = 60)): Task[T]
```

Retries with exponential backoff.

---

## Timing

### sleep

```nim
proc sleep*(d: Duration): Task[Unit]
proc sleep*(interval: TimeInterval): Task[Unit]
```

Suspends the task for the given duration.

### withTimeout

```nim
proc withTimeout*[T](timeout: Duration, task: Task[T]): Task[T]
proc withTimeout*[T](timeout: TimeInterval, task: Task[T]): Task[T]
```

Adds a timeout to a task. Returns `Timeout` error if exceeded.

### yieldNow

```nim
proc yieldNow*(): Task[Unit]
```

Yields control to other tasks.

---

## Iteration

### forEachTask

```nim
proc forEachTask*[T](items: seq[T], body: proc(item: T): Task[Unit]): Task[Unit]
```

Iterates sequentially over items.

### forEachParallel

```nim
proc forEachParallel*[T](items: seq[T], body: proc(item: T): Task[Unit]): Task[Unit]
```

Iterates in parallel over items.

### mapTask

```nim
proc mapTask*[T, U](items: seq[T], f: proc(item: T): Task[U]): Task[seq[U]]
```

Maps items in parallel.

### filterTask

```nim
proc filterTask*[T](items: seq[T], pred: proc(item: T): Task[bool]): Task[seq[T]]
```

Filters items sequentially.

### whileTask

```nim
proc whileTask*(cond: proc(): bool, body: Task[Unit]): Task[Unit]
```

Loops while condition is true.

---

## Resource Management

### bracket

```nim
proc bracket*[R, T](acquire: Task[R],
                    use: proc(r: R): Task[T],
                    release: proc(r: R): Task[Unit]): Task[T]
```

Safe resource management. Release is always called.

### bracketOnError

```nim
proc bracketOnError*[R, T](acquire: Task[R],
                           use: proc(r: R): Task[T],
                           release: proc(r: R): Task[Unit]): Task[T]
```

Release only called on error.

---

## Channels

### TaskChannel[T]

```nim
proc newTaskChannel*[T](capacity = 0): TaskChannel[T]
```

Creates a channel. `capacity = 0` means unbounded.

### send

```nim
proc send*[T](ch: TaskChannel[T], value: T): Task[Unit]
```

Sends a value. Blocks if channel is full.

### recv

```nim
proc recv*[T](ch: TaskChannel[T]): Task[T]
```

Receives a value. Blocks if channel is empty.

### tryRecv

```nim
proc tryRecv*[T](ch: TaskChannel[T]): Task[Result[T]]
```

Non-blocking receive.

### closeChannel

```nim
proc closeChannel*[T](ch: TaskChannel[T]): Task[Unit]
```

Closes the channel.

### isClosed

```nim
proc isClosed*[T](ch: TaskChannel[T]): bool
```

Checks if channel is closed.

---

## Semaphore

```nim
proc newSemaphore*(permits: int): Semaphore
proc acquire*(s: Semaphore): Task[Unit]
proc release*(s: Semaphore): Task[Unit]
proc tryAcquire*(s: Semaphore): Task[bool]
proc withSemaphore*[T](s: Semaphore, t: Task[T]): Task[T]
```

---

## Mutex

```nim
proc newMutex*(): Mutex
proc lock*(m: Mutex): Task[Unit]
proc unlock*(m: Mutex): Task[Unit]
proc tryLock*(m: Mutex): Task[bool]
proc withMutex*[T](m: Mutex, t: Task[T]): Task[T]
```

---

## Nursery (Structured Concurrency)

### NurseryPolicy

```nim
type NurseryPolicy* = enum
  npFailFast,    # Cancel all on first failure
  npCollectAll,  # Run all, aggregate errors
  npSupervise    # Run all, record errors but succeed
```

### Nursery

```nim
proc newNursery*(policy = npFailFast): Nursery
proc spawnChild*(n: Nursery, t: Task[Unit]): Task[TaskId]
proc joinAll*(n: Nursery): Task[Unit]
proc errors*(n: Nursery): seq[RtError]
```

### TypedNursery[T]

```nim
proc newTypedNursery*[T](policy = npFailFast): TypedNursery[T]
proc spawnChild*[T](n: TypedNursery[T], t: Task[T]): Task[TaskId]
proc joinAll*[T](n: TypedNursery[T]): Task[Unit]
proc joinAllValues*[T](n: TypedNursery[T]): Task[seq[T]]
proc joinAllResults*[T](n: TypedNursery[T]): Task[seq[Result[T]]]
proc results*[T](n: TypedNursery[T]): seq[Result[T]]
proc successResults*[T](n: TypedNursery[T]): seq[T]
proc errors*[T](n: TypedNursery[T]): seq[RtError]
```

### Nursery Scopes

```nim
proc nursery*(body: proc(n: Nursery): Task[Unit], policy = npFailFast): Task[Unit]
proc typedNursery*[T](body: proc(n: TypedNursery[T]): Task[Unit],
                      policy = npFailFast): Task[seq[T]]
proc typedNurseryAll*[T](body: proc(n: TypedNursery[T]): Task[Unit],
                         policy = npFailFast): Task[seq[Result[T]]]
```

---

## AsyncDispatch Interop

### awaitFuture

```nim
proc awaitFuture*[T](fut: Future[T]): Task[T]
```

Awaits an asyncdispatch Future.

### toFuture

```nim
proc toFuture*[T](t: Task[T]): Future[T]
```

Converts a Task to a Future.

### awaitIO

```nim
proc awaitIO*(ev: AsyncEvent): Task[Unit]
proc awaitIO*(fd: AsyncFD, interest: IoInterest): Task[Unit]
```

Waits for I/O readiness.

---

## Tracing

### trace

```nim
proc trace*(msg: string): Task[Unit]
```

Emits a trace message.

---

## Error Constructors

```nim
proc cancelledError*(): RtError
proc timeoutError*(): RtError
proc exceptionError*(msg: string): RtError
proc exceptionError*(ex: ref Exception): RtError
proc foreignError*(msg: string): RtError
proc aggregateError*(errors: seq[RtError]): RtError
```

### Error Chaining

```nim
proc withCause*(e: RtError, cause: RtError): RtError
proc rootCause*(e: RtError): RtError
```
