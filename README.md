# RTEffects

A CPS (Continuation-Passing Style) based runtime effects library for Nim, providing structured concurrency, async operations, and powerful error handling.

## Requirements

- Nim >= 2.3.0

## Installation

Add to your `.nimble` file:

```nim
requires "rteffects"
```

Or install directly:

```bash
nimble install rteffects
```

## Quick Start

```nim
import std/times
import rteffects

# Define a task using the .rt. macro
proc fetchData(): Task[string] {.rt.} =
  perform sleep(100.milliseconds)
  return "Hello, RTEffects!"

# Run the task
let result = runDefault(fetchData())
if result.isOk:
  echo result.ok  # "Hello, RTEffects!"
else:
  echo "Error: ", result.err.msg
```

## Core Concepts

### Tasks

A `Task[T]` represents an asynchronous computation that produces a value of type `T`. Tasks are lazy - they don't execute until run.

### The .rt. Macro

The `.rt.` pragma transforms a proc into a CPS-style task. Inside `.rt.` procs:

- `await` - Wait for another task and get its result
- `perform` - Execute an effect (like `sleep`)
- `return` - Return a value

```nim
proc myTask(): Task[int] {.rt.} =
  let data = await fetchFromNetwork()
  perform sleep(100.milliseconds)
  return data.len
```

### Structured Concurrency with Nurseries

Nurseries ensure all child tasks complete before the parent continues:

```nim
proc parent(): Task[Unit] =
  nursery(proc(n: Nursery): Task[Unit] {.gcsafe, closure.} =
    andThen(spawnChild(n, childTask1()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
      andThen(spawnChild(n, childTask2()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        pure(unit())
      )
    )
  )
```

### Error Handling

```nim
proc withRecovery(): Task[string] =
  let task = riskyOperation()
  recover(task, proc(e: RtError): Task[string] {.gcsafe, closure.} =
    pure("fallback value")
  )
```

### Parallel Execution

```nim
# Run all tasks in parallel
let results = runDefault(all(@[task1(), task2(), task3()]))

# Race - get first result
let fastest = runDefault(race(@[slowTask(), fastTask()]))
```

### Timeouts

```nim
let result = runDefault(withTimeout(5.seconds, longRunningTask()))
if result.isErr and result.err.kind == Timeout:
  echo "Operation timed out"
```

## Examples

The `examples/` directory contains comprehensive examples:

| Example | Description |
|---------|-------------|
| [ex01_hello_world.nim](examples/ex01_hello_world.nim) | Basic task creation and execution |
| [ex02_async_sleep.nim](examples/ex02_async_sleep.nim) | Using sleep and perform |
| [ex03_spawn_join.nim](examples/ex03_spawn_join.nim) | Spawning and joining child tasks |
| [ex04_error_handling.nim](examples/ex04_error_handling.nim) | Error recovery and chaining |
| [ex05_timeout.nim](examples/ex05_timeout.nim) | Timeout patterns |
| [ex06_retry.nim](examples/ex06_retry.nim) | Retry with backoff |
| [ex07_parallel.nim](examples/ex07_parallel.nim) | Parallel execution (all, race, allSettled) |
| [ex08_nursery.nim](examples/ex08_nursery.nim) | Structured concurrency |
| [ex09_channels.nim](examples/ex09_channels.nim) | Channel-based communication |
| [ex10_sync.nim](examples/ex10_sync.nim) | Semaphore and Mutex |
| [ex11_resource.nim](examples/ex11_resource.nim) | Resource management (bracket) |
| [ex12_worker_pool.nim](examples/ex12_worker_pool.nim) | Worker pool pattern |
| [ex13_rate_limiter.nim](examples/ex13_rate_limiter.nim) | Rate limiting |
| [ex14_pipeline.nim](examples/ex14_pipeline.nim) | Data processing pipeline |
| [ex15_cancellation.nim](examples/ex15_cancellation.nim) | Task cancellation |
| [ex16_asyncdispatch_interop.nim](examples/ex16_asyncdispatch_interop.nim) | AsyncDispatch integration |

Run an example:

```bash
nim c -r examples/ex01_hello_world.nim
```

## Documentation

- [Getting Started](docs/getting_started.md) - Introduction and basic concepts
- [API Reference](docs/api_reference.md) - Complete API documentation
- [Patterns & Best Practices](docs/patterns.md) - Common patterns and tips

## API Overview

### Core Types

- `Task[T]` - Async computation producing `T`
- `Result[T]` - Success value or error
- `RtError` - Error with kind, message, and optional cause chain
- `Unit` - Void-like type for `Task[Unit]`

### Running Tasks

```nim
runDefault(task)           # Run to completion, return Result[T]
runDefaultWithTrace(task)  # Run with tracing support
start(task)                # Start task, return TaskId
```

### Combinators

```nim
andThen(task, f)    # Chain tasks (flatMap)
map(task, f)        # Transform successful result
recover(task, f)    # Recover from errors
ensure(task, fin)   # Always run finalizer
```

### Parallel Execution

```nim
all(tasks)          # Run all, fail fast
allSettled(tasks)   # Run all, collect results
race(tasks)         # First to complete wins
```

### Synchronization

```nim
newSemaphore(n)     # Limit concurrency
newMutex()          # Mutual exclusion
newTaskChannel[T]() # Inter-task communication
```

### Resource Management

```nim
bracket(acquire, use, release)  # Safe resource handling
```

## Guidelines

- Use `Task[Unit]` for void-like effects and returns
- Use `unit()` to construct a value for `Task[Unit]`
- Always mark closures with `{.gcsafe, closure.}`
- Use `perform sleep()` instead of stdlib `sleep()` inside tasks
- Handle errors using `recover`, `catchError`, or check `Result.isOk`

## Running Tests

```bash
# Run all tests
./build_all.sh

# Run specific test
nim c -r tests/t_rteffects.nim
nim c -r tests/t_spec.nim
nim c -r tests/t_new_features.nim
```

## CI with Coverage

```bash
scripts/ci/run_testament_gcov.sh
```

Example GitHub Actions:

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: iffy/install-nim@v5
        with:
          version: "2.3.1"
      - run: sudo apt-get update && sudo apt-get install -y lcov
      - run: scripts/ci/run_testament_gcov.sh
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-html
          path: coverage/html
```

## License

MIT
