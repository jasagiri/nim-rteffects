## Example 09: Channels
##
## Demonstrates inter-task communication using TaskChannels.

import std/[times, strformat]
import rteffects

# Example 1: Basic producer-consumer
echo "=== Example 1: Basic Producer-Consumer ==="

proc producer(ch: TaskChannel[int], count: int): Task[Unit] =
  proc loop(i: int): Task[Unit] =
    if i > count:
      andThen(closeChannel(ch), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        echo "Producer: channel closed"
        pure(unit())
      )
    else:
      echo fmt"Producer: sending {i}"
      andThen(send(ch, i), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        andThen(sleep(10.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          loop(i + 1)
        )
      )
  loop(1)

proc consumer(ch: TaskChannel[int]): Task[int] =
  proc loop(sum: int): Task[int] =
    andThen(tryRecv(ch), proc(res: Result[int]): Task[int] {.gcsafe, closure.} =
      if res.isOk:
        let value = res.ok
        echo fmt"Consumer: received {value}"
        loop(sum + value)
      elif isClosed(ch):
        echo fmt"Consumer: channel closed, sum = {sum}"
        pure(sum)
      else:
        # Channel empty but not closed, wait and retry
        andThen(sleep(5.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
          loop(sum)
        )
    )
  loop(0)

proc example1(): Task[int] =
  let ch = newTaskChannel[int]()
  andThen(spawn(producer(ch, 5)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
    consumer(ch)
  )

let result1 = runDefault(example1())
echo "Total sum: ", result1.ok

# Example 2: Bounded channel (backpressure)
echo "\n=== Example 2: Bounded Channel (capacity=2) ==="

proc boundedProducer(ch: TaskChannel[string]): Task[Unit] =
  proc sendItem(i: int): Task[Unit] =
    if i > 5:
      andThen(closeChannel(ch), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        pure(unit())
      )
    else:
      let msg = fmt"Item-{i}"
      echo fmt"Producer: trying to send {msg}"
      andThen(send(ch, msg), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        echo fmt"Producer: sent {msg}"
        sendItem(i + 1)
      )
  sendItem(1)

proc boundedConsumer(ch: TaskChannel[string]): Task[seq[string]] =
  proc loop(items: seq[string]): Task[seq[string]] =
    andThen(recv(ch), proc(item: string): Task[seq[string]] {.gcsafe, closure.} =
      echo fmt"Consumer: received {item}"
      andThen(sleep(50.milliseconds), proc(_: Unit): Task[seq[string]] {.gcsafe, closure.} =
        loop(items & @[item])
      )
    )

  # Handle channel close
  let recvTask = loop(@[])
  recover(recvTask, proc(e: RtError): Task[seq[string]] {.gcsafe, closure.} =
    pure(@[])  # Return empty on close
  )

proc example2(): Task[seq[string]] =
  let ch = newTaskChannel[string](2)  # Buffer size of 2
  andThen(spawn(boundedProducer(ch)), proc(_: TaskId): Task[seq[string]] {.gcsafe, closure.} =
    boundedConsumer(ch)
  )

let result2 = runDefault(example2())
echo "Received items: ", result2.ok.len

# Example 3: Multiple producers, single consumer
echo "\n=== Example 3: Fan-in Pattern ==="

proc fanInProducer(ch: TaskChannel[string], name: string, count: int): Task[Unit] =
  proc sendLoop(i: int): Task[Unit] =
    if i > count:
      pure(unit())
    else:
      let msg = fmt"{name}-{i}"
      andThen(send(ch, msg), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        andThen(sleep(10.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          sendLoop(i + 1)
        )
      )
  sendLoop(1)

proc fanInExample(): Task[int] =
  let ch = newTaskChannel[string]()

  # Spawn multiple producers
  andThen(spawn(fanInProducer(ch, "A", 3)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
    andThen(spawn(fanInProducer(ch, "B", 3)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
      andThen(spawn(fanInProducer(ch, "C", 3)), proc(_: TaskId): Task[int] {.gcsafe, closure.} =
        # Consumer: collect messages for a limited time
        proc collectFor(count: int, collected: int): Task[int] =
          if count <= 0:
            pure(collected)
          else:
            andThen(tryRecv(ch), proc(res: Result[string]): Task[int] {.gcsafe, closure.} =
              if res.isOk:
                echo "Received: ", res.ok
                collectFor(count - 1, collected + 1)
              else:
                andThen(sleep(5.milliseconds), proc(_: Unit): Task[int] {.gcsafe, closure.} =
                  collectFor(count - 1, collected)
                )
            )
        collectFor(20, 0)
      )
    )
  )

let result3 = runDefault(fanInExample())
echo "Collected messages: ", result3.ok
