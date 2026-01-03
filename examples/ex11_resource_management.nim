## Example 11: Resource Management
##
## Demonstrates safe resource handling with bracket patterns.

import std/[times, strformat]
import rteffects

# Simulated resource
type
  Connection = ref object
    id: int
    open: bool

var connectionIdCounter = 0
var activeConnections = 0

proc openConnection(): Connection =
  connectionIdCounter.inc
  activeConnections.inc
  result = Connection(id: connectionIdCounter, open: true)
  echo fmt"Connection {result.id} opened (active: {activeConnections})"

proc closeConnection(conn: Connection) =
  if conn.open:
    conn.open = false
    activeConnections.dec
    echo fmt"Connection {conn.id} closed (active: {activeConnections})"

# Example 1: Basic bracket pattern
echo "=== Example 1: Basic Bracket Pattern ==="

proc acquireConn(): Task[Connection] {.rt.} =
  return openConnection()

proc releaseConn(conn: Connection): Task[Unit] {.rt.} =
  closeConnection(conn)
  return unit()

proc useConnection(conn: Connection): Task[string] {.rt.} =
  echo fmt"Using connection {conn.id}"
  perform sleep(50.milliseconds)
  return fmt"Result from connection {conn.id}"

proc bracketExample(): Task[string] =
  bracket(
    acquireConn(),
    useConnection,
    releaseConn
  )

let result1 = runDefault(bracketExample())
echo "Result: ", result1.ok
echo "Active connections: ", activeConnections

# Example 2: Bracket with error in use phase
echo "\n=== Example 2: Bracket with Error ==="

proc useWithError(conn: Connection): Task[string] {.rt.} =
  echo fmt"Using connection {conn.id} (will fail)"
  perform sleep(25.milliseconds)
  return await fail[string](foreignError("Operation failed"))

let result2 = runDefault(bracket(acquireConn(), useWithError, releaseConn))
if result2.isOk:
  echo "Result: ", result2.ok
else:
  echo "Error: ", result2.err.msg
echo "Active connections after error: ", activeConnections

# Example 3: bracketOnError - release only on failure
echo "\n=== Example 3: bracketOnError ==="

proc useSuccessfully(conn: Connection): Task[Connection] {.rt.} =
  echo fmt"Using connection {conn.id} successfully"
  return conn  # Return the connection to caller

proc rollbackConn(conn: Connection): Task[Unit] {.rt.} =
  echo fmt"Rolling back connection {conn.id}"
  closeConnection(conn)
  return unit()

# Success case - connection stays open
let result3a = runDefault(bracketOnError(acquireConn(), useSuccessfully, rollbackConn))
if result3a.isOk:
  echo "Got connection: ", result3a.ok.id, " (still open: ", result3a.ok.open, ")"
  closeConnection(result3a.ok)  # Manual cleanup

# Failure case - connection rolled back
proc useAndFail(conn: Connection): Task[Connection] {.rt.} =
  echo fmt"Using connection {conn.id} (will fail)"
  return await fail[Connection](foreignError("Transaction failed"))

let result3b = runDefault(bracketOnError(acquireConn(), useAndFail, rollbackConn))
if result3b.isOk:
  echo "Got connection"
else:
  echo "Error (connection was rolled back): ", result3b.err.msg
echo "Active connections: ", activeConnections

# Example 4: ensure - always run cleanup
echo "\n=== Example 4: ensure - Always Run Cleanup ==="

var cleanupRan = false

proc successTask(): Task[int] {.rt.} =
  return 42

proc failTask(): Task[int] =
  fail[int](foreignError("failed"))

proc cleanupTask(): Task[Unit] =
  proc(rt: ptr Runtime, k: Cont[Unit]) =
    cleanupRan = true
    echo "Cleanup executed!"
    k(rt, ok(unit()))

cleanupRan = false
let result4a = runDefault(ensure(successTask(), cleanupTask()))
echo "Success result: ", result4a.ok, ", cleanup ran: ", cleanupRan

cleanupRan = false
let result4b = runDefault(ensure(failTask(), cleanupTask()))
echo "Failure result: ", result4b.err.msg, ", cleanup ran: ", cleanupRan

# Example 5: defer in .rt. procs
echo "\n=== Example 5: defer in .rt. procs ==="

proc deferExample(): Task[string] {.rt.} =
  defer:
    echo "Deferred cleanup 1"
  defer:
    echo "Deferred cleanup 2"

  echo "Doing work..."
  perform sleep(25.milliseconds)
  return "Work completed"

let result5 = runDefault(deferExample())
echo "Result: ", result5.ok
