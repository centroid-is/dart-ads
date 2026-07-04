---
phase: 03-core-ads-commands-error-mapping
plan: 04
subsystem: api
tags: [ads, ams, dart, client, error-mapping, adsexception]

# Dependency graph
requires:
  - phase: 03-02
    provides: AdsException.fromCode error table + AdsState enum
  - phase: 03-03
    provides: AmsConnection.request() returning ({errorCode, payload}) record
  - phase: 01
    provides: per-command request encoders + response decoders in commands.dart
provides:
  - AdsClient with six named-parameter core-command methods (read/write/readWrite/readState/writeControl/readDeviceInfo)
  - AdsStateInfo and DeviceInfo typed value returns
  - Both-levels AdsException mapping (AMS errorCode pre-decode, payload result post-decode)
  - FakeTransport-driven client unit suite proving per-command mapping + both error levels
affects: [04-router, 05-notifications, 06-sum-commands, 07-symbols, 08-cli]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Client veneer over AmsConnection.request builds raw ADS payloads (post-header) and reuses Phase-1 decoders"
    - "Single AMS-level throw site (_command) + single payload-level throw site (_throwOnResult), both via AdsException.fromCode"

key-files:
  created:
    - lib/src/client/ads_client.dart
    - lib/src/client/ads_types.dart
    - test/unit/ads_client_test.dart
  modified:
    - lib/dart_ads.dart

key-decisions:
  - "target/source held on AdsClient as the Phase-4 router seam; AmsConnection still stamps addressing this phase (D-01)"
  - "readWrite returns the read bytes directly (D-ReadWrite-convenience)"
  - "writeControl data defaults to empty bytes (D-WriteControl-data)"
  - "AMS errorCode checked BEFORE payload decode so short/empty error frames never trip decoder length guards (T-3-02)"

patterns-established:
  - "AdsClient command methods: build payload -> _command (AMS-level throw) -> decode -> _throwOnResult (payload-level throw) -> typed return"
  - "Named test cases (read/write/read_write/read_state/write_control/device_info/result_error/ams_error) support -N filtering"

requirements-completed: [CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, CMD-06, ERR-01]

# Metrics
duration: 9min
completed: 2026-07-04
---

# Phase 3 Plan 04: AdsClient Core Commands & Error Mapping Summary

**Idiomatic async `AdsClient` exposing the six core ADS commands with named parameters and typed returns (`AdsStateInfo`, `DeviceInfo`), throwing `AdsException` at both the AMS-header and payload-result levels, proven against `FakeTransport`.**

## Performance

- **Duration:** ~9 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 4 (3 created, 1 modified)

## Accomplishments

- `AdsClient` veneer over `AmsConnection.request()` with all six core commands: `read`, `write`, `readWrite`, `readState`, `writeControl`, `readDeviceInfo` — each with locked named-parameter signatures.
- Uniform BOTH-levels error mapping: `_command` throws `AdsException.fromCode(errorCode)` on a non-zero AMS-header errorCode BEFORE decoding; each method throws `AdsException.fromCode(result)` on a non-zero decoded payload result AFTER decoding.
- Pure typed value returns: `AdsStateInfo` (mapped `AdsState` enum + raw `rawAdsState`/`deviceState` ints) and `DeviceInfo` (name + version/revision/build triple).
- Barrel now exports `AdsClient`, `AdsStateInfo`, `DeviceInfo`.
- 10-test FakeTransport suite covering per-command mapping and both error levels, including a pre-decode-ordering proof and distinctness from the transport/wire exception families.

## Task Commits

1. **Task 1: AdsClient command methods + AdsStateInfo/DeviceInfo** - `182a2c9` (feat)
2. **Task 2: Barrel exports + FakeTransport client unit tests** - `97ae17e` (test)

## Files Created/Modified

- `lib/src/client/ads_client.dart` - AdsClient with the six core command methods and the two uniform throw sites; builds raw ADS payloads (post-header) and reuses Phase-1 decoders.
- `lib/src/client/ads_types.dart` - Pure `AdsStateInfo` and `DeviceInfo` value types.
- `lib/dart_ads.dart` - Exports `AdsClient`, `AdsStateInfo`, `DeviceInfo`.
- `test/unit/ads_client_test.dart` - FakeTransport-driven client suite (per-command mapping + both error levels + distinctness).

## Decisions Made

- Reused the internal `protocol/range_check.dart` `checkUint` from the client's payload builders to mirror the encoder bodies exactly (silent-truncation guard on the wire fields), rather than duplicating range logic.
- Added an optional `timeout` named parameter to every command method (threads straight through to `AmsConnection.request`) — consistent with the connection's per-request timeout override, no behavioural change when omitted.
- Added an extra `read_state` test for the unknown/out-of-range wire value (`AdsState.unknown`) to lock in the tolerant `AdsState.fromCode` mapping.

## Deviations from Plan

None - plan executed exactly as written. The optional `timeout` parameter is an additive convenience within the locked signatures (all plan-specified named parameters are present and unchanged).

## Issues Encountered

None. `dart analyze --fatal-infos` is clean package-wide; all 91 unit tests pass (10 new client tests + 81 pre-existing).

## Known Stubs

None - no placeholder data, hardcoded empty returns, or unwired surfaces. Every command method returns real decoded device data.

## Next Phase Readiness

- Client command surface is complete and error-mapped; Phase 4's `AmsRouter` can construct/own `AdsClient` instances and take over source stamping via the held `target`/`source` seam without touching command-method bodies.
- Phase 5 notifications and Phase 6 sum commands build on the same `AdsClient` / `readWrite` foundation.
- Note (from Phase 3 plan set): integration tests per command against the C++ mock (write-back store + magic-indexGroup error fixture) and the TEST-05 C++ parity ports are the remaining Phase-3 coverage, delivered by sibling plans — not this plan.

## Self-Check: PASSED

- FOUND: lib/src/client/ads_client.dart
- FOUND: lib/src/client/ads_types.dart
- FOUND: test/unit/ads_client_test.dart
- FOUND commit: 182a2c9 (Task 1)
- FOUND commit: 97ae17e (Task 2)

---
*Phase: 03-core-ads-commands-error-mapping*
*Completed: 2026-07-04*
