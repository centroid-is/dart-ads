---
phase: 03-core-ads-commands-error-mapping
verified: 2026-07-04T00:00:00Z
status: passed
score: 4/4
overrides_applied: 0
re_verification: false
---

# Phase 3: Core ADS Commands & Error Mapping — Verification Report

**Phase Goal:** Users can issue the full core ADS command set through an idiomatic async Dart API, with every ADS error surfaced as a typed exception.
**Verified:** 2026-07-04
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can Read, Write, and ReadWrite bytes at (indexGroup, indexOffset, length) with correct results verified against the mock server | VERIFIED | `AdsClient.read/write/readWrite` with named params; `ads_client_test.dart` tests `read`, `write`, `read_write` pass live; parity tests `testAdsReadReqEx2`, `testAdsReadReqEx2LargeBuffer`, `testAdsWriteReqEx`, `testAdsReadWriteReqEx2` pass |
| 2 | User can read device state (ReadState) and device info (ReadDeviceInfo), and set state via WriteControl | VERIFIED | `AdsClient.readState/readDeviceInfo/writeControl` implemented; `read_state`, `device_info`, `write_control` integration tests pass; `write_control` test proves `WriteControl(STOP)` observable via `ReadState` |
| 3 | Every ADS error code carried in a response maps to a typed Dart exception distinct from transport/timeout errors | VERIFIED | `AdsException` (distinct from `AdsTimeoutException`/`AdsConnectionException`/`MalformedFrameException`); `_command` throws pre-decode on AMS errorCode; `_throwOnResult` throws post-decode on payload result; `result_error` and `ams_error` integration tests pass; `ads_error_test.dart` + `ads_client_test.dart` unit tests green |
| 4 | Each core command has an integration test passing against the mock server | VERIFIED | 8 per-command integration tests in `ads_client_test.dart`; 10 C++-named parity scenarios in `ads_parity_test.dart`; 113/113 total tests pass |

**Score:** 4/4 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `test_harness/mock_server.cpp` | All 6 core commands + 2 magic error groups + wrapResponse amsError param | VERIFIED | READ/WRITE/READ_WRITE/READ_STATE/WRITE_CONTROL switch cases present; `kErrResultGroup=0xE7700000`, `kErrAmsGroup=0xE7700001`; `wrapResponse` has defaulted `amsError=0` param; connection-scoped store declared inside per-connection block |
| `lib/src/protocol/ads_error.dart` | Full AdsDef.h error table, `AdsException`, `adsErrorName/adsErrorText` | VERIFIED | 274-line file; full table (global/router/device/client ranges); `AdsException implements Exception`; range helpers `isDeviceError`/`isClientError`; 0x0749→0x0750 gap preserved; synthetic fallback for unknown codes |
| `lib/src/protocol/constants.dart` | `AdsState` as enhanced enum (0..19 + unknown(-1), code field, tolerant fromCode) | VERIFIED | `enum AdsState` with members `invalid(0)..exception(19)` + `unknown(-1)`; `AdsState.fromCode` returns `unknown` for out-of-range values |
| `lib/src/connection/ams_connection.dart` | `request()` returning `({int errorCode, Uint8List payload})` | VERIFIED | Line 145: `Future<({int errorCode, Uint8List payload})> request(...)` declared; `_onFrame` completes with `(errorCode: header.errorCode, payload: ...)` at line 281 |
| `lib/src/connection/pending_request.dart` | Completer retyped to the record type | VERIFIED | Line 33: `final Completer<({int errorCode, Uint8List payload})> completer` |
| `lib/src/client/ads_client.dart` | `AdsClient` with 6 named-parameter command methods + both-levels throw | VERIFIED | 200-line file; all 6 methods; `_command` checks `errorCode != 0` pre-decode; `_throwOnResult` checks result post-decode; no `ads_error` import in transport layer (transport-pure) |
| `lib/src/client/ads_types.dart` | `AdsStateInfo` (enum + raw ints) + `DeviceInfo` (name + version triple) | VERIFIED | `AdsStateInfo(adsState, rawAdsState, deviceState)` and `DeviceInfo(name, version, revision, build)` as pure value types |
| `lib/dart_ads.dart` | Exports `AdsClient`, `AdsStateInfo`, `DeviceInfo`, `AdsException`, `adsErrorName`, `adsErrorText` | VERIFIED | Lines 92-100 confirm all exports; `AdsError` (removed class) not exported |
| `test/unit/ads_error_test.dart` | Error-table lookup, 1861, range boundaries, gap, unknown fallback, AdsState.fromCode | VERIFIED | 127-line file; 10 test cases covering all specified behaviors; all green |
| `test/unit/ads_client_test.dart` | Per-command mapping + both error levels via FakeTransport | VERIFIED | 315-line file; tests for read/write/read_write/read_state/write_control/device_info + result_error/ams_error + distinctness; all green |
| `test/integration/ads_client_test.dart` | 8 integration tests (per-command + both error levels) | VERIFIED | All 8 tests (read, write, read_write, read_state, write_control, device_info, result_error, ams_error) pass against live mock |
| `test/integration/ads_parity_test.dart` | 10 named parity scenarios matching C++ AdsLibTest method names | VERIFIED | All 10 groups (testAdsReadReqEx2, testAdsReadReqEx2LargeBuffer, testAdsReadDeviceInfoReqEx, testAdsReadStateReqEx, testAdsReadWriteReqEx2, testAdsWriteReqEx, testAdsWriteControlReqEx, testAdsTimeout, testLargeFrames, testParallelReadAndWrite) pass |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `runServer switch(aoe.cmdId())` | connection-scoped store + `curAdsState` | per-command handlers (READ/WRITE/READ_WRITE/READ_STATE/WRITE_CONTROL cases) | WIRED | Cases present at lines 529–646 of mock_server.cpp; store declared inside accept-loop body |
| `_onFrame` | `PendingRequest completer` | `completes with (errorCode: header.errorCode, payload: ...)` | WIRED | Line 281: `pending.completer.complete((errorCode: header.errorCode, payload: ...))` |
| `AdsClient._command` | `AdsException.fromCode` | `if (response.errorCode != 0) throw AdsException.fromCode(response.errorCode)` | WIRED | Lines 186–188 of ads_client.dart; AMS-level throw site confirmed |
| `AdsClient` command methods | `_throwOnResult` after decode | `AdsException.fromCode(result)` payload-level throw site | WIRED | `_throwOnResult` invoked in all 6 command methods; lines 82, 100, 123, 135, 159, 172 |
| `ads_client_test.dart` | `startMockServer + AdsClient` | live loopback socket | WIRED | `connectClient()` helper spawns mock, opens `SocketTransport`, wraps in `AdsClient` |
| `ads_parity_test.dart group names` | C++ AdsLibTest scenario names | 1:1 named Dart groups for Phase-9 audit | WIRED | All 10 group names match C++ method names verbatim |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `ads_client_test.dart` | `AdsClient.read()` result | live C++ mock server via loopback socket | Yes — seeded store `(0xF005,0x123)=0x2A000000` returned by mock READ handler | FLOWING |
| `ads_parity_test.dart` | `readDeviceInfo()` fields | C++ mock `buildReadDeviceInfoRes` | Yes — name='Dart ADS Mock', v3.1 build 4024 hardcoded in mock; asserted exact in test | FLOWING |
| `ads_client.dart._command` | `response.errorCode` | `AmsConnection.request()` record from `_onFrame` | Yes — `header.errorCode` read from decoded AMS header, threaded through PendingRequest completer | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| mock_server --selftest byte-accuracy | `test_harness/build/mock_server --selftest` | `OK` (exit 0) | PASS |
| dart analyze clean | `dart analyze --fatal-infos` | `No issues found!` | PASS |
| Unit test suite | `dart test -x integration` | `+91 All tests passed!` | PASS |
| Integration test suite | `dart test -t integration` | `+22 All tests passed!` | PASS |
| Full suite | `dart test` | `+113 All tests passed!` | PASS |

---

### Probe Execution

| Probe | Command | Result | Status |
|-------|---------|--------|--------|
| mock_server selftest | `test_harness/build/mock_server --selftest` | exit 0, printed `OK` | PASS |

---

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| CMD-01 | 03-01, 03-04, 03-05, 03-06 | User can Read bytes at (indexGroup, indexOffset, length) | SATISFIED | `AdsClient.read` + `test_harness/mock_server.cpp` READ case; integration test `read` passes |
| CMD-02 | 03-01, 03-04, 03-05, 03-06 | User can Write bytes at (indexGroup, indexOffset) | SATISFIED | `AdsClient.write` + mock WRITE case; integration test `write` + read-back passes |
| CMD-03 | 03-01, 03-04, 03-05, 03-06 | User can ReadWrite in one round-trip | SATISFIED | `AdsClient.readWrite` + mock READ_WRITE case; integration test `read_write` passes |
| CMD-04 | 03-01, 03-04, 03-05, 03-06 | User can read device state (ReadState) | SATISFIED | `AdsClient.readState` returns `AdsStateInfo`; integration test `read_state` passes |
| CMD-05 | 03-01, 03-04, 03-05, 03-06 | User can set device state via WriteControl | SATISFIED | `AdsClient.writeControl` + stateful mock; `write_control` test proves observable state change |
| CMD-06 | 03-04, 03-05, 03-06 | User can read device info (name + version) | SATISFIED | `AdsClient.readDeviceInfo` returns `DeviceInfo`; integration test `device_info` passes |
| ERR-01 | 03-02, 03-03, 03-04, 03-05 | ADS error codes map to typed Dart exceptions distinct from transport errors | SATISFIED | `AdsException` implemented; both error levels verified live; unit + integration tests pass. Note: REQUIREMENTS.md still shows ERR-01 as `[ ]` Pending — documentation needs updating |
| TEST-05 (partial) | 03-06 | Phase-3-applicable AdsLibTest scenarios have Dart counterparts | SATISFIED (partial) | 10 named parity groups in `ads_parity_test.dart` covering Phase-3 command/timeout/large-frame/parallel scenarios; full TEST-05 audit deferred to Phase 9 |

**Note on ERR-01 documentation:** The code fully implements ERR-01 (distinct `AdsException` family, full error table, both-levels throw, tested). However, `REQUIREMENTS.md` line 35 still shows `- [ ] ERR-01` (unchecked) and the traceability table at line 149 says `Pending`. This is a documentation housekeeping gap — the implementation is complete and verified. REQUIREMENTS.md should be updated to `- [x] ERR-01` / `Complete`.

---

### Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| (none) | — | — | — |

Scanned files: `mock_server.cpp`, `ads_error.dart`, `ams_connection.dart`, `pending_request.dart`, `ads_client.dart`, `ads_types.dart`, `dart_ads.dart`, `ads_error_test.dart`, `ads_client_test.dart` (unit + integration), `ads_parity_test.dart`. No `TBD`/`FIXME`/`XXX`/`TODO`/`HACK`/`PLACEHOLDER`/`return null` anti-patterns found. No stubs, no hardcoded empty returns, no disconnected data flows.

---

### Human Verification Required

None. All success criteria are verifiable programmatically. The previously deferred CI-on-GitHub item is documented in `01-HUMAN-UAT.md` and not re-raised here per context instructions.

---

## Gaps Summary

No gaps. All four ROADMAP success criteria are verified against actual code and passing tests. The ERR-01 documentation inconsistency in REQUIREMENTS.md is a housekeeping item (update the checkbox and traceability status to Complete) but does not affect goal achievement.

---

_Verified: 2026-07-04T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
