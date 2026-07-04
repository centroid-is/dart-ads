---
phase: 03-core-ads-commands-error-mapping
plan: 02
subsystem: protocol
tags: [ads, error-mapping, exceptions, enum, dart, adsdef]

# Dependency graph
requires:
  - phase: 01-framing-codecs
    provides: "AdsState/AdsError int consts in constants.dart, sealed AdsResponse decoders (result field), golden_parity_test"
  - phase: 02-tcp-transport-connection
    provides: "AmsConnection.request() seam and the transport/wire exception families this must stay distinct from"
provides:
  - "lib/src/protocol/ads_error.dart: full AdsDef.h error table (global/router/device/client), adsErrorName/adsErrorText, and the AdsException family"
  - "AdsException with isDeviceError [0x0700,0x0740) and isClientError [0x0740,0x07FF] range helpers plus a synthetic unknown-code fallback"
  - "AdsState as an enhanced enum (members 0..19 + unknown sentinel, code field, tolerant fromCode)"
  - "Barrel exports for AdsException/adsErrorName/adsErrorText; AdsError name removed"
affects: [03-04-ads-client, 03-error-integration, phase-04-router-err-02]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Distinct exception families: AdsException (device/protocol) sits alongside MalformedFrameException (wire) and AdsTimeout/AdsConnectionException (transport)"
    - "Enhanced Dart enum with a wire `code` field + tolerant static fromCode returning an `unknown` sentinel instead of throwing"
    - "Const code->(name,text) record map with synthetic ADS-error-0x fallback for unknown/hostile codes"

key-files:
  created:
    - lib/src/protocol/ads_error.dart
    - test/unit/ads_error_test.dart
  modified:
    - lib/src/protocol/constants.dart
    - lib/dart_ads.dart
    - test/unit/golden_parity_test.dart

key-decisions:
  - "AdsState.unknown carries sentinel code -1 (never a valid u16) so it can never collide with a real wire state"
  - "adsErrorText returns 'unknown ADS error code' for misses; adsErrorName returns synthetic 'ADS error 0x{hex}' — never throws"
  - "AdsException is a flat class (code/name/message + range getters), no subtype tree (per CONTEXT ERR-01 v1 decision)"

patterns-established:
  - "Pattern 1: pure protocol/ error assets (no dart:async/dart:io) so the whole subtree stays isolation-testable"
  - "Pattern 2: verbatim AdsDef.h transcription preserving intentional gaps (0x0749 -> 0x0750) rather than inventing filler"

requirements-completed: [ERR-01]

# Metrics
duration: 9min
completed: 2026-07-04
---

# Phase 3 Plan 02: ADS Error Mapping Assets Summary

**A pure, distinct `AdsException` family backed by the full AdsDef.h error table with range helpers and an unknown-code fallback, plus a tolerant `AdsState` enum — all exported and unit-tested.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments
- Transcribed the complete AdsDef.h error table (global 0x0006–0x001A, router 0x0506–0x0508, device 0x0700–0x072F, client 0x0740–0x0755) into a pure `const` code→(name,text) map, preserving the intentional 0x0749→0x0750 gap.
- Added the `AdsException` family — a distinct type from the wire/transport exceptions — with `isDeviceError`/`isClientError` range helpers, `code` round-trip, and a synthetic fallback so unknown/hostile codes never throw (mitigates T-3-02).
- Converted `AdsState` from int consts to an enhanced enum (0..19 + `unknown(-1)` sentinel) with a tolerant `fromCode` that never throws on out-of-range values (mitigates T-3-04).
- Wired the public barrel and migrated the golden test to the enum; added a 10-test suite covering lookup, 0x745==1861, range boundaries, the gap, unknown fallback, and `AdsState.fromCode`.

## Task Commits

Each task was committed atomically:

1. **Task 1: ads_error.dart (table + AdsException) and AdsState enum** - `3f78494` (feat)
2. **Task 2: Wire barrel exports, fix golden test, add error-table unit tests** - `eba87ac` (feat)

## Files Created/Modified
- `lib/src/protocol/ads_error.dart` - Full ADS error table, `adsErrorName`/`adsErrorText`, and the `AdsException` family (created)
- `test/unit/ads_error_test.dart` - 10 tests: lookup, 1861, range boundaries, gap, unknown fallback, `AdsState.fromCode` (created)
- `lib/src/protocol/constants.dart` - `AdsState` int consts → enhanced enum; removed superseded partial `AdsError` class (modified)
- `lib/dart_ads.dart` - Export `AdsException`/`adsErrorName`/`adsErrorText`; drop `AdsError` from constants export (modified)
- `test/unit/golden_parity_test.dart` - `AdsState.run` → `AdsState.run.code` at the two int usages (modified)

## Decisions Made
- `AdsState.unknown` uses sentinel `code -1` (never a valid u16) so `fromCode` can distinguish it from any real wire state.
- Kept `AdsException` flat (no subtype tree) per the CONTEXT ERR-01 v1 decision; callers branch on `code`/`isDeviceError`/`isClientError`.
- `adsErrorText` returns a generic `unknown ADS error code` message on a miss while `adsErrorName` returns the synthetic `ADS error 0x{hex}` identifier.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. Task 1's `dart analyze` is scoped to the two new files by design (the barrel still referenced the removed `AdsError` at that point); the full-package analysis and 81-test unit suite both pass after Task 2 restored barrel consistency.

## TDD Note
Task 1 is tagged `tdd="true"`, but the plan assigns the behavior tests (`test/unit/ads_error_test.dart`) to Task 2 — a same-package test cannot reference `ads_error.dart` until it exists. The two tasks were executed in plan order (implementation → tests+exports); all Task 1 `<behavior>` assertions are covered by the Task 2 suite, which passes green.

## Threat Coverage
- **T-3-02 (AdsException.fromCode):** unknown/hostile codes get a synthetic name and never throw — verified by the unknown-code test (0xABCD) and the 0x074A gap test.
- **T-3-04 (AdsState.fromCode):** out-of-range u16 (20, 9999, -7) falls back to `unknown` — verified by the tolerant-fallback tests.

## Next Phase Readiness
- The pure error family and `AdsState` enum are ready for the `AdsClient` (03-04) to compose `AdsException.fromCode` at both the AMS-errorCode and payload-`result` levels.
- ERR-02's actionable 1861/source-NetId message remains deferred to Phase 4 (router owns source stamping), as planned.

## Self-Check: PASSED

- FOUND: lib/src/protocol/ads_error.dart
- FOUND: test/unit/ads_error_test.dart
- FOUND: .planning/phases/03-core-ads-commands-error-mapping/03-02-SUMMARY.md
- FOUND commit: 3f78494 (Task 1)
- FOUND commit: eba87ac (Task 2)
- FOUND commit: 5f82122 (SUMMARY)

---
*Phase: 03-core-ads-commands-error-mapping*
*Completed: 2026-07-04*
