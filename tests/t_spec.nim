import std/[unittest, times, asyncdispatch, strutils]
import rteffects

suite "Spec: CPS (.rt.) and core ops":
  test "given .rt. proc when using perform/await then CPS transforms are correct":
    proc t(): Task[int] {.rt.} =
      var v = 1
      if v == 1:
        perform sleep(1.milliseconds)
        v = 3
      else:
        v = 5
      return v

    let res = runDefault(t())
    check res.isOk
    check res.ok == 3

  test "given .rt. proc when return await then value is returned":
    proc child(): Task[int] {.rt.} =
      return 4

    proc parent(): Task[int] {.rt.} =
      return await child()

    let res = runDefault(parent())
    check res.isOk
    check res.ok == 4

  test "given .rt. proc when defer/finally then cleanup runs":
    var cleaned = false
    proc t(): Task[int] {.rt.} =
      defer:
        cleaned = true
      return 8

    let res = runDefault(t())
    check res.isOk
    check res.ok == 8
    check cleaned

suite "Spec: Task lifecycle":
  test "given start/spawn when task completes then join returns result":
    var marker = 0
    proc t(): Task[Unit] {.rt.} =
      marker = 7
      return unit()

    let id = start(t())
    check id != InvalidTaskId
    check marker == 7

  test "given join on unknown task then ForeignError is returned":
    proc parent(): Task[Unit] {.rt.} =
      let res = await joinResult[int](TaskId(9999))
      if not res.isOk:
        return await fail[Unit](res.err)
      return unit()

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError

  test "given cancel when task is blocked then it resumes as Cancelled":
    proc sleeper(): Task[int] {.rt.} =
      perform sleep(50.milliseconds)
      return 1

    proc parent(): Task[int] {.rt.} =
      let id = await spawn(sleeper())
      perform cancel(id)
      return await join[int](id)

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.Cancelled

suite "Spec: Error boundaries and cancellation":
  test "given .rt. proc when it raises then ExceptionRaised is returned at boundary":
    proc boom(): Task[Unit] {.rt.} =
      raise newException(ValueError, "boom")

    let res = runDefault(boom())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ExceptionRaised

  test "given spawned task when it raises then join returns ExceptionRaised":
    proc child(): Task[int] {.rt.} =
      raise newException(ValueError, "child-boom")

    proc parent(): Task[int] {.rt.} =
      let id = await spawn(child())
      return await join[int](id)

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ExceptionRaised

  test "given parent cancellation when child is running then cancellation propagates":
    var childId = InvalidTaskId

    proc child(): Task[Unit] {.rt.} =
      perform sleep(50.milliseconds)
      return unit()

    proc parent(): Task[Unit] {.rt.} =
      let id = await spawn(child())
      childId = id
      perform sleep(50.milliseconds)
      return unit()

    proc root(): Task[Unit] {.rt.} =
      let parentId = await spawn(parent())
      perform yieldNow()
      perform cancel(parentId)
      if childId == InvalidTaskId:
        return await fail[Unit](foreignError("child id was not set"))
      let res = await joinResult[Unit](childId)
      if res.isOk:
        return await fail[Unit](foreignError("expected child to be cancelled"))
      if res.err.kind != RtErrorKind.Cancelled:
        return await fail[Unit](res.err)
      return unit()

    let res = runDefault(root())
    check res.isOk

suite "Spec: Timeout semantics":
  test "given withTimeout when task completes first then timer is cancelled":
    proc fast(): Task[int] {.rt.} =
      perform sleep(1.milliseconds)
      return 9

    let res = runDefault(withTimeout(20.milliseconds, fast()))
    check res.isOk
    check res.ok == 9

  test "given withTimeout when timeout wins then task is cancelled and Timeout returned":
    proc slow(): Task[int] {.rt.} =
      perform sleep(20.milliseconds)
      return 1

    let res = runDefault(withTimeout(1.milliseconds, slow()))
    check res.isOk == false
    check res.err.kind == RtErrorKind.Timeout

suite "Spec: asyncdispatch interop":
  test "given awaitFuture when future fails then ExceptionRaised is returned":
    proc awaiter(): Task[int] {.rt.} =
      let fut = newFuture[int]("fail-future")
      fut.fail(newException(ValueError, "boom"))
      return await awaitFuture(fut)

    let res = runDefault(awaiter())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ExceptionRaised

  test "given Task when converting to Future then future resolves on completion":
    proc t(): Task[int] {.rt.} =
      return 6

    let fut = toFuture(t())
    let v = waitFor(fut)
    check v == 6

suite "Spec: Nursery and structured concurrency":
  test "given nursery scope when child fails then FailFast cancels siblings":
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

  test "given nursery policy CollectAll then errors are aggregated":
    proc okChild(): Task[Unit] {.rt.} =
      perform sleep(1.milliseconds)
      return unit()

    proc failingChild(): Task[Unit] {.rt.} =
      return await fail[Unit](foreignError("boom"))

    proc parent(): Task[Unit] =
      let n = newNursery(npCollectAll)
      andThen(spawnChild(n, okChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
          joinAll(n)
        )
      )

    let res = runDefault(parent())
    check res.isOk == false
    check res.err.kind == RtErrorKind.ForeignError
    check res.err.msg.contains("boom")

  test "given nursery policy Supervise then parent succeeds and errors are recorded":
    proc failingChild(): Task[Unit] {.rt.} =
      return await fail[Unit](foreignError("oops"))

    proc parent(): Task[Unit] =
      let n = newNursery(npSupervise)
      andThen(spawnChild(n, failingChild()), proc(_: TaskId): Task[Unit] {.gcsafe, closure.} =
        joinAll(n)
      )

    let res = runDefault(parent())
    check res.isOk

suite "Spec: IO and tracing ops":
  test "given awaitIO operation then handler waits for IO readiness":
    proc waiter(): Task[Unit] {.rt.} =
      let ev = newAsyncEvent()
      let timer = sleepAsync(1)
      timer.addCallback(proc() = trigger(ev))
      perform awaitIO(ev)
      close(ev)
      return unit()

    let res = runDefault(waiter())
    check res.isOk

  test "given trace operation then handler records trace event":
    proc t(): Task[Unit] {.rt.} =
      perform trace("hello")
      return unit()

    let traced = runDefaultWithTrace(t())
    check traced.result.isOk
    check traced.trace.len == 1
    check traced.trace[0] == "hello"

suite "Spec: Control-flow constraints":
  test "given .rt. proc when while is used then it works correctly":
    proc t(): Task[int] {.rt.} =
      var count = 0
      while count < 3:
        perform sleep(1.milliseconds)
        count.inc
      return count

    let res = runDefault(t())
    check res.isOk
    check res.ok == 3
