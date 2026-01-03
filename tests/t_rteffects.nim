import std/[unittest, asyncdispatch, times]

import rteffects

suite "RTEffects runtime (BDD)":
  test "given core helpers when used then values are stable":
    let okRes = ok(123)
    check okRes.isOk
    check okRes.ok == 123
    let voidRes = okVoid()
    check voidRes.isOk
    let e1 = cancelledError()
    let e2 = timeoutError()
    let e3 = exceptionError("boom")
    let e4 = foreignError("oops")
    check e1.kind == RtErrorKind.Cancelled
    check e2.kind == RtErrorKind.Timeout
    check e3.kind == RtErrorKind.ExceptionRaised
    check e4.kind == RtErrorKind.ForeignError
    check $e4 == "ForeignError: oops"
    discard unit()
    discard hash(TaskId(7))

  test "given a sleep op when awaited then the task resumes with the return value":
    proc delayed(): Task[int] {.rt.} =
      perform sleep(5.milliseconds)
      return 42

    let res = runDefault(delayed())
    check res.isOk
    check res.ok == 42

  test "given a spawned child when joined then the parent observes the child's result":
    proc child(): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return 7

    proc parent(): Task[int] {.rt.} =
      let id = await spawn(child())
      let v = await join[int](id)
      return v

    let res = runDefault(parent())
    check res.isOk
    check res.ok == 7

  test "given a cancelled child when joined then the parent sees Cancelled":
    proc longTask(): Task[int] {.rt.} =
      perform sleep(50.milliseconds)
      return 99

    proc canceller(): Task[int] {.rt.} =
      let id = await spawn(longTask())
      perform cancel(id)
      return await join[int](id)

    let res = runDefault(canceller())
    check res.isOk == false
    check res.err.kind == RtErrorKind.Cancelled

  test "given a Future when awaited then the value is bridged into Task":
    proc awaiter(): Task[int] {.rt.} =
      let fut = newFuture[int]("bridge-test")
      let timer = sleepAsync(5)
      timer.addCallback(proc() = fut.complete(11))
      return await awaitFuture(fut)

    let res = runDefault(awaiter())
    check res.isOk
    check res.ok == 11

  test "given a failed Future when awaited then ExceptionRaised is returned":
    proc awaiter(): Task[int] {.rt.} =
      let fut = newFuture[int]("fail-bridge")
      fut.fail(newException(ValueError, "broken"))
      return await awaitFuture(fut)

    let res = runDefault(awaiter())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ExceptionRaised

  test "given yieldNow when awaited then the task continues":
    proc t(): Task[int] {.rt.} =
      perform yieldNow()
      return 9

    let res = runDefault(t())
    check res.isOk
    check res.ok == 9

  test "given a completed child when joined then join returns immediately":
    proc child(): Task[int] {.rt.} =
      return 10

    proc parent(): Task[int] {.rt.} =
      let id = await spawn(child())
      perform yieldNow()
      let v = await join[int](id)
      return v

    let res = runDefault(parent())
    check res.isOk
    check res.ok == 10

  test "given an unknown task when joined then ForeignError is returned":
    proc parent(): Task[Unit] {.rt.} =
      let res = await joinResult[int](TaskId(9999))
      if not res.isOk:
        return await fail[Unit](res.err)
      return unit()

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given cancel on unknown task then it succeeds":
    proc parent(): Task[Unit] {.rt.} =
      perform cancel(TaskId(4242))
      return unit()

    let res = runDefault(parent())
    check res.isOk

  test "given withTimeout when task completes then result is ok":
    proc fast(): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return 5

    proc parent(): Task[int] {.rt.} =
      return await withTimeout(20.milliseconds, fast())

    let res = runDefault(parent())
    check res.isOk
    check res.ok == 5

  test "given withTimeout when timeout happens then Timeout is returned":
    proc slow(): Task[int] {.rt.} =
      perform sleep(30.milliseconds)
      return 1

    proc parent(): Task[int] {.rt.} =
      return await withTimeout(1.milliseconds, slow())

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.Timeout

  test "given withTimeout when task fails then error is returned":
    proc bad(): Task[int] {.rt.} =
      return await fail[int](foreignError("bad"))

    proc parent(): Task[int] {.rt.} =
      return await withTimeout(20.milliseconds, bad())

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given a cancelled sleeper then the sleep callback is ignored":
    proc sleeper(): Task[Unit] {.rt.} =
      perform sleep(10.milliseconds)
      return unit()

    proc parent(): Task[Unit] {.rt.} =
      let id = await spawn(sleeper())
      perform cancel(id)
      perform sleep(20.milliseconds)
      return unit()

    let res = runDefault(parent())
    check res.isOk

  test "given a cancelled awaitFuture then the future callback is ignored":
    proc waiter(fut: Future[int]): Task[Unit] {.rt.} =
      discard await awaitFuture(fut)
      return unit()

    proc parent(): Task[Unit] {.rt.} =
      let fut = newFuture[int]("ignore-bridge")
      let timer = sleepAsync(5)
      timer.addCallback(proc() = fut.complete(1))
      let id = await spawn(waiter(fut))
      perform cancel(id)
      perform sleep(20.milliseconds)
      return unit()

    let res = runDefault(parent())
    check res.isOk

  test "given andThen with error then the error is propagated":
    let t: Task[int] = fail[int](foreignError("nope"))
    let chained = andThen(t, proc(v: int): Task[int] {.gcsafe, closure.} =
      pure(v + 1)
    )
    let res = runDefault(chained)
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given a nursery when a child fails then joinAll returns the error":
    proc longChild(): Task[Unit] {.rt.} =
      perform sleep(50.milliseconds)

    proc failingChild(): Task[Unit] {.rt.} =
      return await fail[Unit](foreignError("boom"))

    proc parent(): Task[Unit] =
      let n = newNursery()
      andThen(spawnChild(n, longChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given a stuck task then runDefault returns the root error":
    let stuck: Task[int] = proc(rt: ptr Runtime, k: Cont[int]) =
      discard
    let res = runDefault(stuck, budget = 1, pollTimeoutMs = 0)
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given test hooks when executed then internal branches are covered":
    when defined(rteffectsTesting):
      testHookMarkMissing()
      testHookFinishMissing()
      testHookFinishDone()
      testHookAddJoinWaiterMissing()
      testHookAddJoinWaiterDone()
      testHookEnqueueMissing()
      testHookEnqueueCancelled()
      testHookCancelMissingAndDone()
    else:
      check false
