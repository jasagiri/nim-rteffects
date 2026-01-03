## Example 12: Worker Pool Pattern
##
## Implements a worker pool for processing jobs concurrently.

import std/[times, strformat, random]
import rteffects

type
  Job = object
    id: int
    data: string

  JobResult = object
    jobId: int
    result: string
    workerId: int

randomize()

proc processJob(workerId: int, job: Job): Task[JobResult] {.rt.} =
  let processingTime = rand(50..150)
  echo fmt"Worker {workerId}: processing job {job.id} ({processingTime}ms)"
  perform sleep(processingTime.milliseconds)
  return JobResult(
    jobId: job.id,
    result: fmt"Processed '{job.data}' by worker {workerId}",
    workerId: workerId
  )

# Simple worker that processes a single job
proc singleWorker(workerId: int, job: Job): Task[JobResult] =
  processJob(workerId, job)

# Process jobs using mapTask for parallel execution
proc processAllJobs(jobs: seq[Job], numWorkers: int): Task[seq[JobResult]] =
  var idx = 0
  mapTask(jobs, proc(job: Job): Task[JobResult] {.gcsafe, closure.} =
    idx.inc
    let workerId = (idx mod numWorkers) + 1
    singleWorker(workerId, job)
  )

# Create jobs
var jobs: seq[Job] = @[]
for i in 1..8:
  jobs.add(Job(id: i, data: fmt"Task-{i}"))

echo "=== Worker Pool Example ==="
echo fmt"Processing {jobs.len} jobs with 3 workers"
echo ""

let results = runDefault(processAllJobs(jobs, 3))

if results.isOk:
  echo "\n=== Results ==="
  for r in results.ok:
    echo fmt"Job {r.jobId}: {r.result}"

  echo fmt"\nTotal jobs processed: {results.ok.len}"
else:
  echo "Error: ", results.err.msg
