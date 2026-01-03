import std/[unittest, times, asyncdispatch, strutils, hashes]
import rteffects

suite "Cancellation Check API":
  test "isCancelled returns false for non-cancelled task":
    proc t(): Task[bool] {.rt.} =
      return await isCancelled()

    let res = runDefault(t())
    check res.isOk
    check res.ok == false

  test "checkCancelled passes for non-cancelled task":
    proc t(): Task[int] {.rt.} =
      perform checkCancelled()
      return 42

    let res = runDefault(t())
    check res.isOk
    check res.ok == 42

  test "checkCancelled returns error for cancelled task":
    proc child(): Task[int] {.rt.} =
      perform sleep(10.milliseconds)
      perform checkCancelled()
      return 1

    proc parent(): Task[int] {.rt.} =
      let id = await spawn(child())
      perform cancel(id)
      return await join[int](id)

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.Cancelled

suite "Task Combinators":
  test "map transforms success value":
    proc t(): Task[int] {.rt.} =
      return 5

    let mapped = map(t(), proc(v: int): string {.gcsafe, closure.} = $v)
    let res = runDefault(mapped)
    check res.isOk
    check res.ok == "5"

  test "map propagates error":
    let failed = fail[int](foreignError("oops"))
    let mapped = map(failed, proc(v: int): string {.gcsafe, closure.} = $v)
    let res = runDefault(mapped)
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "recover handles error":
    let failed = fail[int](foreignError("oops"))
    let recovered = recover(failed, proc(e: RtError): Task[int] {.gcsafe, closure.} =
      pure(42)
    )
    let res = runDefault(recovered)
    check res.isOk
    check res.ok == 42

  test "recoverWith provides default value":
    let failed = fail[int](foreignError("oops"))
    let recovered = recoverWith(failed, 100)
    let res = runDefault(recovered)
    check res.isOk
    check res.ok == 100

  test "retry succeeds on first attempt":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        k(rt, ok(attempts))

    let res = runDefault(retry(task(), 3))
    check res.isOk
    check res.ok == 1
    check attempts == 1

  test "retry retries on failure":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        if attempts < 3:
          k(rt, err[int](foreignError("fail")))
        else:
          k(rt, ok(attempts))

    let res = runDefault(retry(task(), 5))
    check res.isOk
    check res.ok == 3
    check attempts == 3

  test "retry fails after max attempts":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        k(rt, err[int](foreignError("always fail")))

    let res = runDefault(retry(task(), 3))
    check res.isOk == false
    check attempts == 3

  test "race returns first completed":
    proc fast(): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return 1

    proc slow(): Task[int] {.rt.} =
      perform sleep(50.milliseconds)
      return 2

    let res = runDefault(race(@[slow(), fast()]))
    check res.isOk
    check res.ok == 1

  test "all collects all results":
    proc main(): Task[seq[int]] =
      var tasks: seq[Task[int]] = @[]
      tasks.add(pure(1))
      tasks.add(pure(2))
      tasks.add(pure(3))
      all(tasks)

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 3
    # Results may be in any order due to parallel execution
    check 1 in res.ok
    check 2 in res.ok
    check 3 in res.ok

  test "all fails on first error":
    proc ok1(): Task[int] {.rt.} =
      return 1

    proc failing(): Task[int] {.rt.} =
      return await fail[int](foreignError("boom"))

    let res = runDefault(all(@[ok1(), failing()]))
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "allSettled collects all results including failures":
    proc main(): Task[seq[Result[int]]] =
      var tasks: seq[Task[int]] = @[]
      tasks.add(pure(1))
      tasks.add(fail[int](foreignError("boom")))
      tasks.add(pure(2))
      allSettled(tasks)

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 3
    # Check that we have both success and failure results
    var successCount = 0
    var failCount = 0
    for r in res.ok:
      if r.isOk:
        successCount.inc
      else:
        failCount.inc
    check successCount == 2
    check failCount == 1

suite "Type-Safe Task IDs":
  test "spawnTyped and joinTyped work correctly":
    proc child(): Task[int] {.rt.} =
      return 42

    proc parent(): Task[int] {.rt.} =
      let tid = await spawnTyped(child())
      return await joinTyped(tid)

    let res = runDefault(parent())
    check res.isOk
    check res.ok == 42

  test "cancelTyped cancels the task":
    proc child(): Task[int] {.rt.} =
      perform sleep(50.milliseconds)
      return 1

    proc parent(): Task[int] {.rt.} =
      let tid = await spawnTyped(child())
      perform cancelTyped(tid)
      return await joinTyped(tid)

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.Cancelled

suite "Resource Management (Bracket)":
  test "bracket releases resource on success":
    var acquired = false
    var released = false

    proc acquire(): Task[string] {.rt.} =
      acquired = true
      return "resource"

    proc use(r: string): Task[int] {.rt.} =
      check r == "resource"
      return 42

    proc release(r: string): Task[Unit] {.rt.} =
      check r == "resource"
      released = true
      return unit()

    let res = runDefault(bracket(acquire(), use, release))
    check res.isOk
    check res.ok == 42
    check acquired
    check released

  test "bracket releases resource on error":
    var released = false

    proc acquire(): Task[int] {.rt.} =
      return 1

    proc use(r: int): Task[string] {.rt.} =
      return await fail[string](foreignError("use failed"))

    proc release(r: int): Task[Unit] {.rt.} =
      released = true
      return unit()

    let res = runDefault(bracket(acquire(), use, release))
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError
    check released

suite "TaskChannel Communication":
  test "basic send and receive":
    proc main(): Task[int] =
      let ch = newTaskChannel[int]()

      proc sender(ch: TaskChannel[int]): Task[Unit] =
        send(ch, 42)

      proc receiver(ch: TaskChannel[int]): Task[int] =
        recv(ch)

      andThen(spawn(sender(ch)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
        andThen(sleep(1.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
          receiver(ch)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == 42

  test "channel with capacity blocks sender":
    proc main(): Task[seq[int]] =
      let ch = newTaskChannel[int](1)

      proc sender(ch: TaskChannel[int]): Task[Unit] =
        andThen(send(ch, 1), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          send(ch, 2)
        )

      proc receiver(ch: TaskChannel[int]): Task[seq[int]] =
        andThen(recv(ch), proc(v1: int): Task[seq[int]] {.gcsafe, closure.} =
          andThen(sleep(1.milliseconds), proc(_: Unit): Task[seq[int]] {.gcsafe, closure.} =
            andThen(recv(ch), proc(v2: int): Task[seq[int]] {.gcsafe, closure.} =
              pure(@[v1, v2])
            )
          )
        )

      andThen(spawn(sender(ch)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        receiver(ch)
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == @[1, 2]

  test "tryRecv returns error when empty":
    proc main(): Task[Result[int]] =
      let ch = newTaskChannel[int]()
      tryRecv(ch)

    let res = runDefault(main())
    check res.isOk
    check res.ok.isOk == false

  test "close channel wakes receivers":
    proc main(): Task[Result[int]] =
      let ch = newTaskChannel[int]()

      proc receiver(ch: TaskChannel[int]): Task[int] =
        recv(ch)

      andThen(spawn(receiver(ch)), proc(tid: TaskId): Task[Result[int]] {.gcsafe, closure.} =
        andThen(sleep(1.milliseconds), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
          andThen(closeChannel(ch), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
            joinResult[int](tid)
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.isOk == false  # Channel closed

suite "Semaphore":
  test "semaphore basic acquire and release":
    proc main(): Task[Unit] =
      let sem = newSemaphore(1)
      andThen(acquire(sem), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        release(sem)
      )

    let res = runDefault(main())
    check res.isOk

  test "withSemaphore acquires and releases":
    proc main(): Task[int] =
      let sem = newSemaphore(1)
      withSemaphore(sem, pure(42))

    let res = runDefault(main())
    check res.isOk
    check res.ok == 42

  test "tryAcquire returns true when available":
    proc main(): Task[bool] =
      let sem = newSemaphore(1)
      tryAcquire(sem)

    let res = runDefault(main())
    check res.isOk
    check res.ok == true

  test "tryAcquire returns false when not available":
    proc main(): Task[bool] =
      let sem = newSemaphore(1)
      andThen(acquire(sem), proc(_: Unit): Task[bool] {.gcsafe, closure.} =
        tryAcquire(sem)
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == false

suite "Mutex":
  test "mutex basic lock and unlock":
    proc main(): Task[Unit] =
      let m = newMutex()
      andThen(lock(m), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        unlock(m)
      )

    let res = runDefault(main())
    check res.isOk

  test "withMutex acquires and releases":
    proc main(): Task[int] =
      let m = newMutex()
      withMutex(m, pure(42))

    let res = runDefault(main())
    check res.isOk
    check res.ok == 42

  test "tryLock returns true when available":
    proc main(): Task[bool] =
      let m = newMutex()
      tryLock(m)

    let res = runDefault(main())
    check res.isOk
    check res.ok == true

  test "tryLock returns false when locked":
    proc main(): Task[bool] =
      let m = newMutex()
      andThen(lock(m), proc(_: Unit): Task[bool] {.gcsafe, closure.} =
        tryLock(m)
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == false

suite "Typed Nursery":
  test "typed nursery collects results":
    proc child(n: int): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return n * 2

    proc main(): Task[seq[int]] =
      typedNursery[int](proc (n: TypedNursery[int]): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, child(1)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          andThen(spawnChild(n, child(2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
            andThen(spawnChild(n, child(3)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
              pure(unit())
            )
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 3
    check 2 in res.ok
    check 4 in res.ok
    check 6 in res.ok

  test "typed nursery with failing child":
    proc okChild(n: int): Task[int] {.rt.} =
      return n

    proc failChild(): Task[int] {.rt.} =
      return await fail[int](foreignError("boom"))

    proc main(): Task[seq[Result[int]]] =
      typedNurseryAll[int](proc (n: TypedNursery[int]): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, okChild(1)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          andThen(spawnChild(n, failChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
            andThen(spawnChild(n, okChild(2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
              pure(unit())
            )
          )
        )
      , npSupervise)

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 3
    check res.ok[0].isOk
    check res.ok[1].isOk == false
    check res.ok[2].isOk

suite "Error Chaining":
  test "withCause creates error chain":
    let inner = foreignError("inner error")
    let outer = foreignError("outer error").withCause(inner)

    check outer.cause != nil
    check outer.cause[].msg == "inner error"

  test "rootCause finds original error":
    let e1 = foreignError("level 1")
    let e2 = foreignError("level 2").withCause(e1)
    let e3 = foreignError("level 3").withCause(e2)

    let root = rootCause(e3)
    check root.msg == "level 1"

  test "aggregateError collects multiple errors":
    let errors = @[
      foreignError("error 1"),
      foreignError("error 2"),
      foreignError("error 3")
    ]
    let agg = aggregateError(errors)

    check agg.kind == RtErrorKind.AggregateError
    check agg.children.len == 3

suite "Iteration Helpers":
  test "forEachTask iterates sequentially":
    proc main(): Task[seq[int]] =
      var order: seq[int] = @[]
      let items = @[1, 2, 3]

      proc body(item: int): Task[Unit] {.gcsafe, closure.} =
        order.add(item)
        pure(unit())

      andThen(forEachTask(items, body), proc(_: Unit): Task[seq[int]] {.gcsafe, closure.} =
        pure(order)
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == @[1, 2, 3]

  test "mapTask transforms items":
    proc main(): Task[seq[int]] =
      let items = @[1, 2, 3]

      proc double(n: int): Task[int] {.gcsafe, closure.} =
        pure(n * 2)

      mapTask(items, double)

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 3
    # Check that all doubled values are present (order may vary)
    check 2 in res.ok
    check 4 in res.ok
    check 6 in res.ok

  test "filterTask filters items":
    proc main(): Task[seq[int]] =
      let items = @[1, 2, 3, 4, 5]

      proc isEven(n: int): Task[bool] {.gcsafe, closure.} =
        pure(n mod 2 == 0)

      filterTask(items, isEven)

    let res = runDefault(main())
    check res.isOk
    check res.ok == @[2, 4]

suite "While Loop Support":
  test "while loop with await in body":
    proc t(): Task[int] {.rt.} =
      var count = 0
      while count < 3:
        perform sleep(1.milliseconds)
        count.inc
      return count

    let res = runDefault(t())
    check res.isOk
    check res.ok == 3

suite "For Loop Support":
  test "for loop without await":
    proc t(): Task[int] {.rt.} =
      var sum = 0
      for i in 1..3:
        sum += i
      return sum

    let res = runDefault(t())
    check res.isOk
    check res.ok == 6

suite "Additional Coverage Tests":
  test "bracketOnError releases only on failure":
    var releasedOnErr = false

    proc acquire(): Task[int] {.rt.} =
      return 1

    proc useSuccess(r: int): Task[string] {.rt.} =
      return "ok"

    proc releaseOnErr(r: int): Task[Unit] {.rt.} =
      releasedOnErr = true
      return unit()

    let res = runDefault(bracketOnError(acquire(), useSuccess, releaseOnErr))
    check res.isOk
    check res.ok == "ok"
    check releasedOnErr == false  # Should NOT release on success

  test "bracketOnError releases on failure":
    var releasedOnErr = false

    proc acquire(): Task[int] {.rt.} =
      return 1

    proc useFail(r: int): Task[string] {.rt.} =
      return await fail[string](foreignError("boom"))

    proc releaseOnErr(r: int): Task[Unit] {.rt.} =
      releasedOnErr = true
      return unit()

    let res = runDefault(bracketOnError(acquire(), useFail, releaseOnErr))
    check res.isOk == false
    check releasedOnErr == true  # Should release on failure

  test "forEachParallel runs in parallel":
    proc main(): Task[Unit] =
      let items = @[1, 2, 3]

      proc body(item: int): Task[Unit] {.gcsafe, closure.} =
        andThen(sleep(1.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          pure(unit())
        )

      forEachParallel(items, body)

    let res = runDefault(main())
    check res.isOk

  test "forEachParallel with empty list":
    proc main(): Task[Unit] =
      var items: seq[int] = @[]
      forEachParallel(items, proc(item: int): Task[Unit] {.gcsafe, closure.} =
        pure(unit())
      )

    let res = runDefault(main())
    check res.isOk

  test "race with empty list returns error":
    var tasks: seq[Task[int]] = @[]
    let res = runDefault(race(tasks))
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "all with empty list returns empty seq":
    var tasks: seq[Task[int]] = @[]
    let res = runDefault(all(tasks))
    check res.isOk
    check res.ok.len == 0

  test "allSettled with empty list returns empty seq":
    var tasks: seq[Task[int]] = @[]
    let res = runDefault(allSettled(tasks))
    check res.isOk
    check res.ok.len == 0

  test "retry with delay between attempts":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        if attempts < 2:
          k(rt, err[int](foreignError("fail")))
        else:
          k(rt, ok(attempts))

    let res = runDefault(retry(task(), 3, initDuration(milliseconds = 1)))
    check res.isOk
    check res.ok == 2
    check attempts == 2

  test "retryWithBackoff with multiple failures":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        if attempts < 3:
          k(rt, err[int](foreignError("fail")))
        else:
          k(rt, ok(attempts))

    let res = runDefault(retryWithBackoff(task(), 5, initDuration(milliseconds = 1), initDuration(milliseconds = 5)))
    check res.isOk
    check res.ok == 3
    check attempts == 3

  test "retryWithBackoff fails after max attempts":
    var attempts = 0
    proc task(): Task[int] =
      proc (rt: ptr Runtime, k: Cont[int]) =
        attempts.inc
        k(rt, err[int](foreignError("always fail")))

    let res = runDefault(retryWithBackoff(task(), 2, initDuration(milliseconds = 1)))
    check res.isOk == false
    check attempts == 2

  test "runDefaultWithTrace with hook":
    var hookedMsgs: seq[string] = @[]
    proc hook(msg: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        hookedMsgs.add(msg)

    proc t(): Task[Unit] {.rt.} =
      perform trace("hello")
      perform trace("world")
      return unit()

    let res = runDefaultWithTrace(t(), hook)
    check res.isOk
    check hookedMsgs.len == 2
    check hookedMsgs[0] == "hello"
    check hookedMsgs[1] == "world"

  test "withTimeout with TimeInterval":
    proc fast(): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return 42

    let res = runDefault(withTimeout(20.milliseconds, fast()))
    check res.isOk
    check res.ok == 42

  test "sleep with TimeInterval":
    proc t(): Task[Unit] {.rt.} =
      perform sleep(1.milliseconds)
      return unit()

    let res = runDefault(t())
    check res.isOk

  test "flatMap works as andThen alias":
    let t = pure(5)
    let mapped = flatMap(t, proc(v: int): Task[string] {.gcsafe, closure.} = pure($v))
    let res = runDefault(mapped)
    check res.isOk
    check res.ok == "5"

  test "catchError converts error to success":
    let failed = fail[int](foreignError("oops"))
    let caught = catchError(failed, proc(e: RtError): int {.gcsafe, closure.} = 99)
    let res = runDefault(caught)
    check res.isOk
    check res.ok == 99

  test "catchError passes through success":
    let success = pure(42)
    let caught = catchError(success, proc(e: RtError): int {.gcsafe, closure.} = 99)
    let res = runDefault(caught)
    check res.isOk
    check res.ok == 42

  test "recover passes through success":
    let success = pure(42)
    let recovered = recover(success, proc(e: RtError): Task[int] {.gcsafe, closure.} = pure(99))
    let res = runDefault(recovered)
    check res.isOk
    check res.ok == 42

  test "ensure runs finalizer on success":
    var finalizerRan = false
    proc t(): Task[int] {.rt.} =
      return 42

    proc fin(): Task[Unit] =
      proc (rt: ptr Runtime, k: Cont[Unit]) =
        finalizerRan = true
        k(rt, ok(unit()))

    let res = runDefault(ensure(t(), fin()))
    check res.isOk
    check res.ok == 42
    check finalizerRan

  test "ensure runs finalizer on error":
    var finalizerRan = false
    let failed = fail[int](foreignError("boom"))

    proc fin(): Task[Unit] =
      proc (rt: ptr Runtime, k: Cont[Unit]) =
        finalizerRan = true
        k(rt, ok(unit()))

    let res = runDefault(ensure(failed, fin()))
    check res.isOk == false
    check finalizerRan

  test "ensure with finalizer error on success":
    proc t(): Task[int] {.rt.} =
      return 42

    let finErr = fail[Unit](foreignError("fin failed"))
    let res = runDefault(ensure(t(), finErr))
    check res.isOk == false
    check res.err.msg == "fin failed"

  test "channel send on closed channel":
    proc main(): Task[Unit] =
      let ch = newTaskChannel[int]()
      andThen(closeChannel(ch), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        send(ch, 1)
      )

    let res = runDefault(main())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "channel recv on already closed channel":
    proc main(): Task[int] =
      let ch = newTaskChannel[int]()
      andThen(closeChannel(ch), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        recv(ch)
      )

    let res = runDefault(main())
    check res.isOk == false

  test "tryRecv on closed channel":
    proc main(): Task[Result[int]] =
      let ch = newTaskChannel[int]()
      andThen(closeChannel(ch), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
        tryRecv(ch)
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.isOk == false

  test "isClosed check":
    let ch = newTaskChannel[int]()
    check isClosed(ch) == false
    discard runDefault(closeChannel(ch))
    check isClosed(ch) == true

  test "bracket with acquire failure":
    var useCalled = false
    var releaseCalled = false

    proc acquire(): Task[int] {.rt.} =
      return await fail[int](foreignError("acquire failed"))

    proc use(r: int): Task[string] {.rt.} =
      useCalled = true
      return "ok"

    proc release(r: int): Task[Unit] {.rt.} =
      releaseCalled = true
      return unit()

    let res = runDefault(bracket(acquire(), use, release))
    check res.isOk == false
    check useCalled == false
    check releaseCalled == false

  test "bracket with release failure after success":
    proc acquire(): Task[int] {.rt.} =
      return 1

    proc use(r: int): Task[string] {.rt.} =
      return "ok"

    proc release(r: int): Task[Unit] {.rt.} =
      return await fail[Unit](foreignError("release failed"))

    let res = runDefault(bracket(acquire(), use, release))
    check res.isOk == false
    check res.err.msg == "release failed"

suite "Core Type Coverage":
  test "okVoid creates void result":
    let r = okVoid()
    check r.isOk

  test "exceptionError with nil exception":
    var nilEx: ref Exception = nil
    let e = exceptionError(nilEx)
    check e.kind == RtErrorKind.ExceptionRaised
    check e.msg == "exception raised"

  test "exceptionError with real exception":
    try:
      raise newException(ValueError, "test error")
    except ValueError as e:
      let err = exceptionError(e)
      check err.kind == RtErrorKind.ExceptionRaised
      check err.msg == "test error"
      check err.stackTrace.len > 0

  test "RtError $ with cause and children":
    let child1 = foreignError("child1")
    let child2 = foreignError("child2")
    let agg = aggregateError(@[child1, child2])

    let str = $agg
    check "child1" in str
    check "child2" in str
    check "contains:" in str

    let e1 = foreignError("inner")
    let e2 = foreignError("outer").withCause(e1)
    let str2 = $e2
    check "caused by:" in str2
    check "inner" in str2

  test "TypedTaskId hash and equality":
    let tid1 = TypedTaskId[int](id: TaskId(1))
    let tid2 = TypedTaskId[int](id: TaskId(1))
    let tid3 = TypedTaskId[int](id: TaskId(2))

    check tid1 == tid2
    check not (tid1 == tid3)
    check hash(tid1) == hash(tid2)

  test "invalidTypedTaskId returns invalid":
    let inv = invalidTypedTaskId[int]()
    check inv.id == InvalidTaskId

  test "toTaskId extracts task id":
    let tid = TypedTaskId[int](id: TaskId(42))
    check toTaskId(tid) == TaskId(42)

  test "joinTypedResult returns result":
    proc child(): Task[int] {.rt.} =
      return await fail[int](foreignError("boom"))

    proc parent(): Task[Result[int]] {.rt.} =
      let tid = await spawnTyped(child())
      return await joinTypedResult(tid)

    let res = runDefault(parent())
    check res.isOk
    check res.ok.isOk == false

suite "Runtime Edge Cases":
  test "spawn a task that raises exception":
    proc boom(): Task[int] {.rt.} =
      raise newException(ValueError, "boom!")

    let res = runDefault(boom())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ExceptionRaised

  test "any is alias for race":
    proc fast(): Task[int] {.rt.} =
      return 42

    let res = runDefault(any(@[fast()]))
    check res.isOk
    check res.ok == 42

  test "whileTask basic usage":
    proc main(): Task[Unit] =
      var count = 0
      let task = whileTask(
        proc(): bool {.gcsafe, closure.} = count < 3,
        andThen(yieldNow(), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          count.inc
          pure(unit())
        )
      )
      task

    let res = runDefault(main())
    check res.isOk

  test "void task completion":
    proc voidTask(): Task[void] =
      proc (rt: ptr Runtime, k: Cont[void]) =
        k(rt, okVoid())

    let res = runDefault(voidTask())
    check res.isOk

  test "task with multiple waiters on same task":
    proc main(): Task[int] =
      proc child(): Task[int] {.rt.} =
        perform sleep(1.milliseconds)
        return 42

      proc waiter(id: TaskId): Task[int] =
        join[int](id)

      andThen(spawn(child()), proc(id: TaskId): Task[int] {.gcsafe, closure.} =
        andThen(spawn(waiter(id)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
          join[int](id)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == 42

  test "cancel already cancelled task":
    proc main(): Task[Unit] =
      proc child(): Task[int] {.rt.} =
        perform sleep(50.milliseconds)
        return 1

      andThen(spawn(child()), proc(id: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(cancel(id), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          cancel(id)  # Cancel again
        )
      )

    let res = runDefault(main())
    check res.isOk

  test "start function creates runtime and runs":
    proc t(): Task[int] {.rt.} =
      return 42

    let id = start(t())
    check id != InvalidTaskId

  test "timeout wins and cancels child":
    proc slow(): Task[int] {.rt.} =
      perform sleep(100.milliseconds)
      return 1

    let res = runDefault(withTimeout(1.milliseconds, slow()))
    check res.isOk == false
    check res.err.kind == RtErrorKind.Timeout

  test "timeout with timer error":
    proc task(): Task[int] {.rt.} =
      # This should complete before timeout
      return 42

    let res = runDefault(withTimeout(100.milliseconds, task()))
    check res.isOk
    check res.ok == 42

  test "semaphore waiter queue":
    proc main(): Task[seq[int]] =
      let sem = newSemaphore(1)
      var order: seq[int] = @[]

      proc worker(n: int): Task[Unit] =
        andThen(acquire(sem), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          order.add(n)
          andThen(sleep(1.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
            release(sem)
          )
        )

      andThen(spawn(worker(1)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        andThen(spawn(worker(2)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
          andThen(sleep(10.milliseconds), proc(_: Unit): Task[seq[int]] {.gcsafe, closure.} =
            pure(order)
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 2

  test "mutex waiter queue":
    proc main(): Task[seq[int]] =
      let m = newMutex()
      var order: seq[int] = @[]

      proc worker(n: int): Task[Unit] =
        andThen(lock(m), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          order.add(n)
          andThen(sleep(1.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
            unlock(m)
          )
        )

      andThen(spawn(worker(1)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        andThen(spawn(worker(2)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
          andThen(sleep(10.milliseconds), proc(_: Unit): Task[seq[int]] {.gcsafe, closure.} =
            pure(order)
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 2

  test "channel with waiting sender woken by receive":
    proc main(): Task[int] =
      let ch = newTaskChannel[int](1)

      # Fill the buffer
      andThen(send(ch, 1), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        # This will block
        andThen(spawn(send(ch, 2)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
          # Receive to unblock sender
          andThen(recv(ch), proc(v1: int): Task[int] {.gcsafe, closure.} =
            andThen(sleep(1.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
              andThen(recv(ch), proc(v2: int): Task[int] {.gcsafe, closure.} =
                pure(v1 + v2)
              )
            )
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok == 3

  test "tryRecv with buffered data and waiting sender":
    proc main(): Task[Result[int]] =
      let ch = newTaskChannel[int](1)
      andThen(send(ch, 42), proc(_: Unit): Task[Result[int]] {.gcsafe, closure.} =
        # Spawn a sender that will wait
        andThen(spawn(send(ch, 99)), proc(_: TaskId): Task[Result[int]] {.gcsafe, closure.} =
          # tryRecv should get 42 and wake up the waiting sender
          tryRecv(ch)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.isOk
    check res.ok.ok == 42

  test "aggregateError with empty list":
    let agg = aggregateError(@[])
    check agg.kind == RtErrorKind.AggregateError
    check agg.children.len == 0

  test "race cancels all other children":
    var child1Cancelled = false
    var child2Cancelled = false

    proc child1(): Task[int] =
      andThen(sleep(50.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        pure(1)
      )

    proc child2(): Task[int] =
      pure(2)  # Completes immediately

    let res = runDefault(race(@[child1(), child2()]))
    check res.isOk
    check res.ok == 2

  test "all cancels remaining on first failure":
    proc slow(): Task[int] =
      andThen(sleep(50.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
        pure(1)
      )

    proc failing(): Task[int] =
      fail[int](foreignError("boom"))

    let res = runDefault(all(@[slow(), failing()]))
    check res.isOk == false

  test "nursery npCollectAll aggregates errors":
    proc failingChild(): Task[Unit] {.rt.} =
      return await fail[Unit](foreignError("boom"))

    proc parent(): Task[Unit] =
      let n = newNursery(npCollectAll)
      andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(parent())
    check res.isOk == false
    check "collectAll:" in res.err.msg

suite "Nursery Coverage":
  test "nursery errors accessor":
    proc main(): Task[seq[RtError]] =
      let n = newNursery(npSupervise)
      andThen(spawnChild(n, fail[Unit](foreignError("e1"))), proc(_: TaskId): Task[seq[RtError]] {.gcsafe, closure.} =
        andThen(joinAll(n), proc(_: Unit): Task[seq[RtError]] {.gcsafe, closure.} =
          pure(n.errors)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 1

  test "typed nursery errors accessor":
    proc main(): Task[seq[RtError]] =
      let n = newTypedNursery[int](npSupervise)
      andThen(spawnChild(n, fail[int](foreignError("e1"))), proc(_: TaskId): Task[seq[RtError]] {.gcsafe, closure.} =
        andThen(joinAll(n), proc(_: Unit): Task[seq[RtError]] {.gcsafe, closure.} =
          pure(n.errors)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 1

  test "typed nursery results accessor":
    proc main(): Task[seq[Result[int]]] =
      let n = newTypedNursery[int](npSupervise)
      andThen(spawnChild(n, pure(42)), proc(_: TaskId): Task[seq[Result[int]]] {.gcsafe, closure.} =
        andThen(joinAll(n), proc(_: Unit): Task[seq[Result[int]]] {.gcsafe, closure.} =
          pure(n.results)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 1
    check res.ok[0].isOk
    check res.ok[0].ok == 42

  test "typed nursery successResults accessor":
    proc main(): Task[seq[int]] =
      let n = newTypedNursery[int](npSupervise)
      andThen(spawnChild(n, pure(42)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        andThen(spawnChild(n, fail[int](foreignError("boom"))), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
          andThen(joinAll(n), proc(_: Unit): Task[seq[int]] {.gcsafe, closure.} =
            pure(n.successResults)
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 1
    check res.ok[0] == 42

  test "typed nursery joinAllValues success":
    proc main(): Task[seq[int]] =
      let n = newTypedNursery[int]()
      andThen(spawnChild(n, pure(1)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        andThen(spawnChild(n, pure(2)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
          joinAllValues(n)
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 2
    check 1 in res.ok
    check 2 in res.ok

  test "typed nursery joinAllValues with failure":
    proc main(): Task[seq[int]] =
      let n = newTypedNursery[int](npSupervise)
      andThen(spawnChild(n, pure(1)), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
        andThen(spawnChild(n, fail[int](foreignError("boom"))), proc(_: TaskId): Task[seq[int]] {.gcsafe, closure.} =
          joinAllValues(n)
        )
      )

    let res = runDefault(main())
    check res.isOk == false

  test "typed nursery npFailFast cancels siblings":
    proc main(): Task[Unit] =
      let n = newTypedNursery[int](npFailFast)

      proc slowChild(): Task[int] =
        andThen(sleep(50.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
          pure(1)
        )

      proc failingChild(): Task[int] =
        fail[int](foreignError("boom"))

      andThen(spawnChild(n, slowChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(main())
    check res.isOk == false

  test "typed nursery npCollectAll returns aggregated error":
    proc main(): Task[Unit] =
      let n = newTypedNursery[int](npCollectAll)
      andThen(spawnChild(n, fail[int](foreignError("e1"))), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, fail[int](foreignError("e2"))), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(main())
    check res.isOk == false
    check res.err.kind == RtErrorKind.AggregateError

  test "nursery scope helper":
    var bodyRan = false
    proc main(): Task[Unit] =
      nursery(proc(n: Nursery): Task[Unit] {.gcsafe, closure.} =
        bodyRan = true
        andThen(spawnChild(n, pure(unit())), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          pure(unit())
        )
      )

    let res = runDefault(main())
    check res.isOk
    check bodyRan

  test "typed nursery scope helper":
    proc main(): Task[seq[int]] =
      typedNursery[int](proc(n: TypedNursery[int]): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, pure(1)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          andThen(spawnChild(n, pure(2)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
            pure(unit())
          )
        )
      )

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 2

  test "typed nurseryAll scope helper":
    proc main(): Task[seq[Result[int]]] =
      typedNurseryAll[int](proc(n: TypedNursery[int]): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, pure(1)), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          andThen(spawnChild(n, fail[int](foreignError("boom"))), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
            pure(unit())
          )
        )
      , npSupervise)

    let res = runDefault(main())
    check res.isOk
    check res.ok.len == 2

  test "untyped nursery npSupervise all pass":
    proc main(): Task[Unit] =
      let n = newNursery(npSupervise)
      andThen(spawnChild(n, pure(unit())), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, pure(unit())), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(main())
    check res.isOk
