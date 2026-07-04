---
phase: 03-core-ads-commands-error-mapping
plan: 06
subsystem: testing
tags: [dart-test, integration, ads, parity, adslibtest, invoke-id, timeout]

# Dependency graph
requires:
  - phase: 03-01
    provides: extended C++ mock (data store, magic error groups, stateful WriteControl/ReadState)
  - phase: 03-04
    provides: AdsClient (six core commands) + AmsConnection.request errorCode seam
provides:
  - test/integration/ads_parity_test.dart — ten 1:1 C++-named AdsLibTest scenario ports
  - Mechanical Phase-9 audit surface (group names == C++ method names)
affects: [phase-09-parity-audit, phase-04-router, phase-05-notifications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "1:1 C++-scenario-named test groups for mechanical parity auditing"
    - "Fresh mock+connection per group for connection-scoped store isolation"
    - "Pipelined Future.wait fan-out to prove invoke-ID correlation under load"

key-files:
  created:
    - test/integration/ads_parity_test.dart
  modified: []

key-decisions:
  - "Adapted C++ port-handle error cases (PORTNOTOPEN/NOAMSADDR) to Dart connection lifecycle, documented as covered-by-equivalent (Phase-2 live test)"
  - "testAdsTimeout adapts the C++ get/set-timeout config API to a real per-request timeout firing against an unanswered unknown-command request"
  - "testLargeFrames implements a genuine 64 KiB round-trip, exceeding the C++ unimplemented stub"

patterns-established:
  - "Parity ports assert OUR mock fixtures (Dart ADS Mock, v3.1 build 4024, RUN), not upstream Beckhoff identities"
  - "Every parity request carries a long timeout so a failure is provably a command result, not a timeout (threat T-3-07)"

requirements-completed: [TEST-05, CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, CMD-06]

# Metrics
duration: 9min
completed: 2026-07-04
---

# Phase 3 Plan 06: AdsLibTest Parity Port Summary

**Ten 1:1 C++-named Dart ports of the Phase-3-applicable Beckhoff AdsLibTest scenarios (core commands + timeout + large frames + parallel), green against the live C++ mock.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 1 (created)

## Accomplishments
- Ported the seven core-command scenarios (testAdsReadReqEx2, ...LargeBuffer, ReadDeviceInfo, ReadState, ReadWrite, Write, WriteControl) with 1:1 C++ group names for the Phase-9 mechanical audit.
- Ported the three remaining scenarios: testAdsTimeout (unanswered request → AdsTimeoutException), testLargeFrames (64 KiB round-trip, exceeding the C++ stub), testParallelReadAndWrite (100 pipelined concurrent ops proving invoke-ID correlation under load).
- Documented every C++→Dart adaptation (port handles → connection lifecycle; MISSING_ROUTE → Phase-4 N/A; invalid-group → injectable SRVNOTSUPP; identity fixtures) in a file header for the audit.
- Full suite green: 113 tests, all ten new parity scenarios passing.

## Task Commits

Each task was committed atomically:

1. **Task 1: Port the seven core-command AdsLibTest scenarios** - `d1c6246` (test)
2. **Task 2: Port testAdsTimeout, testLargeFrames, testParallelReadAndWrite** - `73c11f1` (test)

**Plan metadata:** (this commit) (docs: complete plan)

## Files Created/Modified
- `test/integration/ads_parity_test.dart` - Ten `@Tags(['integration'])` groups named 1:1 after their C++ AdsLibTest counterparts, each round-tripping against a fresh live mock; header comment maps every Dart group to its C++ scenario and records the adaptation rules.

## Decisions Made
- **Port-handle error cases → connection lifecycle:** the C++ scenarios' PORTNOTOPEN/NOAMSADDR assertions have no Dart analogue (no port-handle concept); documented as covered-by-equivalent by the Phase-2 `ams_connection_live_test` rather than re-asserted.
- **testAdsTimeout via unknown command:** the mock silently ignores an unknown command id (0x00EE), so a short-timeout `connection.request` deterministically surfaces `AdsTimeoutException` — the Dart expression of the C++ timeout-config knob actually firing.
- **testLargeFrames exceeds the stub:** the C++ original is `fructose_assert(false)`; the Dart port does a real 64 KiB write/read integrity check (below the 4 MiB assembler cap, threat T-3-05 boundary).
- **testParallelReadAndWrite:** reads target the stable seeded fixture (0xF005,0x123)=42 so a mis-correlated response is detectable, while writes fan out to distinct keys; spot-checks confirm the writes landed too.

## Deviations from Plan

None - plan executed exactly as written.

(One non-code adjustment: `dart format` reflowed two lines after an inline edit; applied before the Task 2 commit to keep the CI format gate green. Not a behavioral deviation.)

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 3 command + error-mapping surface is now covered by both the ads_client integration tests (03-05) and this AdsLibTest parity port (03-06); this is the final plan of Phase 3.
- The 1:1 named groups give Phase 9 a mechanical grep target to confirm the Phase-3 slice of TEST-05.
- Phase 4 (router) inherits the documented MISSING_ROUTE / unknown-AmsAddr scenarios as its own parity targets.

---
*Phase: 03-core-ads-commands-error-mapping*
*Completed: 2026-07-04*
