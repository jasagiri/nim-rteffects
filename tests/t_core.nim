import std/[unittest, hashes, strutils]
import rteffects/core

suite "TaskId":
  test "given TaskId when hashed then consistent":
    check hash(TaskId(0)) == hash(0)
    check hash(TaskId(42)) == hash(42)

  test "given TaskId when compared then distinct int semantics hold":
    check TaskId(1) == TaskId(1)
    check TaskId(1) != TaskId(2)

suite "InvalidTaskId":
  test "given InvalidTaskId then it is TaskId(-1)":
    check InvalidTaskId == TaskId(-1)

suite "TypedTaskId":
  test "given same TypedTaskIds when compared then equal":
    let a = TypedTaskId[int](id: TaskId(1))
    let b = TypedTaskId[int](id: TaskId(1))
    check a == b

  test "given different TypedTaskIds when compared then not equal":
    let a = TypedTaskId[int](id: TaskId(1))
    let b = TypedTaskId[int](id: TaskId(2))
    check not (a == b)

  test "given TypedTaskId when hashed then consistent with inner id":
    let tid = TypedTaskId[int](id: TaskId(42))
    check hash(tid) == hash(TaskId(42))

  test "given TypedTaskId when toTaskId then extracts inner id":
    let tid = TypedTaskId[string](id: TaskId(7))
    check toTaskId(tid) == TaskId(7)

  test "given invalidTypedTaskId then inner id is InvalidTaskId":
    let tid = invalidTypedTaskId[int]()
    check tid.id == InvalidTaskId

suite "Unit":
  test "given unit when created then it is a Unit object":
    let u = unit()
    check u is Unit

suite "Result[T]":
  test "given ok with int value then isOk and value accessible":
    let r = ok(42)
    check r.isOk
    check r.ok == 42

  test "given ok with void then isOk":
    let r = okVoid()
    check r.isOk

  test "given err then not isOk and error accessible":
    let r = err[int](RtError(kind: Timeout, msg: "t"))
    check not r.isOk
    check r.err.kind == Timeout

suite "IoInterest":
  test "given IoInterest enum then values are defined":
    check ioRead != ioWrite
    check ord(ioRead) == 0
    check ord(ioWrite) == 1

suite "RtError constructors":
  test "given cancelledError then kind is Cancelled":
    let e = cancelledError()
    check e.kind == Cancelled
    check e.msg == "cancelled"

  test "given timeoutError then kind is Timeout":
    let e = timeoutError()
    check e.kind == Timeout
    check e.msg == "timeout"

  test "given exceptionError with string then kind is ExceptionRaised":
    let e = exceptionError("boom")
    check e.kind == ExceptionRaised
    check e.msg == "boom"

  test "given exceptionError with nil ref then fallback message":
    var nilEx: ref Exception = nil
    let e = exceptionError(nilEx)
    check e.kind == ExceptionRaised
    check e.msg == "exception raised"

  test "given exceptionError with real exception then captures stackTrace":
    try:
      raise newException(ValueError, "test boom")
    except ValueError as ex:
      let e = exceptionError(ex)
      check e.kind == ExceptionRaised
      check e.msg == "test boom"
      check e.stackTrace.len > 0

  test "given foreignError then kind is ForeignError":
    let e = foreignError("oops")
    check e.kind == ForeignError
    check e.msg == "oops"

suite "aggregateError":
  test "given non-empty errors then kind is AggregateError with children":
    let errors = @[foreignError("a"), foreignError("b")]
    let e = aggregateError(errors)
    check e.kind == AggregateError
    check e.children.len == 2
    check e.msg.contains("2 error(s)")

  test "given empty errors then kind is AggregateError with no children":
    let e = aggregateError(@[])
    check e.kind == AggregateError
    check e.children.len == 0
    check e.msg.contains("multiple errors occurred")
    check not e.msg.contains("error(s)")

suite "Error chaining":
  test "given withCause then cause is set":
    let inner = foreignError("inner")
    let outer = foreignError("outer").withCause(inner)
    check outer.cause != nil
    check outer.cause[].msg == "inner"
    check outer.cause[].kind == ForeignError

  test "given rootCause with chain then finds deepest cause":
    let e1 = foreignError("root")
    let e2 = foreignError("mid").withCause(e1)
    let e3 = foreignError("top").withCause(e2)
    let root = rootCause(e3)
    check root.msg == "root"

  test "given rootCause with no chain then returns self":
    let e = foreignError("single")
    check rootCause(e).msg == "single"

suite "RtError $ formatting":
  test "given simple error then formatted as kind and msg":
    let e = foreignError("oops")
    check $e == "ForeignError: oops"

  test "given error with cause then includes caused by":
    let inner = timeoutError()
    let outer = foreignError("wrap").withCause(inner)
    let s = $outer
    check s.contains("ForeignError: wrap")
    check s.contains("caused by:")
    check s.contains("Timeout: timeout")

  test "given aggregate error with children then includes contains":
    let e = aggregateError(@[foreignError("a"), cancelledError()])
    let s = $e
    check s.contains("contains:")
    check s.contains("ForeignError: a")
    check s.contains("Cancelled: cancelled")

  test "given all RtErrorKind values then $ works":
    for kind in RtErrorKind:
      let e = RtError(kind: kind, msg: "test")
      check ($e).len > 0
