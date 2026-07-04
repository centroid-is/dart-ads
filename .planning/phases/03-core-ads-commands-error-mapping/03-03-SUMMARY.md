---
phase: 03-core-ads-commands-error-mapping
plan: 03
subsystem: api
tags: [ads, ams, transport, records, error-handling, dart]

# Dependency graph
requires:
  - phase: 02-tcp-transport-connection-lifecycle
    provides: AmsConnection with invoke-ID correlation, timeout, and disconnect fan-out
  - phase: 03-core-ads-commands-error-mapping (plan 02)
    provides: AdsException family + ADS error table (the mapping site the client will use)
provides:
  - "request() resolves to a record ({int errorCode, Uint8List payload}), surfacing the AMS-header errorCode"
  - "_onFrame passes header.errorCode through instead of discarding it"
  - "PendingRequest.completer retyped to the record; transport stays error-table-free"
affects: [03-04-ads-client, ads-client, error-mapping, read, write, readwrite, readstate, writecontrol]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Dart records as the transport→client return shape (house style)"
    - "Transport-pure layering: AmsConnection surfaces the raw AMS errorCode; the ADS error table stays in protocol/ and mapping stays in the client"

key-files:
  created: []
  modified:
    - lib/src/connection/ams_connection.dart
    - lib/src/connection/pending_request.dart
    - test/unit/ams_connection_test.dart
    - test/integration/ams_connection_live_test.dart
    - test/integration/socket_transport_test.dart

key-decisions:
  - "request() returns Future<({int errorCode, Uint8List payload})> (record) rather than a named value type — records are the house style and no public type is warranted for an internal seam"
  - "AmsConnection surfaces the raw AMS errorCode without interpreting it; mapping to AdsException stays entirely in the client (03-04), keeping L4 transport-pure"

patterns-established:
  - "errorCode record seam: every command response now carries both error levels (AMS header + payload result) to a single client-side mapping site"

requirements-completed: [ERR-01]

# Metrics
duration: 2min
completed: 2026-07-04
---

# Phase 3 Plan 3: Surface AMS errorCode from request() Summary

**`AmsConnection.request()` now resolves to a `({int errorCode, Uint8List payload})` record, surfacing the AMS-header errorCode that was previously discarded in `_onFrame` — unblocking the client's both-levels ADS error throw (ERR-01) without pulling the error table into the transport core.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-07-04T10:34:05Z
- **Completed:** 2026-07-04T10:36:16Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Changed `request()` return type to a record carrying the AMS `errorCode` alongside the payload; `_onFrame` now passes `header.errorCode` through instead of dropping it.
- Retyped `PendingRequest.completer` to the record type; `_failClose`'s error fan-out is unchanged (errors carry no record).
- Preserved every transport invariant: demux-before-lookup, remove-wins claim, dropped-response counting, command-mismatch error, timeout, and single-shot disconnect fan-out.
- Updated all three in-repo callers and added a `.errorCode == 0` unit assertion on a success response; full package `dart analyze --fatal-infos` is clean and the unit suite is green (10/10).

## Task Commits

Each task was committed atomically:

1. **Task 1: Surface AMS errorCode from request(), update PendingRequest and _onFrame** - `3dc3969` (feat)
2. **Task 2: Update the two existing request() callers** - `e6f4ac2` (test)
3. **Deviation (Rule 3): Update the third request() caller (socket_transport_test.dart)** - `315ccfd` (test)

**Plan metadata:** committed with this SUMMARY (docs: complete plan)

## Files Created/Modified
- `lib/src/connection/ams_connection.dart` - `request()` returns the errorCode record; `_onFrame` completes with `(errorCode: header.errorCode, payload: <slice>)`; class/method docs updated.
- `lib/src/connection/pending_request.dart` - `completer` retyped to `Completer<({int errorCode, Uint8List payload})>`.
- `test/unit/ams_connection_test.dart` - `await f` sites read `.payload`; correlation test asserts `.errorCode == 0` on success responses.
- `test/integration/ams_connection_live_test.dart` - `r1`/`r2` are records; `.payload` fed to `decodeReadDeviceInfoResponse`.
- `test/integration/socket_transport_test.dart` - both round-trip sites read `.payload` before decoding (deviation fix).

## Decisions Made
- `request()` returns a Dart record (`({int errorCode, Uint8List payload})`) rather than a named value type — records are the established house style and this is an internal transport→client seam, not public API.
- The connection surfaces the raw AMS errorCode only; it imports nothing from `protocol/ads_error.dart`. All ADS-error interpretation stays in the client (03-04), so the transport core keeps a single responsibility.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Updated a third request() caller the plan did not list**
- **Found during:** Post-Task-2 repo-wide caller sweep
- **Issue:** `test/integration/socket_transport_test.dart` calls `conn.request(...)` at two sites and passes the result straight to `decodeReadDeviceInfoResponse`. The plan's `<interfaces>` enumerated only the unit test and the live test; leaving this file would break compilation of the integration suite (the record has no implicit `Uint8List` conversion) — a verify-ordering violation (a task must reference only files that compile at its completion).
- **Fix:** Read `.payload` from the returned record before decoding at both sites.
- **Files modified:** test/integration/socket_transport_test.dart
- **Verification:** `dart analyze test/integration/socket_transport_test.dart --fatal-infos` clean; full-package `dart analyze --fatal-infos` clean.
- **Committed in:** `315ccfd`

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Necessary to keep the whole package compiling under the new signature. No scope creep — a mechanical `.payload` read identical to the plan's prescribed caller updates.

## Issues Encountered
None — the signature change was purely additive to the completed value; all existing correlation/timeout/fan-out tests passed unchanged.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The errorCode seam is in place: 03-04's `AdsClient` can now throw at BOTH levels — `if (errorCode != 0) throw AdsException.fromCode(errorCode)` on the AMS header, then again on a non-zero decoded payload `result`.
- The live integration test (`ams_connection_live_test.dart`) compiles against `.payload` but is not run here — it exercises the mock and lands in a later wave.
- No blockers.

## Self-Check: PASSED
- FOUND: lib/src/connection/ams_connection.dart (modified, analyze clean)
- FOUND: lib/src/connection/pending_request.dart (modified, analyze clean)
- FOUND commit 3dc3969, e6f4ac2, 315ccfd
- Unit suite: 10/10 passing

---
*Phase: 03-core-ads-commands-error-mapping*
*Completed: 2026-07-04*
