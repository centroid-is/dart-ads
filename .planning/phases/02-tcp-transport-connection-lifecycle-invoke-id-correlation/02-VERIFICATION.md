---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
verified: 2026-07-03T00:00:00Z
status: passed
score: 5/5 must-haves verified
overrides_applied: 0
---

# Phase 2: TCP Transport / Connection Lifecycle / Invoke-ID Correlation Verification Report

**Phase Goal:** A live TCP connection to an ADS peer round-trips real frames through the FrameAssembler, correlates responses to requests by invoke-ID, enforces timeouts, and fails safely on disconnect.
**Verified:** 2026-07-03
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | A Dart test opens and cleanly closes a TCP connection to the mock server on an ephemeral port, launched via Process.start with stdout readiness handshake, torn down cleanly | VERIFIED | `test/integration/socket_transport_test.dart` — "connects and round-trips ReadDeviceInfo" + "close completes done and flips isConnected" pass. `startMockServer` in `test/support/mock_server.dart` uses `Process.start`, parses `LISTENING <port>` with a 10 s bounded `timeout(...)`, tears down via `server.stop()` (SIGTERM + await exitCode). Full integration suite 69/69 green. |
| 2 | Concurrent in-flight requests each receive their correct response, correlated by monotonic invoke-ID → Completer map, with no crossed responses | VERIFIED | `test/unit/ams_connection_test.dart` groups `correlation` and `reorder` pass (FakeTransport). `test/integration/ams_connection_live_test.dart` "reorder: correlates reordered responses by invoke-ID" passes with `--delay-ms 80` (on-wire inversion); `droppedResponses == 0` asserted. `_pending.remove(id)` is the sole completion claim (5 occurrences confirmed by grep). |
| 3 | A request that gets no reply fails with a typed timeout error after the configured per-request timeout | VERIFIED | `test/unit/ams_connection_test.dart` group `timeout` — `AdsTimeoutException` thrown, pending map empty after expiry, late response counts in `droppedResponses` and never re-throws. `AdsTimeoutException` carries `invokeId` + `commandId` (verified in `lib/src/connection/exceptions.dart`). |
| 4 | On disconnect, all pending requests error out and all notification streams close (failure fan-out) with no hung Futures | VERIFIED | `test/unit/ams_connection_test.dart` group `disconnect` — errored disconnect + clean-FIN variants both proven. `test/integration/ams_connection_live_test.dart` "disconnect: mid-request drop fans out with no hung Future" passes with `--close-after 1`; pending request errors as `AdsConnectionException` (not timeout), `done` completes. Single-shot `_failClose` guard (`if (_closed) return`) + snapshot-clear-before-error confirmed by grep. |
| 5 | Unsolicited notification frames (cmd 0x0008, no invoke-ID) route to the demux path instead of the invoke-ID map, and connection/codec logic is unit-testable against a fakeable transport with no live socket | VERIFIED | `test/unit/ams_connection_test.dart` group `notification` — cmd 0x08 increments `notificationFrames`, does not touch `_pending` or `droppedResponses`. Demux-before-lookup pattern confirmed: `deviceNotification` branch precedes `_pending.remove` in `_onFrame`. `FakeTransport` (written/feed/simulateDisconnect) proven by 5-case unit test; all AmsConnection unit tests use FakeTransport exclusively. |

**Score:** 5/5 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/src/transport/transport.dart` | abstract interface class AdsTransport (four members; no dart:io) | VERIFIED | 58 lines; `abstract interface class AdsTransport` present; zero `dart:io` imports confirmed by grep. |
| `lib/src/transport/socket_transport.dart` | dart:io Socket implementation with flush()+destroy() teardown | VERIFIED | 69 lines; `flush()` (1 occurrence) + `destroy()` (3 occurrences — try block + call + comment) confirmed. tcpNoDelay set. Null-guards on _socket. |
| `lib/src/transport/fake_transport.dart` | In-memory test double (written/feed/simulateDisconnect) | VERIFIED | 63 lines; `List<Uint8List> written` field, `void feed`, `simulateDisconnect` — all 5 driver names confirmed. Defensive copy in `add()`. |
| `lib/src/connection/exceptions.dart` | AdsTimeoutException + AdsConnectionException; no dart:io | VERIFIED | 63 lines; both classes present, distinct families, no dart:io import. `AdsTimeoutException` carries invokeId+commandId; `AdsConnectionException` carries optional cause. |
| `lib/src/connection/ams_connection.dart` | AmsConnection: invoke-ID correlation, timeout, demux, fan-out, lifecycle surface | VERIFIED | 329 lines (well above min_lines:80). All required members present: `connect`, `request`, `isConnected`, `done`, `droppedResponses`, `notificationFrames`, `close`. Uses real `.encode()` API (no `toBytes()`). |
| `lib/src/connection/pending_request.dart` | PendingRequest record: Completer + Timer + expectedCommandId | VERIFIED | 37 lines; `Completer<Uint8List>`, `Timer`, and `expectedCommandId` all present. Package-internal; not barrel-exported (grep confirms 0 occurrences in `lib/dart_ads.dart`). |
| `test/unit/fake_transport_test.dart` | FakeTransport unit tests — 4 behavior groups | VERIFIED | 87 lines; 5 tests covering add-records, add-copies, feed-delivers, simulateDisconnect-onDone, simulateDisconnect-error. |
| `test/unit/ams_connection_test.dart` | AmsConnection unit tests — 5 required behavior groups | VERIFIED | 316 lines; `correlation`, `reorder`, `timeout`, `disconnect`, `notification` groups all present (confirmed by grep on group names). |
| `test/support/mock_server.dart` | startMockServer + MockServer handle; staleness rebuild; LISTENING parse; 10 s timeout | VERIFIED | 204 lines; `Process.start`, `startsWith('LISTENING ')`, `lastModifiedSync`+`cmake` (9 combined occurrences), `timeout(` (1 occurrence). `stop()` method uses SIGTERM + await exitCode. Build-lock guard for concurrent `dart test` isolates included. |
| `test/integration/socket_transport_test.dart` | Live connect / ReadDeviceInfo round-trip / clean close | VERIFIED | 73 lines; `@Tags(['integration'])`, `startMockServer` (2 occurrences), lifecycle asserted (`isConnected`, `conn.done`). `decodeReadDeviceInfoResponse(payload).name` asserted equal to `'Dart ADS Mock'`. |
| `test/integration/ams_connection_live_test.dart` | Live reorder (--delay-ms) + disconnect (--close-after) | VERIFIED | 82 lines; `--delay-ms` and `--close-after` args present; `droppedResponses` asserted 0; `isA<AdsConnectionException>()` asserted on disconnect. Two request Futures captured before either is awaited (pipelining confirmed by code review). |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/dart_ads.dart` | `lib/src/transport/transport.dart` | `export 'src/transport/transport.dart' show AdsTransport` | VERIFIED | grep confirms 1 occurrence |
| `lib/dart_ads.dart` | `lib/src/transport/socket_transport.dart` | `export 'src/transport/socket_transport.dart' show SocketTransport` | VERIFIED | grep confirms 1 occurrence |
| `lib/dart_ads.dart` | `lib/src/connection/exceptions.dart` | `export ... show AdsTimeoutException, AdsConnectionException` | VERIFIED | grep confirms 1 occurrence |
| `lib/dart_ads.dart` | `lib/src/connection/ams_connection.dart` | `export 'src/connection/ams_connection.dart' show AmsConnection` | VERIFIED | grep confirms 1 occurrence; `pending_request.dart` NOT exported (0 occurrences) |
| `lib/src/connection/ams_connection.dart` | `FrameAssembler` | `_transport.inbound.listen -> _assembler.add(chunk) -> _onFrame` | VERIFIED | 4 references to `FrameAssembler` in ams_connection.dart; listener wired in `connect()` |
| `lib/src/connection/ams_connection.dart` | `_pending` (map-remove-wins) | `_pending.remove(id)` on both the timeout path and the inbound path | VERIFIED | 5 occurrences of `_pending.remove` (timeout timer callback + _onFrame + _failClose snapshot path) |
| `lib/src/connection/ams_connection.dart` | demux path | branch on `commandId == AdsCommandId.deviceNotification` before `_pending.remove(header.invokeId)` | VERIFIED | 1 occurrence; positioned before invoke-ID lookup in `_onFrame` |
| `test/support/mock_server.dart` | `test_harness/build/mock_server` | `Process.start(bin, args)` + staleness cmake rebuild | VERIFIED | `Process.start` present; `lastModifiedSync` + `cmake` (9 occurrences) |
| `test/integration/*` | `test/support/mock_server.dart` | `startMockServer(...)` + teardown via `addTearDown(server.stop)` / `tearDownAll` | VERIFIED | `startMockServer` present in both integration files; teardown confirmed |
| `test/integration/*` | `package:dart_ads/dart_ads.dart` | `AmsConnection` + `SocketTransport` via public barrel | VERIFIED | Both integration test files import `package:dart_ads/dart_ads.dart` and use `AmsConnection`, `SocketTransport` |

---

### Data-Flow Trace (Level 4)

Not applicable. Phase 2 delivers transport/connection infrastructure (no rendering components, no UI state). The behavioral spot-checks (integration tests) serve as the data-flow proof.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full unit suite (65 tests) | `dart test -x integration` | +65: All tests passed | PASS |
| Full suite incl. integration (69 tests) | `dart test` | +69: All tests passed | PASS |
| Static analysis | `dart analyze --fatal-infos` | No issues found | PASS |
| C++ mock self-test (golden byte-accuracy gate) | `./test_harness/build/mock_server --selftest` | OK (exit 0) | PASS |

---

### Probe Execution

No `probe-*.sh` scripts declared or present for this phase. Behavioral spot-checks above (integration tests launched via `dart test`) fulfill this verification role.

---

### Requirements Coverage

| Requirement | Source Plan | Description | Code Status | Evidence |
|-------------|-------------|-------------|-------------|---------|
| TRANS-01 | 02-01, 02-04 | Open/close TCP connection to ADS peer | SATISFIED | `SocketTransport.connect/close` (flush+destroy); integration test "connects and round-trips ReadDeviceInfo" + "close completes done" |
| TRANS-02 | 02-03 | Configurable per-request timeout fails pending operation on expiry | SATISFIED | `Timer` in `AmsConnection.request`; `AdsTimeoutException(invokeId, commandId)` on expiry; unit test `timeout` group proves no leak |
| TRANS-03 | 02-03, 02-04 | Disconnect errors all pending requests and closes notification streams | SATISFIED | `_failClose` snapshots+clears `_pending`, errors each with `AdsConnectionException`, closes `_demuxControllers`; integration disconnect test proves live fan-out |
| TRANS-04 | 02-01 | Fakeable transport interface for socket-free unit tests | SATISFIED | `AdsTransport` interface; `FakeTransport` with `written/feed/simulateDisconnect` proven by 5-case unit test |
| PROTO-03 | 02-03, 02-04 | Correlate responses to requests by invoke-ID (monotonic counter → Completer) | SATISFIED | `Map<int,PendingRequest>` with `_pending.remove` as sole completion claim; correlation + reorder unit tests; live reorder integration test with `droppedResponses==0` |
| PROTO-04 | 02-03 | Route notification frames (cmd 0x0008) to demux, not invoke-ID map | SATISFIED | `_onFrame` branches on `commandId == AdsCommandId.deviceNotification` before `_pending.remove`; unit test `notification` group proves no map interaction, no droppedResponses |
| TEST-03 | 02-02, 02-04 | Integration tests launch mock via Process.start with ephemeral port + LISTENING handshake, torn down cleanly | SATISFIED | `startMockServer` in `test/support/mock_server.dart`; both integration test files use it; 4 integration tests pass |

**Note on REQUIREMENTS.md tracking inconsistency (WARNING, not BLOCKER):** The REQUIREMENTS.md requirement-list checkboxes and traceability table status column show TRANS-02, TRANS-04, and PROTO-04 as `[ ]` / "Pending" rather than `[x]` / "Complete". TRANS-01, TRANS-03, PROTO-03, and TEST-03 are correctly marked complete. The code fully implements all 7 requirements as verified above — the discrepancy is a documentation tracking omission. REQUIREMENTS.md was not updated for the 3 items after the executor completed them. This does not affect phase goal achievement.

---

### Anti-Patterns Found

No anti-patterns found. Scanned all 11 files created/modified by this phase:

- Zero `TBD`, `FIXME`, or `XXX` markers
- Zero `TODO` or `HACK` markers in library code
- No stub patterns (`return null`, `return {}`, `UnimplementedError`) in shipped code
- `FakeTransport.connect` no-op is by design (explicit comment, satisfies the interface contract without I/O)
- No hardcoded empty props flowing to render paths

---

### Human Verification Required

None. All 5 success criteria are proven by automated tests (65 unit + 4 integration). The previously-tracked CI-push item lives in `01-HUMAN-UAT.md` and is explicitly excluded from re-raising here per phase context notes.

---

## Gaps Summary

No gaps. All 5 roadmap success criteria are verified in the codebase with evidence from both static code inspection and a green 69/69 test run. The 7 requirement IDs (TRANS-01, TRANS-02, TRANS-03, TRANS-04, PROTO-03, PROTO-04, TEST-03) are all implemented and confirmed by passing tests.

The sole minor finding is a documentation tracking inconsistency in REQUIREMENTS.md (3 of 7 requirement checkbox/status fields not updated to reflect completion). This is informational and does not require a gap plan.

---

_Verified: 2026-07-03_
_Verifier: Claude (gsd-verifier)_
