## Example 14: Pipeline Processing
##
## Demonstrates building data processing pipelines with channels.

import std/[times, strformat, strutils]
import rteffects

type
  DataItem = object
    id: int
    value: string

# Pipeline stages
proc stage1_fetch(output: TaskChannel[DataItem], items: seq[string]): Task[Unit] =
  proc loop(idx: int): Task[Unit] =
    if idx >= items.len:
      andThen(closeChannel(output), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        echo "Stage1: completed, channel closed"
        pure(unit())
      )
    else:
      let item = DataItem(id: idx + 1, value: items[idx])
      echo fmt"Stage1: fetched item {item.id}"
      andThen(send(output, item), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        loop(idx + 1)
      )
  loop(0)

proc stage2_transform(input: TaskChannel[DataItem], output: TaskChannel[DataItem]): Task[Unit] =
  proc loop(): Task[Unit] =
    andThen(recv(input), proc(item: DataItem): Task[Unit] {.gcsafe, closure.} =
      # Transform: uppercase the value
      let transformed = DataItem(
        id: item.id,
        value: item.value.toUpperAscii()
      )
      echo fmt"Stage2: transformed item {item.id}"
      andThen(sleep(10.milliseconds), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        andThen(send(output, transformed), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
          loop()
        )
      )
    )

  recover(loop(), proc(e: RtError): Task[Unit] {.gcsafe, closure.} =
    andThen(closeChannel(output), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
      echo "Stage2: completed"
      pure(unit())
    )
  )

proc stage3_enrich(input: TaskChannel[DataItem], output: TaskChannel[DataItem]): Task[Unit] =
  proc loop(): Task[Unit] =
    andThen(recv(input), proc(item: DataItem): Task[Unit] {.gcsafe, closure.} =
      # Enrich: add prefix
      let enriched = DataItem(
        id: item.id,
        value: fmt"[PROCESSED] {item.value}"
      )
      echo fmt"Stage3: enriched item {item.id}"
      andThen(send(output, enriched), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
        loop()
      )
    )

  recover(loop(), proc(e: RtError): Task[Unit] {.gcsafe, closure.} =
    andThen(closeChannel(output), proc(_: Unit): Task[Unit] {.gcsafe, closure.} =
      echo "Stage3: completed"
      pure(unit())
    )
  )

proc stage4_collect(input: TaskChannel[DataItem]): Task[seq[DataItem]] =
  proc loop(results: seq[DataItem]): Task[seq[DataItem]] =
    andThen(recv(input), proc(item: DataItem): Task[seq[DataItem]] {.gcsafe, closure.} =
      echo fmt"Stage4: collected item {item.id}"
      loop(results & @[item])
    )

  recover(loop(@[]), proc(e: RtError): Task[seq[DataItem]] {.gcsafe, closure.} =
    echo "Stage4: completed"
    pure(@[])
  )

proc runPipeline(inputData: seq[string]): Task[seq[DataItem]] =
  let ch1 = newTaskChannel[DataItem](2)
  let ch2 = newTaskChannel[DataItem](2)
  let ch3 = newTaskChannel[DataItem](2)

  # Start all stages
  andThen(spawn(stage1_fetch(ch1, inputData)), proc(_: TaskId): Task[seq[DataItem]] {.gcsafe, closure.} =
    andThen(spawn(stage2_transform(ch1, ch2)), proc(_: TaskId): Task[seq[DataItem]] {.gcsafe, closure.} =
      andThen(spawn(stage3_enrich(ch2, ch3)), proc(_: TaskId): Task[seq[DataItem]] {.gcsafe, closure.} =
        # Run collector in main flow
        stage4_collect(ch3)
      )
    )
  )

echo "=== Data Processing Pipeline ==="
echo "Stage 1: Fetch data"
echo "Stage 2: Transform (uppercase)"
echo "Stage 3: Enrich (add prefix)"
echo "Stage 4: Collect results"
echo ""

let inputData = @["apple", "banana", "cherry", "date", "elderberry"]
echo "Input: ", inputData
echo ""

let result = runDefault(runPipeline(inputData))

if result.isOk:
  echo "\n=== Final Results ==="
  for item in result.ok:
    echo fmt"  {item.id}: {item.value}"
else:
  echo "Pipeline error: ", result.err.msg
