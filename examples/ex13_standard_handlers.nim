## ex13: Standard Handlers — ready-to-use effect tags and mock handlers
##
## The handlers module ships pre-defined effect tags for HTTP and file I/O,
## typed perform wrappers that eliminate manual boxing, and mock handlers
## for deterministic testing without real network or disk access.
##
## Key concepts:
##   - httpGetTag, httpPostTag, fileReadTag, fileWriteTag — pre-defined constants
##   - performHttpGet, performHttpPost, performFileRead, performFileWrite
##   - mockHttpGetHandler / mockFileReadHandler with URL/path substring matching
##   - HandlerEntry.impl — the raw HandlerProc used with handle[T]
##   - First-match-wins semantics across multiple mock responses
##   - No-match → abort (ExceptionRaised)
##   - Composing HTTP + File handlers in one pipeline

import std/strutils
import rteffects

# ── 1. Simple HTTP GET with a single mock ──────────────────────────────────────

block simpleGet:
  let eff = performHttpGet("https://api.example.com/users")
  let handled = handle[string](eff, httpGetTag,
    mockHttpGetHandler(@[("api.example.com", """{"users":[]}""")]).impl)
  let result = run[string](handled)

  assert result.isOk, "expected ok, got: " & result.err.msg
  assert result.ok == """{"users":[]}""", "unexpected body: " & result.ok
  echo "1. HTTP GET mock: ", result.ok

# ── 2. HTTP GET → map (parse the response body length as a proxy for parsing) ─

block getAndMap:
  let eff = performHttpGet("https://api.example.com/items")
    .map(proc(body: string): string {.gcsafe.} =
      "parsed:" & $body.len & " bytes")

  let handled = handle[string](eff, httpGetTag,
    mockHttpGetHandler(@[("items", """[1,2,3]""")]).impl)
  let result = run[string](handled)

  assert result.isOk
  assert result.ok == "parsed:7 bytes", "got: " & result.ok
  echo "2. HTTP GET → map: ", result.ok

# ── 3. File read with mock ──────────────────────────────────────────────────────

block fileRead:
  let eff = performFileRead("/data/config.json")
  let handled = handle[string](eff, fileReadTag,
    mockFileReadHandler(@[("config.json", """{"version":"1.0"}""")]).impl)
  let result = run[string](handled)

  assert result.isOk
  assert result.ok == """{"version":"1.0"}"""
  echo "3. File read mock: ", result.ok

# ── 4. Multiple mock responses — first matching pattern wins ──────────────────

block multipleResponses:
  let mocks = mockHttpGetHandler(@[
    ("api.example.com/users", """{"count":3}"""),
    ("api.example.com",       """{"fallback":true}"""),
  ])

  # /users path matches the first pattern
  let effUsers = performHttpGet("https://api.example.com/users")
  let r1 = run[string](handle[string](effUsers, httpGetTag, mocks.impl))
  assert r1.isOk
  assert r1.ok == """{"count":3}""", "got: " & r1.ok
  echo "4a. first match (/users): ", r1.ok

  # /items path falls through to the second (domain-only) pattern
  let effItems = performHttpGet("https://api.example.com/items")
  let r2 = run[string](handle[string](effItems, httpGetTag, mocks.impl))
  assert r2.isOk
  assert r2.ok == """{"fallback":true}""", "got: " & r2.ok
  echo "4b. second match (fallback): ", r2.ok

# ── 5. No matching mock → error abort ─────────────────────────────────────────

block noMatch:
  let eff = performHttpGet("https://other.example.com/data")
  let handled = handle[string](eff, httpGetTag,
    mockHttpGetHandler(@[("api.example.com", "irrelevant")]).impl)
  let result = run[string](handled)

  assert not result.isOk
  assert result.err.kind == ExceptionRaised
  assert "No mock response for:" in result.err.msg
  echo "5. no match → error: ", result.err.msg

# ── 6. Composing HTTP + File handlers in one pipeline ────────────────────────
#
# Handler composition: both mockHttpGetHandler and mockFileReadHandler are
# installed before the pipeline runs. Each handle[T] call wraps the prior
# Eff[T] value, so the engine sees both handlers while stepping.
#
# Pattern: fetch a URL to get a filename, transform the response with map
# (pure — no second perform), then in a separate handled step read the file.
# Two `run[]` calls sequence the effects; each run is self-contained.

block httpAndFilePipeline:
  # Phase A — HTTP GET with mock, map the response to derive a file path.
  let getFilename =
    performHttpGet("https://api.example.com/manifest")
      .map(proc(body: string): string {.gcsafe.} =
        # body is the manifest content; extract the config path from it
        body)  # mock returns the path directly

  let getHandled = handle[string](getFilename, httpGetTag,
    mockHttpGetHandler(@[("manifest", "/data/config.json")]).impl)

  let getResult = run[string](getHandled)
  assert getResult.isOk, "GET failed: " & getResult.err.msg
  let configPath = getResult.ok  # "/data/config.json"
  echo "6a. HTTP GET (phase A): path = ", configPath

  # Phase B — File read with mock, using the path from phase A.
  let readConfig =
    performFileRead(configPath)
      .map(proc(content: string): string {.gcsafe.} =
        "loaded:" & content)

  let readHandled = handle[string](readConfig, fileReadTag,
    mockFileReadHandler(@[("config.json", """{"mode":"prod"}""")]).impl)

  let readResult = run[string](readHandled)
  assert readResult.isOk, "file read failed: " & readResult.err.msg
  assert readResult.ok == """loaded:{"mode":"prod"}""", "got: " & readResult.ok
  echo "6b. File read (phase B): ", readResult.ok

# ── 7. HTTP POST with mock ────────────────────────────────────────────────────

block httpPost:
  let eff = performHttpPost("https://api.example.com/submit",
                             """{"name":"Alice"}""")

  let mock = HandlerEntry(
    tag: httpPostTag,
    impl: proc(payload: BoxedValue,
               resume: proc(v: BoxedValue) {.gcsafe.},
               abort:  proc(e: RtError)  {.gcsafe.}) {.gcsafe.} =
      # Payload encodes "url\nbody"; echo back a canned response.
      resume(boxStr("""{"status":"created"}""")))

  let result = run[string](handle[string](eff, httpPostTag, mock.impl))
  assert result.isOk
  assert result.ok == """{"status":"created"}"""
  echo "7. HTTP POST mock: ", result.ok

echo "\nAll ex13 checks passed."
