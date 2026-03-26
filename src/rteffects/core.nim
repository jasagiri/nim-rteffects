import std/[hashes, options]

type
  TaskId* = distinct int
  Unit* = object
  IoInterest* = enum
    ioRead,
    ioWrite

type
  RtErrorKind* = enum
    Timeout,
    Cancelled,
    ExceptionRaised,
    ForeignError,
    ValidationIssue, ## A single schema validation error
    AggregateError,  ## Multiple errors collected
    Contradiction,   ## Belnap tvBoth collapsed to 2-valued
    Incomplete       ## Belnap tvNeither collapsed to 2-valued

  ValidationIssueDetail* = object
    field*: string
    rule*: string
    value*: string    ## String representation of the invalid value
    message*: string

  RtError* = object
    kind*: RtErrorKind
    msg*: string
    cause*: ref RtError       ## Optional cause for error chaining
    stackTrace*: string       ## Optional stack trace
    children*: seq[RtError]   ## For AggregateError
    issue*: Option[ValidationIssueDetail] ## Detailed info for ValidationIssue

  Result*[T] = object
    isOk*: bool
    ok*: T
    err*: RtError

  ## Type-safe task handle that preserves the result type
  TypedTaskId*[T] = object
    id*: TaskId

const InvalidTaskId* = TaskId(-1)

proc hash*(id: TaskId): Hash {.borrow.}
proc `==`*(a, b: TaskId): bool {.borrow.}

proc `==`*[T](a, b: TypedTaskId[T]): bool =
  a.id == b.id

proc hash*[T](id: TypedTaskId[T]): Hash =
  hash(id.id)

proc toTaskId*[T](tid: TypedTaskId[T]): TaskId =
  tid.id

proc invalidTypedTaskId*[T](): TypedTaskId[T] =
  TypedTaskId[T](id: InvalidTaskId)

proc ok*[T](v: T): Result[T] =
  when T is void:
    Result[void](isOk: true)
  else:
    Result[T](isOk: true, ok: v)

proc okVoid*(): Result[void] =
  Result[void](isOk: true)

proc unit*(): Unit =
  Unit()

proc err*[T](e: RtError): Result[T] =
  Result[T](isOk: false, err: e)

proc cancelledError*(): RtError =
  RtError(kind: RtErrorKind.Cancelled, msg: "cancelled")

proc timeoutError*(): RtError =
  RtError(kind: RtErrorKind.Timeout, msg: "timeout")

proc exceptionError*(msg: string): RtError =
  RtError(kind: RtErrorKind.ExceptionRaised, msg: msg)

proc exceptionError*(ex: ref Exception): RtError =
  if ex.isNil:
    return exceptionError("exception raised")
  var e = exceptionError(ex.msg)
  e.stackTrace = ex.getStackTrace()
  e

proc foreignError*(msg: string): RtError =
  RtError(kind: RtErrorKind.ForeignError, msg: msg)

proc validationError*(field, rule, value, msg: string): RtError =
  RtError(
    kind: RtErrorKind.ValidationIssue,
    msg: field & ": " & msg,
    issue: some(ValidationIssueDetail(
      field: field,
      rule: rule,
      value: value,
      message: msg
    ))
  )

proc aggregateError*(errors: seq[RtError]): RtError =
  var msg = "multiple errors occurred"
  if errors.len > 0:
    msg = msg & ": " & $errors.len & " error(s)"
  RtError(kind: RtErrorKind.AggregateError, msg: msg, children: errors)

proc withCause*(e: RtError, cause: RtError): RtError =
  ## Create a new error with a cause chain
  result = e
  result.cause = new(RtError)
  result.cause[] = cause

proc rootCause*(e: RtError): RtError =
  ## Get the root cause of an error chain
  result = e
  while result.cause != nil:
    result = result.cause[]

proc `$`*(e: RtError): string =
  result = $e.kind & ": " & e.msg
  if e.cause != nil:
    result.add("\n  caused by: " & $e.cause[])
  if e.children.len > 0:
    result.add("\n  contains:")
    for child in e.children:
      result.add("\n    - " & $child)
