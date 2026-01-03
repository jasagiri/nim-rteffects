import std/[asyncdispatch, asyncfutures, deques, tables, times, locks]
import ./core

type
  ReadyProc = proc () {.gcsafe.}
  JoinWaiter = proc (rt: ptr Runtime, res: AnyResult) {.gcsafe.}
  TraceHook* = proc (msg: string) {.gcsafe.}

  AnyResult = ref object of RootObj
    isOk: bool
    err: RtError

  OkResult[T] = ref object of AnyResult
    ok: T

  TaskState = enum
    tsReady,
    tsRunning,
    tsBlocked,
    tsDone

  TaskRecord = object
    id: TaskId
    parent: TaskId
    state: TaskState
    waiting: seq[JoinWaiter]
    cancelled: bool
    epoch: int
    result: AnyResult

  Runtime* = object
    readyQ: Deque[ReadyProc]
    tasks: Table[TaskId, TaskRecord]
    nextId: int
    activeCount: int
    currentId: TaskId
    budget: int
    pollTimeoutMs: int
    traceHook: TraceHook
    traceEvents: seq[string]
    shuttingDown: bool

  Cont*[T] = proc (rt: ptr Runtime, res: Result[T]) {.gcsafe, closure.}
  Task*[T] = proc (rt: ptr Runtime, k: Cont[T]) {.gcsafe, closure.}

  ## Channel for inter-task communication
  TaskChannel*[T] = ref object
    buffer: seq[T]
    capacity: int
    closed: bool
    sendWaiters: seq[proc(rt: ptr Runtime) {.gcsafe.}]
    recvWaiters: seq[proc(rt: ptr Runtime, value: T, ok: bool) {.gcsafe.}]

  ## Semaphore for limiting concurrency
  Semaphore* = ref object
    count: int
    maxCount: int
    waiters: seq[proc(rt: ptr Runtime) {.gcsafe.}]

  ## Mutex for exclusive access
  Mutex* = ref object
    locked: bool
    waiters: seq[proc(rt: ptr Runtime) {.gcsafe.}]

var liveRuntimes: seq[ref Runtime] = @[]
var runtimeLock: Lock
runtimeLock.initLock()

proc initRuntime*(budget = 1000, pollTimeoutMs = 10, traceHook: TraceHook = nil): Runtime =
  result.readyQ = initDeque[ReadyProc](64)
  result.tasks = initTable[TaskId, TaskRecord]()
  result.nextId = 1
  result.activeCount = 0
  result.currentId = InvalidTaskId
  result.budget = budget
  result.pollTimeoutMs = pollTimeoutMs
  result.traceHook = traceHook
  result.traceEvents = @[]
  result.shuttingDown = false

proc addRuntime(rtRef: ref Runtime) =
  withLock runtimeLock:
    liveRuntimes.add(rtRef)

proc removeRuntime(rtRef: ref Runtime) =
  withLock runtimeLock:
    let idx = liveRuntimes.find(rtRef)
    if idx >= 0:
      liveRuntimes.del(idx)

proc isRuntimeValid(rtPtr: ptr Runtime): bool {.gcsafe.} =
  ## Check if a runtime pointer is still valid (not yet removed)
  {.cast(gcsafe).}:
    withLock runtimeLock:
      for rtRef in liveRuntimes:
        if addr(rtRef[]) == rtPtr:
          return true
      return false

proc toAnyResult[T](res: Result[T]): AnyResult =
  if res.isOk:
    when T is void:
      return OkResult[void](isOk: true)
    elif T is Unit:
      return AnyResult(isOk: true)
    else:
      return OkResult[T](isOk: true, ok: res.ok)
  AnyResult(isOk: false, err: res.err)

proc fromAnyResult[T](res: AnyResult): Result[T] =
  if res.isOk:
    when T is void:
      return Result[void](isOk: true)
    elif T is Unit:
      return ok(unit())
    else:
      let boxed = OkResult[T](res)
      return Result[T](isOk: true, ok: boxed.ok)
  Result[T](isOk: false, err: res.err)

proc anyErr(e: RtError): AnyResult =
  AnyResult(isOk: false, err: e)

proc finishTaskAny(rt: var Runtime, id: TaskId, res: AnyResult) =
  if not rt.tasks.hasKey(id):
    return
  var rec = rt.tasks[id]
  if rec.state == tsDone:
    return
  var finalRes = res
  if rec.cancelled:
    finalRes = anyErr(cancelledError())
  let waiters = rec.waiting
  rec.state = tsDone
  rec.result = finalRes
  rec.waiting = @[]
  rt.tasks[id] = rec
  rt.activeCount.dec
  let rtPtr = addr rt
  for waiter in waiters:
    let w = waiter
    rt.readyQ.addLast(proc() = w(rtPtr, finalRes))

proc finishTask[T](rt: var Runtime, id: TaskId, res: Result[T]) =
  finishTaskAny(rt, id, toAnyResult(res))

proc markBlocked(rt: var Runtime, id: TaskId) =
  if not rt.tasks.hasKey(id):
    return
  var rec = rt.tasks[id]
  if rec.state != tsDone:
    rec.state = tsBlocked
    rt.tasks[id] = rec

proc markReady(rt: var Runtime, id: TaskId) =
  if not rt.tasks.hasKey(id):
    return
  var rec = rt.tasks[id]
  if rec.state != tsDone:
    rec.state = tsReady
    rt.tasks[id] = rec

proc enqueueCont[T](rt: var Runtime, id: TaskId, k: Cont[T], res: Result[T]) =
  let rtPtr = addr rt
  rt.readyQ.addLast(proc() =
    if not rtPtr[].tasks.hasKey(id):
      return
    let rec = rtPtr[].tasks[id]
    if rec.cancelled:
      finishTaskAny(rtPtr[], id, anyErr(cancelledError()))
      return
    rtPtr[].currentId = id
    if rec.state != tsDone:
      var updated = rec
      updated.state = tsRunning
      rtPtr[].tasks[id] = updated
    try:
      k(rtPtr, res)
    except CatchableError:
      let msg = getCurrentExceptionMsg()
      finishTaskAny(rtPtr[], id, anyErr(exceptionError(msg)))
  )

proc startTask[T](rt: var Runtime, parent: TaskId, task: Task[T]): TaskId =
  let id = TaskId(rt.nextId)
  rt.nextId.inc
  rt.activeCount.inc
  rt.tasks[id] = TaskRecord(
    id: id,
    parent: parent,
    state: tsReady,
    waiting: @[],
    cancelled: false,
    epoch: 0,
    result: nil
  )
  let rtPtr = addr rt
  rt.readyQ.addLast(proc() =
    if not rtPtr[].tasks.hasKey(id):
      return
    var rec = rtPtr[].tasks[id]
    if rec.cancelled:
      finishTaskAny(rtPtr[], id, anyErr(cancelledError()))
      return
    rtPtr[].currentId = id
    rec.state = tsRunning
    rtPtr[].tasks[id] = rec
    try:
      task(rtPtr, proc(rtInner: ptr Runtime, res: Result[T]) =
        finishTask(rtInner[], id, res)
      )
    except CatchableError:
      let msg = getCurrentExceptionMsg()
      finishTaskAny(rtPtr[], id, anyErr(exceptionError(msg)))
  )
  id

proc addJoinWaiter(rt: var Runtime, id: TaskId, waiter: JoinWaiter) =
  if not rt.tasks.hasKey(id):
    return
  var rec = rt.tasks[id]
  if rec.state == tsDone:
    let rtPtr = addr rt
    rt.readyQ.addLast(proc() = waiter(rtPtr, rec.result))
  else:
    rec.waiting.add(waiter)
    rt.tasks[id] = rec

proc cancelTask(rt: var Runtime, id: TaskId) =
  if not rt.tasks.hasKey(id):
    return
  var rec = rt.tasks[id]
  if rec.cancelled:
    return
  if rec.state == tsDone:
    return
  rec.cancelled = true
  rec.epoch.inc
  rt.tasks[id] = rec
  var children: seq[TaskId] = @[]
  for childId, childRec in rt.tasks.pairs:
    if childRec.parent == id:
      children.add(childId)
  for childId in children:
    cancelTask(rt, childId)
  if rec.state != tsRunning:
    finishTaskAny(rt, id, anyErr(cancelledError()))

proc runLoop*(rt: var Runtime) =
  while rt.activeCount > 0 or rt.readyQ.len > 0:
    var budget = rt.budget
    while budget > 0 and rt.readyQ.len > 0:
      let job = rt.readyQ.popFirst()
      job()
      dec budget
    if rt.readyQ.len == 0:
      if hasPendingOperations():
        poll(rt.pollTimeoutMs)
      else:
        break

proc runDefault*[T](body: Task[T], budget = 1000, pollTimeoutMs = 10): Result[T] =
  let rtRef = new(Runtime)
  rtRef[] = initRuntime(budget, pollTimeoutMs)
  addRuntime(rtRef)
  var rootResult: Result[T] = err[T](foreignError("root task did not complete"))
  let rootId = startTask(rtRef[], InvalidTaskId, body)
  let waiter: JoinWaiter = proc(rtPtr: ptr Runtime, res: AnyResult) =
    rootResult = fromAnyResult[T](res)
  addJoinWaiter(rtRef[], rootId, waiter)
  rtRef[].runLoop()
  removeRuntime(rtRef)
  rootResult

proc runDefaultWithTrace*[T](body: Task[T], hook: TraceHook, budget = 1000,
                             pollTimeoutMs = 10): Result[T] =
  let rtRef = new(Runtime)
  rtRef[] = initRuntime(budget, pollTimeoutMs, hook)
  addRuntime(rtRef)
  var rootResult: Result[T] = err[T](foreignError("root task did not complete"))
  let rootId = startTask(rtRef[], InvalidTaskId, body)
  let waiter: JoinWaiter = proc(rtPtr: ptr Runtime, res: AnyResult) =
    rootResult = fromAnyResult[T](res)
  addJoinWaiter(rtRef[], rootId, waiter)
  rtRef[].runLoop()
  removeRuntime(rtRef)
  rootResult

proc runDefaultWithTrace*[T](body: Task[T], budget = 1000,
                             pollTimeoutMs = 10): tuple[result: Result[T], trace: seq[string]] =
  let rtRef = new(Runtime)
  rtRef[] = initRuntime(budget, pollTimeoutMs)
  addRuntime(rtRef)
  var rootResult: Result[T] = err[T](foreignError("root task did not complete"))
  let rootId = startTask(rtRef[], InvalidTaskId, body)
  let waiter: JoinWaiter = proc(rtPtr: ptr Runtime, res: AnyResult) =
    rootResult = fromAnyResult[T](res)
  addJoinWaiter(rtRef[], rootId, waiter)
  rtRef[].runLoop()
  let trace = rtRef[].traceEvents
  removeRuntime(rtRef)
  (result: rootResult, trace: trace)

proc pure*[T](v: T): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    when T is void:
      k(rt, okVoid())
    else:
      k(rt, ok(v))

proc fail*[T](e: RtError): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    k(rt, err[T](e))

template taskResultType*[T](t: Task[T]): typedesc[T] =
  T

template taskResultType*[T](t: typedesc[Task[T]]): typedesc[T] =
  T

proc andThen*[T, U](t: Task[T], f: proc (v: T): Task[U] {.gcsafe, closure.}): Task[U] =
  proc (rt: ptr Runtime, k: Cont[U]) =
    t(rt, proc(rtInner: ptr Runtime, res: Result[T]) =
      if res.isOk:
        when T is void:
          let next = f()
        else:
          let next = f(res.ok)
        next(rtInner, k)
      else:
        k(rtInner, err[U](res.err))
    )

proc ensure*[T](t: Task[T], fin: Task[Unit]): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    t(rt, proc(rtInner: ptr Runtime, res: Result[T]) =
      fin(rtInner, proc(rtFin: ptr Runtime, finRes: Result[Unit]) =
        if res.isOk:
          if finRes.isOk:
            k(rtFin, res)
          else:
            k(rtFin, err[T](finRes.err))
        else:
          k(rtFin, res)
      )
    )

proc whileTask*(cond: proc (): bool {.gcsafe, closure.}, t: Task[Unit]): Task[Unit] {.gcsafe.} =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    if cond():
      let next = andThen(t, proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        whileTask(cond, t)
      )
      next(rt, k)
    else:
      k(rt, ok(unit()))

proc yieldNow*(): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    let id = rt[].currentId
    markReady(rt[], id)
    enqueueCont(rt[], id, k, ok(unit()))

proc trace*(msg: string): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    rt[].traceEvents.add(msg)
    if rt[].traceHook != nil:
      rt[].traceHook(msg)
    enqueueCont(rt[], rt[].currentId, k, ok(unit()))

proc sleep*(d: Duration): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    let id = rt[].currentId
    markBlocked(rt[], id)
    let ms = max(0, int(d.inMilliseconds))
    let epoch = rt[].tasks[id].epoch
    let rtPtr = rt
    let fut = sleepAsync(ms)
    fut.addCallback(proc() =
      if not isRuntimeValid(rtPtr):
        return
      if not rtPtr[].tasks.hasKey(id):
        return
      let rec = rtPtr[].tasks[id]
      if rec.epoch != epoch or rec.cancelled:
        return
      enqueueCont(rtPtr[], id, k, ok(unit()))
    )

proc toDuration(d: TimeInterval): Duration =
  ## Convert fixed units; months/years are treated as days for v0.1.
  initDuration(
    nanoseconds = d.nanoseconds,
    microseconds = d.microseconds,
    milliseconds = d.milliseconds,
    seconds = d.seconds,
    minutes = d.minutes,
    hours = d.hours,
    days = d.days + d.weeks * 7 + d.months * 30 + d.years * 365
  )

proc sleep*(d: TimeInterval): Task[Unit] =
  sleep(toDuration(d))

proc awaitFuture*[T](f: Future[T]): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    let id = rt[].currentId
    markBlocked(rt[], id)
    let epoch = rt[].tasks[id].epoch
    let rtPtr = rt
    f.addCallback(proc() =
      if not isRuntimeValid(rtPtr):
        return
      if not rtPtr[].tasks.hasKey(id):
        return
      let rec = rtPtr[].tasks[id]
      if rec.epoch != epoch or rec.cancelled:
        return
      if f.failed:
        let msg = if f.error.isNil: "future failed" else: f.error.msg
        enqueueCont(rtPtr[], id, k, err[T](exceptionError(msg)))
      else:
        let value = f.read()
        enqueueCont(rtPtr[], id, k, ok(value))
    )

proc awaitIO*(fd: AsyncFD, interest: IoInterest): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    let id = rt[].currentId
    markBlocked(rt[], id)
    let epoch = rt[].tasks[id].epoch
    let rtPtr = rt
    let cb: Callback = proc(sock: AsyncFD): bool {.gcsafe.} =
      if not isRuntimeValid(rtPtr):
        return true
      if not rtPtr[].tasks.hasKey(id):
        return true
      let rec = rtPtr[].tasks[id]
      if rec.epoch != epoch or rec.cancelled:
        return true
      enqueueCont(rtPtr[], id, k, ok(unit()))
      return true
    try:
      let disp = getGlobalDispatcher()
      if not disp.contains(fd):
        register(fd)
      case interest
      of ioRead:
        addRead(fd, cb)
      of ioWrite:
        addWrite(fd, cb)
    except CatchableError:
      let msg = getCurrentExceptionMsg()
      enqueueCont(rtPtr[], id, k, err[Unit](exceptionError(msg)))

proc awaitIO*(ev: AsyncEvent): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    let id = rt[].currentId
    markBlocked(rt[], id)
    let epoch = rt[].tasks[id].epoch
    let rtPtr = rt
    let cb: Callback = proc(fd: AsyncFD): bool {.gcsafe.} =
      if not isRuntimeValid(rtPtr):
        return true
      if not rtPtr[].tasks.hasKey(id):
        return true
      let rec = rtPtr[].tasks[id]
      if rec.epoch != epoch or rec.cancelled:
        return true
      enqueueCont(rtPtr[], id, k, ok(unit()))
      return true
    try:
      addEvent(ev, cb)
    except CatchableError:
      let msg = getCurrentExceptionMsg()
      enqueueCont(rtPtr[], id, k, err[Unit](exceptionError(msg)))

proc spawn*[T](t: Task[T]): Task[TaskId] =
  proc (rt: ptr Runtime, k: Cont[TaskId]) =
    let id = startTask(rt[], rt[].currentId, t)
    enqueueCont(rt[], rt[].currentId, k, ok(id))

proc join*[T](id: TaskId): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    if not rt[].tasks.hasKey(id):
      enqueueCont(rt[], rt[].currentId, k, err[T](foreignError("unknown task")))
      return
    let callerId = rt[].currentId
    markBlocked(rt[], callerId)
    let waiter: JoinWaiter = proc(rtPtr: ptr Runtime, res: AnyResult) =
      let typedRes = fromAnyResult[T](res)
      enqueueCont(rtPtr[], callerId, k, typedRes)
    addJoinWaiter(rt[], id, waiter)

proc joinResult*[T](id: TaskId): Task[Result[T]] =
  proc (rt: ptr Runtime, k: Cont[Result[T]]) =
    if not rt[].tasks.hasKey(id):
      enqueueCont(rt[], rt[].currentId, k, ok(err[T](foreignError("unknown task"))))
      return
    let callerId = rt[].currentId
    markBlocked(rt[], callerId)
    let waiter: JoinWaiter = proc(rtPtr: ptr Runtime, res: AnyResult) =
      let typedRes = fromAnyResult[T](res)
      enqueueCont(rtPtr[], callerId, k, ok(typedRes))
    addJoinWaiter(rt[], id, waiter)

proc cancel*(id: TaskId): Task[Unit] =
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    cancelTask(rt[], id)
    enqueueCont(rt[], rt[].currentId, k, ok(unit()))

proc withTimeout*[T](d: Duration, t: Task[T]): Task[T] =
  proc (rt: ptr Runtime, k: Cont[T]) =
    let parent = rt[].currentId
    markBlocked(rt[], parent)
    let childId = startTask(rt[], parent, t)
    let timerId = startTask(rt[], parent, sleep(d))
    var done = false

    proc complete(res: Result[T]) {.gcsafe.} =
      if done:
        return
      done = true
      if res.isOk or res.err.kind != RtErrorKind.Timeout:
        cancelTask(rt[], timerId)
      if res.err.kind == RtErrorKind.Timeout:
        cancelTask(rt[], childId)
      enqueueCont(rt[], parent, k, res)

    addJoinWaiter(rt[], childId, proc(rtPtr: ptr Runtime, res: AnyResult) =
      complete(fromAnyResult[T](res))
    )

    addJoinWaiter(rt[], timerId, proc(rtPtr: ptr Runtime, res: AnyResult) =
      let timerRes = fromAnyResult[Unit](res)
      if timerRes.isOk:
        complete(err[T](timeoutError()))
      else:
        complete(err[T](timerRes.err))
    )

proc withTimeout*[T](d: TimeInterval, t: Task[T]): Task[T] =
  withTimeout(toDuration(d), t)

proc start*[T](t: Task[T]): TaskId =
  let rtRef = new(Runtime)
  rtRef[] = initRuntime()
  addRuntime(rtRef)
  let id = startTask(rtRef[], InvalidTaskId, t)
  rtRef[].runLoop()
  removeRuntime(rtRef)
  id

proc toFuture*[T](t: Task[T]): Future[T] =
  let fut = newFuture[T]("rteffects.toFuture")
  let res = runDefault(t)
  if res.isOk:
    fut.complete(res.ok)
  else:
    fut.fail(newException(ValueError, $res.err))
  fut

# =============================================================================
# Cancellation Check API
# =============================================================================

proc isCancelled*(): Task[bool] =
  ## Check if the current task has been cancelled
  proc (rt: ptr Runtime, k: Cont[bool]) =
    let id = rt[].currentId
    if not rt[].tasks.hasKey(id):
      k(rt, ok(false))
      return
    let rec = rt[].tasks[id]
    k(rt, ok(rec.cancelled))

proc checkCancelled*(): Task[Unit] =
  ## If cancelled, immediately return Cancelled error; otherwise continue
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    let id = rt[].currentId
    if not rt[].tasks.hasKey(id):
      k(rt, ok(unit()))
      return
    let rec = rt[].tasks[id]
    if rec.cancelled:
      k(rt, err[Unit](cancelledError()))
    else:
      k(rt, ok(unit()))

# =============================================================================
# Task Combinators
# =============================================================================

proc map*[T, U](t: Task[T], f: proc(v: T): U {.gcsafe, closure.}): Task[U] =
  ## Transform the success value of a task
  proc (rt: ptr Runtime, k: Cont[U]) =
    t(rt, proc(rtInner: ptr Runtime, res: Result[T]) =
      if res.isOk:
        when T is void:
          k(rtInner, ok(f()))
        else:
          k(rtInner, ok(f(res.ok)))
      else:
        k(rtInner, err[U](res.err))
    )

proc flatMap*[T, U](t: Task[T], f: proc(v: T): Task[U] {.gcsafe, closure.}): Task[U] =
  ## Alias for andThen
  andThen(t, f)

proc recover*[T](t: Task[T], handler: proc(e: RtError): Task[T] {.gcsafe, closure.}): Task[T] =
  ## Recover from errors by providing an alternative task
  proc (rt: ptr Runtime, k: Cont[T]) =
    t(rt, proc(rtInner: ptr Runtime, res: Result[T]) =
      if res.isOk:
        k(rtInner, res)
      else:
        let recovery = handler(res.err)
        recovery(rtInner, k)
    )

proc recoverWith*[T](t: Task[T], default: T): Task[T] =
  ## Recover from errors with a default value
  recover(t, proc(e: RtError): Task[T] {.gcsafe, closure.} = pure(default))

proc catchError*[T](t: Task[T], handler: proc(e: RtError): T {.gcsafe, closure.}): Task[T] =
  ## Catch errors and transform them to success values
  proc (rt: ptr Runtime, k: Cont[T]) =
    t(rt, proc(rtInner: ptr Runtime, res: Result[T]) =
      if res.isOk:
        k(rtInner, res)
      else:
        k(rtInner, ok(handler(res.err)))
    )

proc retry*[T](t: Task[T], maxAttempts: int, delay: Duration = initDuration()): Task[T] =
  ## Retry a task up to maxAttempts times with optional delay between retries
  proc (rt: ptr Runtime, k: Cont[T]) =
    var attempts = 0

    proc attempt(rtPtr: ptr Runtime) {.gcsafe.}

    proc onResult(rtInner: ptr Runtime, res: Result[T]) {.gcsafe.} =
      if res.isOk:
        k(rtInner, res)
      else:
        attempts.inc
        if attempts >= maxAttempts:
          k(rtInner, res)
        elif delay.inMilliseconds > 0:
          let sleepTask = sleep(delay)
          sleepTask(rtInner, proc(rtSleep: ptr Runtime, sleepRes: Result[Unit]) =
            if sleepRes.isOk:
              attempt(rtSleep)
            else:
              k(rtSleep, err[T](sleepRes.err))
          )
        else:
          attempt(rtInner)

    proc attempt(rtPtr: ptr Runtime) =
      t(rtPtr, onResult)

    attempt(rt)

proc retryWithBackoff*[T](t: Task[T], maxAttempts: int,
                          baseDelay: Duration = initDuration(milliseconds = 100),
                          maxDelay: Duration = initDuration(seconds = 10)): Task[T] =
  ## Retry with exponential backoff
  proc (rt: ptr Runtime, k: Cont[T]) =
    var attempts = 0

    proc attempt(rtPtr: ptr Runtime, currentDelay: Duration) {.gcsafe.}

    proc onResult(rtInner: ptr Runtime, res: Result[T], currentDelay: Duration) {.gcsafe.} =
      if res.isOk:
        k(rtInner, res)
      else:
        attempts.inc
        if attempts >= maxAttempts:
          k(rtInner, res)
        else:
          let nextDelay = min(currentDelay * 2, maxDelay)
          let sleepTask = sleep(currentDelay)
          sleepTask(rtInner, proc(rtSleep: ptr Runtime, sleepRes: Result[Unit]) =
            if sleepRes.isOk:
              attempt(rtSleep, nextDelay)
            else:
              k(rtSleep, err[T](sleepRes.err))
          )

    proc attempt(rtPtr: ptr Runtime, currentDelay: Duration) =
      t(rtPtr, proc(rtRes: ptr Runtime, res: Result[T]) =
        onResult(rtRes, res, currentDelay)
      )

    attempt(rt, baseDelay)

proc race*[T](tasks: seq[Task[T]]): Task[T] =
  ## Run multiple tasks concurrently, return the first one to complete
  proc (rt: ptr Runtime, k: Cont[T]) =
    if tasks.len == 0:
      k(rt, err[T](foreignError("race: empty task list")))
      return

    let parent = rt[].currentId
    markBlocked(rt[], parent)
    var done = false
    var childIds: seq[TaskId] = @[]

    proc complete(res: Result[T]) {.gcsafe.} =
      if done:
        return
      done = true
      # Cancel all other children
      for cid in childIds:
        cancelTask(rt[], cid)
      enqueueCont(rt[], parent, k, res)

    for task in tasks:
      let childId = startTask(rt[], parent, task)
      childIds.add(childId)
      addJoinWaiter(rt[], childId, proc(rtPtr: ptr Runtime, res: AnyResult) =
        complete(fromAnyResult[T](res))
      )

proc any*[T](tasks: seq[Task[T]]): Task[T] =
  ## Alias for race
  race(tasks)

proc all*[T](tasks: seq[Task[T]]): Task[seq[T]] =
  ## Run multiple tasks concurrently, collect all results
  proc (rt: ptr Runtime, k: Cont[seq[T]]) =
    if tasks.len == 0:
      k(rt, ok(newSeq[T]()))
      return

    let parent = rt[].currentId
    markBlocked(rt[], parent)
    let results = new(seq[Result[T]])
    results[] = newSeq[Result[T]](tasks.len)
    let completed = new(int)
    completed[] = 0
    let failed = new(bool)
    failed[] = false
    var childIds: seq[TaskId] = @[]

    proc makeWaiter(idx: int, childIds: seq[TaskId]): JoinWaiter =
      proc(rtPtr: ptr Runtime, res: AnyResult) =
        if failed[]:
          return
        results[idx] = fromAnyResult[T](res)
        completed[].inc
        if not results[idx].isOk:
          failed[] = true
          # Cancel remaining
          for cid in childIds:
            cancelTask(rtPtr[], cid)
          enqueueCont(rtPtr[], parent, k, err[seq[T]](results[idx].err))
        elif completed[] == tasks.len:
          var values: seq[T] = @[]
          for r in results[]:
            values.add(r.ok)
          enqueueCont(rtPtr[], parent, k, ok(values))

    for i, task in tasks:
      let childId = startTask(rt[], parent, task)
      childIds.add(childId)

    for i in 0..<tasks.len:
      addJoinWaiter(rt[], childIds[i], makeWaiter(i, childIds))

proc allSettled*[T](tasks: seq[Task[T]]): Task[seq[Result[T]]] =
  ## Run all tasks, collect all results (both success and failure)
  proc (rt: ptr Runtime, k: Cont[seq[Result[T]]]) =
    if tasks.len == 0:
      k(rt, ok(newSeq[Result[T]]()))
      return

    let parent = rt[].currentId
    markBlocked(rt[], parent)
    let results = new(seq[Result[T]])
    results[] = newSeq[Result[T]](tasks.len)
    let completed = new(int)
    completed[] = 0
    var childIds: seq[TaskId] = @[]

    proc makeWaiter(idx: int): JoinWaiter =
      proc(rtPtr: ptr Runtime, res: AnyResult) =
        results[idx] = fromAnyResult[T](res)
        completed[].inc
        if completed[] == tasks.len:
          enqueueCont(rtPtr[], parent, k, ok(results[]))

    for i, task in tasks:
      let childId = startTask(rt[], parent, task)
      childIds.add(childId)

    for i in 0..<tasks.len:
      addJoinWaiter(rt[], childIds[i], makeWaiter(i))

# =============================================================================
# Type-Safe Spawn/Join
# =============================================================================

proc spawnTyped*[T](t: Task[T]): Task[TypedTaskId[T]] =
  ## Spawn a task and return a type-safe task ID
  proc (rt: ptr Runtime, k: Cont[TypedTaskId[T]]) =
    let id = startTask(rt[], rt[].currentId, t)
    let tid = TypedTaskId[T](id: id)
    enqueueCont(rt[], rt[].currentId, k, ok(tid))

proc joinTyped*[T](tid: TypedTaskId[T]): Task[T] =
  ## Join a type-safe task ID
  join[T](tid.id)

proc joinTypedResult*[T](tid: TypedTaskId[T]): Task[Result[T]] =
  ## Join a type-safe task ID, returning Result
  joinResult[T](tid.id)

proc cancelTyped*[T](tid: TypedTaskId[T]): Task[Unit] =
  ## Cancel a type-safe task
  cancel(tid.id)

# =============================================================================
# Resource Management (Bracket Pattern)
# =============================================================================

proc bracket*[R, T](acquire: Task[R],
                    use: proc(r: R): Task[T] {.gcsafe, closure.},
                    release: proc(r: R): Task[Unit] {.gcsafe, closure.}): Task[T] =
  ## Safely acquire, use, and release a resource
  proc (rt: ptr Runtime, k: Cont[T]) =
    acquire(rt, proc(rtAcq: ptr Runtime, acqRes: Result[R]) =
      if not acqRes.isOk:
        k(rtAcq, err[T](acqRes.err))
        return

      let resource = acqRes.ok
      let useTask = use(resource)

      useTask(rtAcq, proc(rtUse: ptr Runtime, useRes: Result[T]) =
        let releaseTask = release(resource)
        releaseTask(rtUse, proc(rtRel: ptr Runtime, relRes: Result[Unit]) =
          if useRes.isOk:
            if relRes.isOk:
              k(rtRel, useRes)
            else:
              k(rtRel, err[T](relRes.err))
          else:
            # Use error takes precedence
            k(rtRel, useRes)
        )
      )
    )

proc bracketOnError*[R, T](acquire: Task[R],
                           use: proc(r: R): Task[T] {.gcsafe, closure.},
                           releaseOnError: proc(r: R): Task[Unit] {.gcsafe, closure.}): Task[T] =
  ## Bracket that only releases on error
  proc (rt: ptr Runtime, k: Cont[T]) =
    acquire(rt, proc(rtAcq: ptr Runtime, acqRes: Result[R]) =
      if not acqRes.isOk:
        k(rtAcq, err[T](acqRes.err))
        return

      let resource = acqRes.ok
      let useTask = use(resource)

      useTask(rtAcq, proc(rtUse: ptr Runtime, useRes: Result[T]) =
        if useRes.isOk:
          k(rtUse, useRes)
        else:
          let releaseTask = releaseOnError(resource)
          releaseTask(rtUse, proc(rtRel: ptr Runtime, relRes: Result[Unit]) =
            k(rtRel, useRes)
          )
      )
    )

# =============================================================================
# Channel (Inter-task Communication)
# =============================================================================

proc newTaskChannel*[T](capacity: int = 0): TaskChannel[T] =
  ## Create a new task channel. capacity=0 means unbounded
  new(result)
  result.buffer = @[]
  result.capacity = capacity
  result.closed = false
  result.sendWaiters = @[]
  result.recvWaiters = @[]

proc send*[T](ch: TaskChannel[T], value: T): Task[Unit] =
  ## Send a value to the channel
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    if ch.closed:
      k(rt, err[Unit](foreignError("channel closed")))
      return

    # If there are waiting receivers, deliver directly
    if ch.recvWaiters.len > 0:
      let waiter = ch.recvWaiters[0]
      ch.recvWaiters.delete(0)
      let rtPtr = rt
      rt[].readyQ.addLast(proc() =
        waiter(rtPtr, value, true)
      )
      k(rt, ok(unit()))
      return

    # If unbounded or under capacity, buffer it
    if ch.capacity == 0 or ch.buffer.len < ch.capacity:
      ch.buffer.add(value)
      k(rt, ok(unit()))
      return

    # Need to wait for space
    let id = rt[].currentId
    markBlocked(rt[], id)
    ch.sendWaiters.add(proc(rtWake: ptr Runtime) =
      ch.buffer.add(value)
      enqueueCont(rtWake[], id, k, ok(unit()))
    )

proc recv*[T](ch: TaskChannel[T]): Task[T] =
  ## Receive a value from the channel
  proc (rt: ptr Runtime, k: Cont[T]) =
    # If there's buffered data
    if ch.buffer.len > 0:
      let value = ch.buffer[0]
      ch.buffer.delete(0)
      # Wake up a sender if waiting
      if ch.sendWaiters.len > 0:
        let waiter = ch.sendWaiters[0]
        ch.sendWaiters.delete(0)
        let rtPtr = rt
        rt[].readyQ.addLast(proc() =
          waiter(rtPtr)
        )
      k(rt, ok(value))
      return

    if ch.closed:
      k(rt, err[T](foreignError("channel closed")))
      return

    # Wait for a value
    let id = rt[].currentId
    markBlocked(rt[], id)
    ch.recvWaiters.add(proc(rtWake: ptr Runtime, value: T, success: bool) =
      if success:
        enqueueCont(rtWake[], id, k, ok(value))
      else:
        enqueueCont(rtWake[], id, k, err[T](foreignError("channel closed")))
    )

proc tryRecv*[T](ch: TaskChannel[T]): Task[Result[T]] =
  ## Try to receive without blocking, returns Result
  proc (rt: ptr Runtime, k: Cont[Result[T]]) =
    if ch.buffer.len > 0:
      let value = ch.buffer[0]
      ch.buffer.delete(0)
      if ch.sendWaiters.len > 0:
        let waiter = ch.sendWaiters[0]
        ch.sendWaiters.delete(0)
        let rtPtr = rt
        rt[].readyQ.addLast(proc() =
          waiter(rtPtr)
        )
      k(rt, ok(ok(value)))
    elif ch.closed:
      k(rt, ok(err[T](foreignError("channel closed"))))
    else:
      k(rt, ok(err[T](foreignError("channel empty"))))

proc closeChannel*[T](ch: TaskChannel[T]): Task[Unit] =
  ## Close the channel
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    ch.closed = true
    # Wake all waiting receivers with error
    for waiter in ch.recvWaiters:
      let w = waiter
      let rtPtr = rt
      var dummy: T
      rt[].readyQ.addLast(proc() =
        w(rtPtr, dummy, false)
      )
    ch.recvWaiters = @[]
    k(rt, ok(unit()))

proc isClosed*[T](ch: TaskChannel[T]): bool =
  ch.closed

# =============================================================================
# Semaphore
# =============================================================================

proc newSemaphore*(count: int): Semaphore =
  ## Create a new semaphore with initial count
  new(result)
  result.count = count
  result.maxCount = count
  result.waiters = @[]

proc acquire*(sem: Semaphore): Task[Unit] =
  ## Acquire the semaphore (decrement count)
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    if sem.count > 0:
      sem.count.dec
      k(rt, ok(unit()))
    else:
      let id = rt[].currentId
      markBlocked(rt[], id)
      sem.waiters.add(proc(rtWake: ptr Runtime) =
        sem.count.dec
        enqueueCont(rtWake[], id, k, ok(unit()))
      )

proc release*(sem: Semaphore): Task[Unit] =
  ## Release the semaphore (increment count)
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    sem.count.inc
    if sem.waiters.len > 0:
      let waiter = sem.waiters[0]
      sem.waiters.delete(0)
      let rtPtr = rt
      rt[].readyQ.addLast(proc() =
        waiter(rtPtr)
      )
    k(rt, ok(unit()))

proc tryAcquire*(sem: Semaphore): Task[bool] =
  ## Try to acquire without blocking
  proc (rt: ptr Runtime, k: Cont[bool]) =
    if sem.count > 0:
      sem.count.dec
      k(rt, ok(true))
    else:
      k(rt, ok(false))

proc withSemaphore*[T](sem: Semaphore, body: Task[T]): Task[T] =
  ## Execute body while holding the semaphore
  bracket(
    acquire(sem),
    proc(_: Unit): Task[T] {.gcsafe, closure.} = body,
    proc(_: Unit): Task[Unit] {.gcsafe, closure.} = release(sem)
  )

# =============================================================================
# Mutex
# =============================================================================

proc newMutex*(): Mutex =
  ## Create a new mutex
  new(result)
  result.locked = false
  result.waiters = @[]

proc lock*(m: Mutex): Task[Unit] =
  ## Acquire the mutex
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    if not m.locked:
      m.locked = true
      k(rt, ok(unit()))
    else:
      let id = rt[].currentId
      markBlocked(rt[], id)
      m.waiters.add(proc(rtWake: ptr Runtime) =
        m.locked = true
        enqueueCont(rtWake[], id, k, ok(unit()))
      )

proc unlock*(m: Mutex): Task[Unit] =
  ## Release the mutex
  proc (rt: ptr Runtime, k: Cont[Unit]) =
    if m.waiters.len > 0:
      let waiter = m.waiters[0]
      m.waiters.delete(0)
      let rtPtr = rt
      rt[].readyQ.addLast(proc() =
        waiter(rtPtr)
      )
    else:
      m.locked = false
    k(rt, ok(unit()))

proc tryLock*(m: Mutex): Task[bool] =
  ## Try to acquire without blocking
  proc (rt: ptr Runtime, k: Cont[bool]) =
    if not m.locked:
      m.locked = true
      k(rt, ok(true))
    else:
      k(rt, ok(false))

proc withLock*[T](m: Mutex, body: Task[T]): Task[T] =
  ## Execute body while holding the mutex
  bracket(
    lock(m),
    proc(_: Unit): Task[T] {.gcsafe, closure.} = body,
    proc(_: Unit): Task[Unit] {.gcsafe, closure.} = release(newSemaphore(1))
  )

proc withMutex*[T](m: Mutex, body: Task[T]): Task[T] =
  ## Execute body while holding the mutex (corrected version)
  bracket(
    lock(m),
    proc(_: Unit): Task[T] {.gcsafe, closure.} = body,
    proc(_: Unit): Task[Unit] {.gcsafe, closure.} = unlock(m)
  )

# =============================================================================
# Iteration helpers
# =============================================================================

proc forEachTask*[T](items: seq[T], body: proc(item: T): Task[Unit] {.gcsafe, closure.}): Task[Unit] =
  ## Sequential iteration over items
  proc loop(idx: int): Task[Unit] {.gcsafe.} =
    if idx >= items.len:
      pure(unit())
    else:
      andThen(body(items[idx]), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        loop(idx + 1)
      )
  loop(0)

proc forEachParallel*[T](items: seq[T], body: proc(item: T): Task[Unit] {.gcsafe, closure.}): Task[Unit] =
  ## Parallel iteration over items
  if items.len == 0:
    return pure(unit())

  var tasks: seq[Task[Unit]] = @[]
  for item in items:
    let i = item
    tasks.add(body(i))

  map(all(tasks), proc(_: seq[Unit]): Unit {.gcsafe, closure.} = unit())

proc mapTask*[T, U](items: seq[T], f: proc(item: T): Task[U] {.gcsafe, closure.}): Task[seq[U]] =
  ## Map over items with a task-returning function
  var tasks: seq[Task[U]] = @[]
  for item in items:
    let i = item
    tasks.add(f(i))
  all(tasks)

proc filterTask*[T](items: seq[T], pred: proc(item: T): Task[bool] {.gcsafe, closure.}): Task[seq[T]] =
  ## Filter items with a task-returning predicate
  proc loop(idx: int, acc: seq[T]): Task[seq[T]] {.gcsafe.} =
    if idx >= items.len:
      pure(acc)
    else:
      let item = items[idx]
      andThen(pred(item), proc(keep: bool): Task[seq[T]] {.gcsafe, closure.} =
        var newAcc = acc
        if keep:
          newAcc.add(item)
        loop(idx + 1, newAcc)
      )
  loop(0, @[])

when defined(rteffectsTesting):
  proc testHookMarkMissing*() =
    var rt = initRuntime()
    markReady(rt, TaskId(9999))
    markBlocked(rt, TaskId(9999))

  proc testHookFinishMissing*() =
    var rt = initRuntime()
    finishTaskAny(rt, TaskId(1234), anyErr(foreignError("missing")))

  proc testHookFinishDone*() =
    var rt = initRuntime()
    let id = TaskId(1)
    rt.tasks[id] = TaskRecord(
      id: id,
      parent: InvalidTaskId,
      state: tsDone,
      waiting: @[],
      cancelled: false,
      epoch: 0,
      result: nil
    )
    finishTaskAny(rt, id, anyErr(foreignError("done")))

  proc testHookAddJoinWaiterMissing*() =
    var rt = initRuntime()
    addJoinWaiter(rt, TaskId(404), proc(rtPtr: ptr Runtime, res: AnyResult) = discard)

  proc testHookAddJoinWaiterDone*() =
    var rt = initRuntime()
    let id = TaskId(2)
    rt.tasks[id] = TaskRecord(
      id: id,
      parent: InvalidTaskId,
      state: tsDone,
      waiting: @[],
      cancelled: false,
      epoch: 0,
      result: toAnyResult(ok(1))
    )
    addJoinWaiter(rt, id, proc(rtPtr: ptr Runtime, res: AnyResult) = discard)
    if rt.readyQ.len > 0:
      let job = rt.readyQ.popFirst()
      job()

  proc testHookEnqueueMissing*() =
    var rt = initRuntime()
    enqueueCont(rt, TaskId(5678), proc(rtPtr: ptr Runtime, res: Result[int]) = discard, ok(1))

  proc testHookEnqueueCancelled*() =
    var rt = initRuntime()
    let id = TaskId(3)
    rt.tasks[id] = TaskRecord(
      id: id,
      parent: InvalidTaskId,
      state: tsReady,
      waiting: @[],
      cancelled: true,
      epoch: 0,
      result: nil
    )
    enqueueCont(rt, id, proc(rtPtr: ptr Runtime, res: Result[int]) = discard, ok(1))

  proc testHookCancelMissingAndDone*() =
    var rt = initRuntime()
    cancelTask(rt, TaskId(8888))
    let id = TaskId(4)
    rt.tasks[id] = TaskRecord(
      id: id,
      parent: InvalidTaskId,
      state: tsDone,
      waiting: @[],
      cancelled: false,
      epoch: 0,
      result: nil
    )
    cancelTask(rt, id)
