import std/macros
import ./core
import ./runtime

template await*[T](t: Task[T]): T =
  {.error: "await can only be used inside .rt. procs".}

template perform*[T](t: Task[T]): T =
  {.error: "perform can only be used inside .rt. procs".}

proc awaitArg(n: NimNode): NimNode =
  if n.kind in {nnkCall, nnkCommand}:
    let head = n[0]
    if head.kind == nnkIdent and head.strVal in ["await", "perform"]:
      if n.len >= 2:
        return n[1]
  return nil

proc hasAwait(n: NimNode): bool =
  ## Check if a node contains await/perform calls
  if awaitArg(n) != nil:
    return true
  for child in n:
    if hasAwait(child):
      return true
  return false

proc tail(stmts: seq[NimNode]): seq[NimNode] =
  if stmts.len <= 1:
    return @[]
  stmts[1 .. ^1]

proc buildTask(stmts: seq[NimNode]): NimNode

proc buildIf(stmt: NimNode, restStmts: seq[NimNode]): NimNode =
  var ifNode = newNimNode(nnkIfExpr)
  var hasElse = false
  for branch in stmt:
    case branch.kind
    of nnkElifBranch:
      let cond = branch[0]
      let bodyList = branch[1]
      var stmts: seq[NimNode] = @[]
      for child in bodyList:
        stmts.add(child)
      for child in restStmts:
        stmts.add(child)
      let bodyTask = buildTask(stmts)
      ifNode.add(newTree(nnkElifExpr, cond, newStmtList(bodyTask)))
    of nnkElse:
      let bodyList = branch[0]
      var stmts: seq[NimNode] = @[]
      for child in bodyList:
        stmts.add(child)
      for child in restStmts:
        stmts.add(child)
      let bodyTask = buildTask(stmts)
      ifNode.add(newTree(nnkElseExpr, newStmtList(bodyTask)))
      hasElse = true
    else:
      discard
  if not hasElse:
    let bodyTask = buildTask(restStmts)
    ifNode.add(newTree(nnkElseExpr, newStmtList(bodyTask)))
  ifNode

proc buildTask(stmts: seq[NimNode]): NimNode =
  if stmts.len == 0:
    return quote do:
      pure(unit())

  let stmt = stmts[0]

  if stmt.kind == nnkReturnStmt:
    if stmt.len == 0:
      return quote do:
        pure(unit())
    let awaited = awaitArg(stmt[0])
    if awaited != nil:
      return awaited
    return newCall(ident("pure"), stmt[0])

  if stmt.kind in {nnkLetSection, nnkVarSection}:
    if stmt.len > 1:
      var expanded: seq[NimNode] = @[]
      for def in stmt:
        var section = newNimNode(stmt.kind)
        section.add(def)
        expanded.add(section)
      for i in 1 ..< stmts.len:
        expanded.add(stmts[i])
      return buildTask(expanded)

    let def = stmt[0]
    let name = def[0]
    let value = def[^1]
    let awaited = awaitArg(value)
    if awaited != nil:
      let rest = buildTask(tail(stmts))
      let lam = quote do:
        proc(`name`: taskResultType(`awaited`)): typeof(`rest`) {.gcsafe, closure.} =
          `rest`
      return newCall(ident("andThen"), awaited, lam)

  if stmt.kind == nnkDiscardStmt:
    let awaited = awaitArg(stmt[0])
    if awaited != nil:
      let rest = buildTask(tail(stmts))
      let lam = quote do:
        proc(_: taskResultType(`awaited`)): typeof(`rest`) {.gcsafe, closure.} =
          `rest`
      return newCall(ident("andThen"), awaited, lam)

  if stmt.kind == nnkIfStmt:
    return buildIf(stmt, tail(stmts))

  if stmt.kind == nnkWhileStmt:
    let cond = stmt[0]
    let body = stmt[1]
    var bodyStmts: seq[NimNode] = @[]
    for child in body:
      bodyStmts.add(child)
    let bodyTask = buildTask(bodyStmts)
    let rest = buildTask(tail(stmts))
    return quote do:
      andThen(whileTask(proc(): bool {.gcsafe, closure.} = `cond`, `bodyTask`),
        proc(_: Unit): typeof(`rest`) {.gcsafe, closure.} = `rest`)

  # Handle for loops with range (e.g., for i in 0..10)
  if stmt.kind == nnkForStmt:
    let loopVar = stmt[0]
    let iterExpr = stmt[1]
    let body = stmt[2]

    # Check if the body contains await/perform
    if not hasAwait(body):
      # No await in body, keep as regular for loop
      let rest = buildTask(tail(stmts))
      return newTree(nnkBlockStmt, newEmptyNode(), newStmtList(stmt, rest))

    var bodyStmts: seq[NimNode] = @[]
    for child in body:
      bodyStmts.add(child)
    let bodyTask = buildTask(bodyStmts)
    let rest = buildTask(tail(stmts))

    # Generate code that converts the iterable to a seq and uses forEachTask
    return quote do:
      block:
        var items: seq[typeof(block:
          var dummy: typeof(`iterExpr`.items())
          dummy)] = @[]
        for item in `iterExpr`:
          items.add(item)
        andThen(forEachTask(items, proc(`loopVar`: typeof(items[0])): Task[Unit] {.gcsafe, closure.} =
          `bodyTask`
        ), proc(_: Unit): typeof(`rest`) {.gcsafe, closure.} = `rest`)

  if stmt.kind == nnkRaiseStmt:
    if stmt.len == 0:
      return quote do:
        fail[taskResultType(typeof(result))](exceptionError("exception raised"))
    let exSym = genSym(nskLet, "ex")
    let exExpr = stmt[0]
    return quote do:
      block:
        let `exSym` = `exExpr`
        fail[taskResultType(typeof(result))](exceptionError(`exSym`))

  let awaited = awaitArg(stmt)
  if awaited != nil:
    let rest = buildTask(tail(stmts))
    let lam = quote do:
      proc(_: taskResultType(`awaited`)): typeof(`rest`) {.gcsafe, closure.} =
        `rest`
    return newCall(ident("andThen"), awaited, lam)

  let rest = buildTask(tail(stmts))
  result = newTree(nnkBlockStmt, newEmptyNode(), newStmtList(stmt, rest))

macro rt*(p: untyped): untyped =
  if p.kind notin {nnkProcDef, nnkFuncDef}:
    return p
  let body = p[^1]
  if body.kind != nnkStmtList:
    return p

  var stmts: seq[NimNode] = @[]
  var defers: seq[NimNode] = @[]
  for child in body:
    if child.kind == nnkDefer:
      defers.add(child[0])
    else:
      stmts.add(child)

  let taskExpr = buildTask(stmts)
  var wrapped = taskExpr
  if defers.len > 0:
    for i in countdown(defers.len - 1, 0):
      var deferStmts: seq[NimNode] = @[]
      for dstmt in defers[i]:
        deferStmts.add(dstmt)
      let deferTask = buildTask(deferStmts)
      wrapped = newCall(ident("ensure"), wrapped, deferTask)
  let newBody = newStmtList(quote do:
    result = `wrapped`
  )
  result = p
  result[^1] = newBody
