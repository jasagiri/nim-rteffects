## Example 13: Rate Limiter
##
## Implements a token bucket rate limiter for controlling request rates.

import std/[times, strformat, deques]
import rteffects

type
  RateLimiter = ref object
    tokens: int
    maxTokens: int
    refillRate: int  # tokens per second
    lastRefill: float
    sem: Semaphore

proc newRateLimiter(maxTokens: int, refillRate: int): RateLimiter =
  result = RateLimiter(
    tokens: maxTokens,
    maxTokens: maxTokens,
    refillRate: refillRate,
    lastRefill: cpuTime(),
    sem: newSemaphore(1)
  )

proc refillTokens(rl: RateLimiter) =
  let now = cpuTime()
  let elapsed = now - rl.lastRefill
  let newTokens = int(elapsed * float(rl.refillRate))
  if newTokens > 0:
    rl.tokens = min(rl.tokens + newTokens, rl.maxTokens)
    rl.lastRefill = now

proc acquireToken(rl: RateLimiter): Task[bool] =
  withSemaphore(rl.sem,
    proc(rt: ptr Runtime, k: Cont[bool]) =
      rl.refillTokens()
      if rl.tokens > 0:
        rl.tokens.dec
        k(rt, ok(true))
      else:
        k(rt, ok(false))
  )

proc waitForToken(rl: RateLimiter): Task[Unit] =
  proc loop(): Task[Unit] =
    andThen(acquireToken(rl), proc(got: bool): Task[Unit] {.gcsafe, closure.} =
      if got:
        pure(unit())
      else:
        # Wait a bit and retry
        andThen(sleep(100.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          loop()
        )
    )
  loop()

# Simulated API call
proc apiCall(id: int): Task[string] {.rt.} =
  perform sleep(50.milliseconds)
  return fmt"Response for request {id}"

proc rateLimitedCall(rl: RateLimiter, requestId: int): Task[string] =
  andThen(waitForToken(rl), proc(_: Unit): Task[string] {.gcsafe, closure.} =
    let startTime = cpuTime()
    andThen(apiCall(requestId), proc(response: string): Task[string] {.gcsafe, closure.} =
      let elapsed = (cpuTime() - startTime) * 1000
      echo fmt"Request {requestId}: {response} ({elapsed:.1f}ms)"
      pure(response)
    )
  )

proc makeRequests(rl: RateLimiter, count: int): Task[seq[string]] =
  proc loop(idx: int, results: seq[string]): Task[seq[string]] =
    if idx > count:
      pure(results)
    else:
      andThen(rateLimitedCall(rl, idx), proc(response: string): Task[seq[string]] {.gcsafe, closure.} =
        loop(idx + 1, results & @[response])
      )
  loop(1, @[])

# Example 1: Sequential rate-limited requests
echo "=== Example 1: Sequential Rate-Limited Requests ==="
echo "Rate limit: 5 tokens max, 2 tokens/second refill"
echo ""

let limiter1 = newRateLimiter(maxTokens = 5, refillRate = 2)
let startTime1 = cpuTime()
let results1 = runDefault(makeRequests(limiter1, 8))
let elapsed1 = cpuTime() - startTime1

if results1.isOk:
  echo fmt"\nCompleted {results1.ok.len} requests in {elapsed1:.2f}s"

# Example 2: Parallel requests with rate limiting
echo "\n=== Example 2: Parallel Requests with Rate Limiting ==="

proc parallelRateLimitedRequests(rl: RateLimiter, requestIds: seq[int]): Task[seq[string]] =
  var tasks: seq[Task[string]] = @[]
  for id in requestIds:
    tasks.add(rateLimitedCall(rl, id))
  all(tasks)

let limiter2 = newRateLimiter(maxTokens = 3, refillRate = 5)
let requestIds = @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

echo fmt"Making {requestIds.len} parallel requests"
echo "Rate limit: 3 tokens max, 5 tokens/second refill"
echo ""

let startTime2 = cpuTime()
let results2 = runDefault(parallelRateLimitedRequests(limiter2, requestIds))
let elapsed2 = cpuTime() - startTime2

if results2.isOk:
  echo fmt"\nCompleted {results2.ok.len} parallel requests in {elapsed2:.2f}s"
else:
  echo "Error: ", results2.err.msg

# Example 3: Rate limiting with timeout
echo "\n=== Example 3: Rate Limiting with Timeout ==="

proc tryAcquireWithTimeout(rl: RateLimiter, timeout: Duration): Task[bool] =
  let task = waitForToken(rl)
  let timedTask = withTimeout(timeout, task)
  andThen(timedTask, proc(_: Unit): Task[bool] {.gcsafe, closure.} =
    pure(true)
  )

proc rateLimitedWithTimeout(rl: RateLimiter, requestId: int, timeout: Duration): Task[Result[string]] =
  andThen(tryAcquireWithTimeout(rl, timeout), proc(acquired: bool): Task[Result[string]] {.gcsafe, closure.} =
    if acquired:
      andThen(apiCall(requestId), proc(response: string): Task[Result[string]] {.gcsafe, closure.} =
        echo fmt"Request {requestId}: success"
        pure(ok(response))
      )
    else:
      echo fmt"Request {requestId}: timed out waiting for token"
      pure(err[string](timeoutError()))
  )

# Use recover to handle timeout errors
let limitedWithTimeout = recover(
  rateLimitedWithTimeout(limiter2, 100, initDuration(milliseconds = 200)),
  proc(e: RtError): Task[Result[string]] {.gcsafe, closure.} =
    if e.kind == RtErrorKind.Timeout:
      echo "Request 100: rate limit timeout"
      pure(err[string](e))
    else:
      pure(err[string](e))
)

let result3 = runDefault(limitedWithTimeout)
if result3.isOk and result3.ok.isOk:
  echo "Got response: ", result3.ok.ok
