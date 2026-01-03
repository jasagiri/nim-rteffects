# Getting Started with RTEffects

RTEffects is a CPS (Continuation-Passing Style) based runtime effects library for Nim. It provides structured concurrency, async operations, and powerful error handling without the complexity of traditional async/await.

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

## Basic Concepts

### Tasks

A `Task[T]` represents an asynchronous computation that will produce a value of type `T` (or an error). Tasks are lazy - they don't execute until run.

```nim
import rteffects

# Define a task using the .rt. macro
proc myTask(): Task[int] {.rt.} =
  return 42

# Run the task
let result = runDefault(myTask())
if result.isOk:
  echo "Got: ", result.ok
else:
  echo "Error: ", result.err
```

### The .rt. Macro

The `.rt.` pragma transforms a regular proc into a task-returning proc with CPS transformation. Inside `.rt.` procs, you can use:

- `await` - Wait for another task and get its result
- `perform` - Execute an effect (like `sleep`)
- `return` - Return a value (transformed into `pure(value)`)

```nim
proc fetchData(): Task[string] {.rt.} =
  # Sleep for 100ms
  perform sleep(100.milliseconds)

  # Call another task
  let data = await otherTask()

  return "Processed: " & data
```

### Running Tasks

Use `runDefault` to execute a task and get its result:

```nim
let result = runDefault(myTask())
# result is Result[T] with isOk, ok, and err fields
```

## Common Patterns

### Sequential Operations

```nim
proc sequential(): Task[string] {.rt.} =
  let a = await taskA()
  let b = await taskB()
  let c = await taskC()
  return a & b & c
```

### Parallel Operations

Use `all` to run multiple tasks in parallel:

```nim
proc parallel(): Task[seq[int]] =
  all(@[task1(), task2(), task3()])

# Or use race to get the first result
proc fastest(): Task[int] =
  race(@[slowTask(), fastTask()])
```

### Error Handling

```nim
proc withErrorHandling(): Task[int] =
  let task = riskyOperation()

  # Recover from errors
  recover(task, proc(e: RtError): Task[int] {.gcsafe, closure.} =
    pure(defaultValue)
  )
```

### Timeouts

```nim
proc withTimeout(): Task[string] =
  withTimeout(5.seconds, longRunningTask())
```

### Resource Management

```nim
proc withResource(): Task[string] =
  bracket(
    acquireResource(),  # Acquire
    useResource,        # Use
    releaseResource     # Release (always called)
  )
```

## Next Steps

- See [API Reference](api_reference.md) for complete API documentation
- Check [Examples](../examples/) for practical use cases
- Read [Patterns](patterns.md) for advanced patterns and best practices
