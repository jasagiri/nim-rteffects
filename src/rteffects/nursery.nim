import ./runtime
import ./core

type
  NurseryPolicy* = enum
    npFailFast,
    npCollectAll,
    npSupervise

  Nursery* = ref object
    children: seq[TaskId]
    policy: NurseryPolicy
    errors: seq[RtError]

  ## Type-safe nursery that collects results
  TypedNursery*[T] = ref object
    children: seq[TaskId]
    policy: NurseryPolicy
    errors: seq[RtError]
    results: seq[Result[T]]

proc newNursery*(policy = npFailFast): Nursery =
  new(result)
  result.children = @[]
  result.policy = policy
  result.errors = @[]

proc newTypedNursery*[T](policy = npFailFast): TypedNursery[T] =
  new(result)
  result.children = @[]
  result.policy = policy
  result.errors = @[]
  result.results = @[]

proc errors*(n: Nursery): seq[RtError] =
  n.errors

proc errors*[T](n: TypedNursery[T]): seq[RtError] =
  n.errors

proc results*[T](n: TypedNursery[T]): seq[Result[T]] =
  n.results

proc successResults*[T](n: TypedNursery[T]): seq[T] =
  ## Get only successful results
  result = @[]
  for r in n.results:
    if r.isOk:
      result.add(r.ok)

proc spawnChild*(n: Nursery, t: Task[Unit]): Task[TaskId] =
  proc (rt: ptr Runtime, k: Cont[TaskId]) =
    let start = spawn(t)
    start(rt, proc(rtInner: ptr Runtime, res: Result[TaskId]) =
      if res.isOk:
        n.children.add(res.ok)
      k(rtInner, res)
    )

proc spawnChild*[T](n: TypedNursery[T], t: Task[T]): Task[TaskId] =
  ## Spawn a child task that returns a value
  proc (rt: ptr Runtime, k: Cont[TaskId]) =
    let start = spawn(t)
    start(rt, proc(rtInner: ptr Runtime, res: Result[TaskId]) =
      if res.isOk:
        n.children.add(res.ok)
      k(rtInner, res)
    )

proc cancelFrom(n: Nursery, idx: int): Task[Unit] {.gcsafe.} =
  if idx >= n.children.len:
    pure(unit())
  else:
    andThen(cancel(n.children[idx]), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
      cancelFrom(n, idx + 1)
    )

proc cancelFromTyped[T](n: TypedNursery[T], idx: int): Task[Unit] {.gcsafe.} =
  if idx >= n.children.len:
    pure(unit())
  else:
    andThen(cancel(n.children[idx]), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
      cancelFromTyped(n, idx + 1)
    )

proc joinFrom(n: Nursery, idx: int): Task[Unit] {.gcsafe.} =
  if idx >= n.children.len:
    n.children.setLen(0)
    if n.policy == npCollectAll and n.errors.len > 0:
      var msg = "collectAll:"
      for err in n.errors:
        msg.add(" " & $err)
      return fail[Unit](foreignError(msg))
    pure(unit())
  else:
    andThen(joinResult[Unit](n.children[idx]),
      proc(res: Result[Unit]): Task[Unit] {.gcsafe, closure.} =
        if not res.isOk:
          case n.policy
          of npFailFast:
            andThen(cancelFrom(n, idx + 1),
              proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
                fail[Unit](res.err)
            )
          of npCollectAll:
            n.errors.add(res.err)
            joinFrom(n, idx + 1)
          of npSupervise:
            n.errors.add(res.err)
            joinFrom(n, idx + 1)
        else:
          joinFrom(n, idx + 1)
    )

proc joinFromTyped[T](n: TypedNursery[T], idx: int): Task[Unit] {.gcsafe.} =
  if idx >= n.children.len:
    n.children.setLen(0)
    if n.policy == npCollectAll and n.errors.len > 0:
      return fail[Unit](aggregateError(n.errors))
    pure(unit())
  else:
    andThen(joinResult[T](n.children[idx]),
      proc(res: Result[T]): Task[Unit] {.gcsafe, closure.} =
        n.results.add(res)
        if not res.isOk:
          case n.policy
          of npFailFast:
            andThen(cancelFromTyped(n, idx + 1),
              proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
                fail[Unit](res.err)
            )
          of npCollectAll:
            n.errors.add(res.err)
            joinFromTyped(n, idx + 1)
          of npSupervise:
            n.errors.add(res.err)
            joinFromTyped(n, idx + 1)
        else:
          joinFromTyped(n, idx + 1)
    )

proc joinAll*(n: Nursery): Task[Unit] =
  joinFrom(n, 0)

proc joinAll*[T](n: TypedNursery[T]): Task[Unit] =
  ## Join all children and collect their results
  joinFromTyped(n, 0)

proc joinAllResults*[T](n: TypedNursery[T]): Task[seq[Result[T]]] =
  ## Join all children and return collected results
  andThen(joinFromTyped(n, 0), proc(_: Unit): Task[seq[Result[T]]] {.gcsafe, closure.} =
    pure(n.results)
  )

proc joinAllValues*[T](n: TypedNursery[T]): Task[seq[T]] =
  ## Join all children and return only successful values (fails if any child fails)
  andThen(joinFromTyped(n, 0), proc(_: Unit): Task[seq[T]] {.gcsafe, closure.} =
    var values: seq[T] = @[]
    for r in n.results:
      if r.isOk:
        values.add(r.ok)
      else:
        return fail[seq[T]](r.err)
    pure(values)
  )

proc nursery*(body: proc (n: Nursery): Task[Unit], policy = npFailFast): Task[Unit] =
  let n = newNursery(policy)
  andThen(body(n), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
    joinAll(n)
  )

proc typedNursery*[T](body: proc (n: TypedNursery[T]): Task[Unit], policy = npFailFast): Task[seq[T]] =
  ## Create a typed nursery scope and return collected successful results
  let n = newTypedNursery[T](policy)
  andThen(body(n), proc(_: Unit): Task[seq[T]] {.gcsafe, closure.} =
    andThen(joinAll(n), proc(_: Unit): Task[seq[T]] {.gcsafe, closure.} =
      pure(n.successResults())
    )
  )

proc typedNurseryAll*[T](body: proc (n: TypedNursery[T]): Task[Unit], policy = npFailFast): Task[seq[Result[T]]] =
  ## Create a typed nursery scope and return all results (including failures)
  let n = newTypedNursery[T](policy)
  andThen(body(n), proc(_: Unit): Task[seq[Result[T]]] {.gcsafe, closure.} =
    joinAllResults(n)
  )
