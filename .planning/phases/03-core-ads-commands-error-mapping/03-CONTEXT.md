# Phase 3: Core ADS Commands & Error Mapping - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Users can issue the full core ADS command set (Read, Write, ReadWrite, ReadState, WriteControl, ReadDeviceInfo) through an idiomatic async Dart API, with every ADS error surfaced as a typed exception. Delivers the `AdsClient` (L6-lite: explicit addressing until Phase 4's router), the full ADS error-code table + `AdsException` mapping, mock-server command coverage with write-back and error fixtures, and per-command integration tests. No routing (Phase 4), no notifications/sum/symbols (Phases 5–7).

Requirements: CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, CMD-06, ERR-01.

</domain>

<decisions>
## Implementation Decisions

### Client API Shape
- Entry class `AdsClient(connection, target, source)` — explicit AmsAddr addressing for now; Phase 4's router takes over source stamping without changing command-method code
- Named parameters on command methods (`read(indexGroup:, indexOffset:, length:)`) — self-documenting against raw hex constants
- Typed return values: `AdsStateInfo` (adsState as an `AdsState` enum + deviceState int) and `DeviceInfo` (name + version triple); raw ints remain accessible
- WriteControl takes an optional named `data` parameter defaulting to empty bytes

### Error Mapping (ERR-01)
- Single `AdsException` carrying `code`, `name`, `message` (+ `isDeviceError`/`isClientError` helpers) — no deep subtype tree in v1
- Full ADS global error table sourced from the vendored `third_party/ADS` `AdsDef.h` (named constants, code → name lookup)
- Errors throw at BOTH levels: non-zero AMS header `errorCode` AND non-zero command `result` field in the payload → `AdsException`
- Error 1861 maps generically in this phase; the actionable source-NetId message is ERR-02, owned by Phase 4

### Mock Extensions & Command Tests
- Mock gains an in-memory data store keyed by (indexGroup, indexOffset): Read/Write/ReadWrite operate on it with write-back persisting within a session; canned ReadState/WriteControl responses
- Magic index group fixture: requests to a designated indexGroup make the mock return a chosen non-zero ADS error — real error frames exercised end-to-end
- Coverage bar: integration test per command (success path) + at least one live error-response case + unit tests for the error-table mapping at both levels (AMS errorCode, payload result)

### Claude's Discretion
- File layout for the client + errors (suggested: lib/src/client/, lib/src/protocol/ads_error.dart or similar — keep protocol/ pure)
- Exact AdsState enum members (from ADSSTATE_* constants) and DeviceInfo field naming
- Mock data-store implementation details and the magic indexGroup value
- Whether ReadWrite gets a convenience that returns the read bytes directly (it should)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AmsConnection.request()` (Phase 2) — returns raw response payload bytes after correlation/timeout; `AdsClient` composes on top
- `lib/src/protocol/commands.dart` (Phase 1) — six request encoders + sealed `AdsResponse` decoders already exist and are golden-parity proven; the client wires encoders → connection → decoders
- Decoders already validate `readLength` before slicing (MalformedFrameException on overrun)
- `test/support/mock_server.dart` launch helper; mock modes --fragment/--coalesce/--delay-ms/--close-after; goldens + readGolden
- Error/exception conventions: transport family (AdsTimeoutException, AdsConnectionException), wire family (MalformedFrameException), caller bugs (ArgumentError)

### Established Patterns
- lib/src/protocol/ stays pure (no dart:async/dart:io) — the error TABLE/constants can live in protocol/; AdsClient (async) lives outside protocol/
- Commit style type(03-XX): description; atomic per task; TDD where eligible
- Statement-scoped endian gate in CI; format gate package-wide
- Verify-command ordering rule: tasks only reference files that exist at their completion

### Integration Points
- Phase 4 AmsRouter will construct/own AdsClient instances (or inject addressing) — keep addressing cleanly separable
- Phase 5 notifications and Phase 6 sum commands build on ReadWrite via the same client
- The decoders' payload `result` field is where payload-level errors surface — client maps them via the new table

</code_context>

<specifics>
## Specific Ideas

- Command methods must throw `AdsException` (not return error codes) — but AdsException must expose `code` so callers can branch on specific errors
- The full command set exists in commands.dart already: this phase is primarily the client veneer + error table + mock/data-store + tests. Scope is deliberately modest — don't rebuild what Phase 1 shipped
- Write-back mock store makes read-after-write integration tests meaningful (write X to offset, read X back)

</specifics>

<deferred>
## Deferred Ideas

- ERR-02 actionable 1861 message → Phase 4 (router owns source NetId)
- Typed value conversion (BOOL/INT/REAL/STRING) → Phase 7 (SYM-03); this phase stays at Uint8List payloads

</deferred>
