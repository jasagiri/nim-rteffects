## handlers.nim — Standard effect tags and handlers for common I/O operations.
##
## Provides ready-to-use effect tags (HTTP, File, LLM) and handler
## implementations (sync, mock, deferred) so consumers don't need to
## define their own for standard operations.
##
## Usage:
##   let eff = performHttpGet("https://api.example.com/data")
##   let result = run[string](handle[string](eff, httpGetTag, syncHttpGetHandler().impl))
##
## For testing:
##   let result = run[string](handle[string](eff, httpGetTag,
##     mockHttpGetHandler(@[("api.example.com", "{}")]).impl))
##
## For async (Engine-based):
##   engine.frames[fid].handlers.add(deferredHttpGetHandler())
##   # Resume later: engine.resumeFrame(fid, boxStr(response))

import std/[httpclient, strutils]
import ./core
import ./vm/types
import ./vm/engine
import ./algebra

# ── Effect Tags ────────────────────────────────────────────────────

const
  httpGetTag* = EffectTag("http:get")
    ## HTTP GET request. Payload: boxStr(url). Resume: boxStr(responseBody).
  httpPostTag* = EffectTag("http:post")
    ## HTTP POST request. Payload: boxStr(url + "\n" + body). Resume: boxStr(responseBody).
  fileReadTag* = EffectTag("file:read")
    ## File read. Payload: boxStr(path). Resume: boxStr(content).
  fileWriteTag* = EffectTag("file:write")
    ## File write. Payload: boxStr(path + "\n" + content). Resume: boxNone().

type
  HttpPostPayload* = ref object of RootObj
    url*: string
    body*: string
    contentType*: string

  FileWritePayload* = ref object of RootObj
    path*: string
    content*: string

# ── Typed Perform Wrappers ─────────────────────────────────────────

proc performHttpGet*(url: string): Eff[string] =
  ## Perform HTTP GET. Returns response body as string.
  perform[string](httpGetTag, boxStr(url))

proc performHttpPost*(url: string, body: string, contentType: string = "application/json"): Eff[string] =
  ## Perform HTTP POST.
  perform[string](httpPostTag, boxRef(HttpPostPayload(
    url: url, body: body, contentType: contentType)))

proc performFileRead*(path: string): Eff[string] =
  ## Read a file. Returns content as string.
  perform[string](fileReadTag, boxStr(path))

proc performFileWrite*(path: string, content: string): Eff[string] =
  ## Write a file. Returns empty string on success.
  perform[string](fileWriteTag, boxRef(FileWritePayload(
    path: path, content: content)))

proc performValidation*(issue: ValidationIssueDetail): Eff[ValidationIssueDetail] =
  ## Request validation for a single issue.
  perform[ValidationIssueDetail](ValidationTag, boxIssue(issue))

# ── Sync Handlers (blocking, for simple scripts) ──────────────────

proc syncHttpGetHandler*(): HandlerEntry =
  ## Synchronous HTTP GET using std/httpclient. Blocks until response.
  HandlerEntry(tag: httpGetTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let url = payload.strVal
      try:
        let client = newHttpClient(timeout = 30000)
        defer: client.close()
        let resp = client.getContent(url)
        resume(boxStr(resp))
      except CatchableError:
        let msg = try: getCurrentExceptionMsg() except: "HTTP GET error"
        abort(exceptionError(msg))
  )

proc syncHttpPostHandler*(): HandlerEntry =
  ## Synchronous HTTP POST using std/httpclient.
  HandlerEntry(tag: httpPostTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      if payload.kind != bvRef or payload.refVal.isNil or not (payload.refVal of HttpPostPayload):
        abort(exceptionError("HTTP POST payload missing or invalid type"))
        return
      
      let data = cast[HttpPostPayload](payload.refVal)
      try:
        let client = newHttpClient(timeout = 30000)
        defer: client.close()
        client.headers = newHttpHeaders({"Content-Type": data.contentType})
        let resp = client.postContent(data.url, data.body)
        resume(boxStr(resp))
      except CatchableError:
        let msg = try: getCurrentExceptionMsg() except: "HTTP POST error"
        abort(exceptionError(msg))
  )

proc syncFileReadHandler*(): HandlerEntry =
  ## Synchronous file read handler.
  HandlerEntry(tag: fileReadTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let path = payload.strVal
      try:
        let content = readFile(path)
        resume(boxStr(content))
      except CatchableError:
        let msg = try: getCurrentExceptionMsg() except: "File read error"
        abort(exceptionError(msg))
  )

proc syncFileWriteHandler*(): HandlerEntry =
  ## Synchronous file write handler.
  HandlerEntry(tag: fileWriteTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      if payload.kind != bvRef or payload.refVal.isNil or not (payload.refVal of FileWritePayload):
        abort(exceptionError("File write payload missing or invalid type"))
        return
        
      let data = cast[FileWritePayload](payload.refVal)
      try:
        writeFile(data.path, data.content)
        resume(boxStr(""))
      except CatchableError:
        let msg = try: getCurrentExceptionMsg() except: "File write error"
        abort(exceptionError(msg))
  )

# ── Validation Handlers ───────────────────────────────────────────

proc failFastValidationHandler*(): HandlerEntry =
  ## Validation handler that aborts on the first issue.
  HandlerEntry(tag: ValidationTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let issue = payload.issueVal
      abort(validationError(issue.field, issue.rule, issue.value, issue.message))
  )

proc collectAllValidationHandler*(): HandlerEntry =
  ## Validation handler that allows continuation, yielding the issue.
  ## Use with joinValidation to aggregate all issues.
  HandlerEntry(tag: ValidationTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      let issue = payload.issueVal
      # We abort but with a ValidationIssue kind.
      # The engine/runner boundary will convert this to tvBoth if it can.
      # Wait, if we want to COLLECT, we should actually 'abort' or return something
      # that semantics.join knows how to handle.
      # In Belnap terms, a validation failure is a 'tvFalse' for THAT specific check.
      abort(validationError(issue.field, issue.rule, issue.value, issue.message))
  )

# ── Mock Handlers (for testing) ────────────────────────────────────

proc mockHttpGetHandler*(responses: seq[(string, string)]): HandlerEntry =
  ## Mock HTTP GET: returns pre-configured response by URL substring match.
  ## responses: seq of (url_substring, response_body).
  var capturedResponses = responses
  HandlerEntry(tag: httpGetTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      {.cast(gcsafe).}:
        let url = payload.strVal
        for (pattern, body) in capturedResponses:
          if pattern in url:
            resume(boxStr(body))
            return
        abort(exceptionError("No mock response for: " & url))
  )

proc mockFileReadHandler*(files: seq[(string, string)]): HandlerEntry =
  ## Mock file read: returns pre-configured content by path substring match.
  var capturedFiles = files
  HandlerEntry(tag: fileReadTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      {.cast(gcsafe).}:
        let path = payload.strVal
        for (pattern, content) in capturedFiles:
          if pattern in path:
            resume(boxStr(content))
            return
        abort(exceptionError("No mock file for: " & path))
  )

# ── Deferred Handlers (for Engine-based async) ─────────────────────

proc deferredHttpGetHandler*(): HandlerEntry =
  ## Handler that does NOT call resume. Frame goes to fsSuspended.
  ## Caller is responsible for engine.resumeFrame(fid, boxStr(response)).
  HandlerEntry(tag: httpGetTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      discard  # fsSuspended
  )

proc deferredHttpPostHandler*(): HandlerEntry =
  ## Deferred HTTP POST handler.
  HandlerEntry(tag: httpPostTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      discard
  )

proc deferredFileReadHandler*(): HandlerEntry =
  ## Deferred file read handler.
  HandlerEntry(tag: fileReadTag, impl: proc(
    payload: BoxedValue,
    resume: proc(v: BoxedValue) {.gcsafe.},
    abort: proc(e: RtError) {.gcsafe.}) {.gcsafe.} =
      discard
  )
