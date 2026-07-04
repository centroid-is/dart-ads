---
phase: 05-device-notifications-as-streams
plan: 06
subsystem: testing
tags: [dart, notifications, integration-test, parity, mock-server, leak-proof, slow-tag]

# Dependency graph
requires:
  - phase: 05-02
    provides: C++ mock notification support (magic count group 0xE7700002, 2x2 group, write-triggered emission, --notify-burst)
  - phase: 05-04
    provides: AmsConnection.addNotification/deleteNotification + synchronous demux registration + droppedNotifications/isConnected observables
  - phase: 05-05
    provides: AdsClient.subscribe() Stream<AdsNotification> lifecycle
provides:
  - "End-to-end notification integration proof over the live C++ mock: lifecycle, first-listen race, hostile-frame containment, transmission modes"
  - "testManyNotifications deterministic no-handle-leak proof (count 0 -> N -> 0 via the in-band active-handle-count group)"
  - "testEndurance (slow) sustained register/receive/cancel soak, excluded from the default suite"
  - "`slow` tag declared in dart_test.yaml (skip-by-default, runnable via --run-skipped)"
  - "Mock hostile-frame trigger group 0xE7700004 + burst-after-response ordering fix"
affects: [phase-9-parity-audit, cli-subscribe]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Bounded waitUntil() polling helper (never an unbounded await) for socket-timed integration assertions"
    - "In-band active-handle-count assertion (0 -> N -> 0) as a deterministic leak proof instead of a throughput number"
    - "C++-named group(...) per AdsLibTest method for mechanical Phase-9 parity audit"
    - "slow tag = skip-by-default + `dart test -t slow --run-skipped` for on-demand soak runs"

key-files:
  created:
    - test/integration/ads_notification_test.dart
    - test/integration/notification_parity_test.dart
  modified:
    - dart_test.yaml
    - test_harness/mock_server.cpp

key-decisions:
  - "Use `skip:` on the `slow` tag (not plain declaration) so the endurance soak is excluded from EVERY default/CI path (bare `dart test`, `-x integration`, `-t integration`) while staying runnable via `--run-skipped` — the only package:test mechanism satisfying both constraints"
  - "Reorder the mock's --notify-burst emission to AFTER the Add-response: burst-before-response is unroutable by ANY client (handle unknown until the response), so the winnable same-chunk race the implemented synchronous registration solves requires burst-after-response"
  - "Add a dedicated mock hostile group (0xE7700004) emitting one malformed 0x08 frame rather than trying to coax a bad frame from existing hooks — the must-have hostile-frame survival proof had no existing trigger"

patterns-established:
  - "Integration leak proof: read magic count group before/during/after, assert 0/N/0"
  - "Per-subscription distinct-offset fan-out proves no cross-talk in the demux map"

requirements-completed: [NOTIF-02, NOTIF-04, TEST-05]

# Metrics
duration: 20min
completed: 2026-07-04
---

# Phase 5 Plan 6: Notification Integration + Parity Ports Summary

**End-to-end notification proof over the live C++ mock — lifecycle, first-listen race, hostile-frame containment, both transmission modes, and a deterministic no-handle-leak proof (count 0→64→0), with the endurance soak tagged `slow` and excluded by default.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-07-04T14:08Z
- **Completed:** 2026-07-04T14:28Z
- **Tasks:** 2
- **Files modified:** 4 (2 created, 2 modified)

## Accomplishments
- `testAdsNotification` (C++-named): subscribe against a mock-known (0x4020,4), receive ≥1 notification carrying the written data + a UTC timestamp, cancel→Delete, and verify no further delivery.
- `testManyNotifications`: 64 concurrent subscriptions on distinct offsets each receive their OWN sample (no cross-talk), with the in-band active-handle count asserted 0 before, 64 during, and 0 after cancelling all — a deterministic leak proof (NOTIF-02, T-5-01).
- First-listen race, hostile-frame containment (droppedNotifications++ / connection alive / later good frame delivered), and serverOnChange-vs-serverCycle delivery all proven end-to-end over the socket.
- `testEndurance` tagged `slow` (50× register/receive/cancel loop re-proving count→0); excluded from the default suite, runnable via `dart test -t slow --run-skipped`.

## Task Commits

1. **Task 1: `slow` tag + testAdsNotification / race / hostile / transmission modes** - `49387a9` (test)
2. **Task 2: testManyNotifications leak proof + testEndurance (slow)** - `e3b0abe` (test)

**Plan metadata:** committed separately (docs).

## Files Created/Modified
- `test/integration/ads_notification_test.dart` - testAdsNotification lifecycle + first-listen-race + hostile-frame + transmission-mode groups (332 lines).
- `test/integration/notification_parity_test.dart` - testManyNotifications leak proof + testEndurance (slow) (232 lines).
- `dart_test.yaml` - declares the `slow` tag (skip-by-default; run via `--run-skipped`).
- `test_harness/mock_server.cpp` - burst-after-response reordering + hostile magic group 0xE7700004.

## Decisions Made
- **`slow` tag exclusion mechanism:** `skip:` + `--run-skipped` is the only package:test approach that both excludes the soak from every default/CI run AND keeps it runnable on demand (`-t slow` alone cannot un-skip; `exclude_tags`/top-level exclusion blocks `-t slow` too — both verified empirically).
- **Mock burst ordering:** emit `--notify-burst` frames after the Add-response so the same-chunk race is winnable by the implemented option-A synchronous registration.
- **Hostile trigger:** a dedicated malformed-frame group is cleaner and deterministic vs. coaxing existing hooks.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Mock `--notify-burst` emitted BEFORE the Add-response (unwinnable race)**
- **Found during:** Task 1 (first-listen race group)
- **Issue:** The mock emitted burst notifications before sending the Add-response. Empirically (probe test) this delivered 0 notifications: the client only learns the handle from the response, so a notification arriving before it is unroutable by ANY client, including the implemented option-A synchronous-registration design. The race group could not pass as written.
- **Fix:** Reordered the ADD handler to send the Add-response first, then emit the burst frames back-to-back (same-chunk / after-response) — the winnable same-chunk race that synchronous registration solves. Probe then delivered all 3; `droppedNotifications` stayed 0.
- **Files modified:** test_harness/mock_server.cpp
- **Verification:** `first-listen race` group green; empirical probe confirmed received=3, dropped=0.
- **Committed in:** `49387a9` (Task 1 commit)

**2. [Rule 2 - Missing Critical] Mock had no hostile-frame trigger**
- **Found during:** Task 1 (hostile notification frame group)
- **Issue:** must-have #4 requires proving a hostile 0x08 frame is dropped while the connection survives, but the mock had no mechanism to emit a malformed notification frame — every emission path produced well-formed frames.
- **Fix:** Added magic write group `0xE7700004` (`kNotifyHostileGroup`) + `emitHostileNotification()` that sends one 0x08 frame whose AMS/TCP wrapper is well-formed (so it reaches the parser as a complete frame) but whose single sample declares size `0xFFFFFFFF`, overrunning the payload → `parseNotificationStream` throws → the 0x08 dispatch contains it (`droppedNotifications++`).
- **Files modified:** test_harness/mock_server.cpp
- **Verification:** `hostile notification frame` group green (droppedNotifications≥1, isConnected true, subsequent good notification delivered); mock `--selftest` OK; goldens unchanged.
- **Committed in:** `49387a9` (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (1 bug, 1 missing critical) — both in the mock (`test_harness/mock_server.cpp`, beyond the plan's listed test files but required for the must-haves).
**Impact on plan:** Both mock changes are additive/ordering-only, gated behind synthetic magic groups / the `--notify-burst` flag; no existing test, golden, or selftest affected (full suite `-x slow` = 206 passed; goldens reproduce byte-identically). No scope creep.

## Issues Encountered
- `package:test` `slow`-tag semantics: `skip` cannot be overridden by `-t slow` (needs `--run-skipped`); a top-level `exclude_tags: slow` also blocks `-t slow`. Resolved by choosing `skip:` + `--run-skipped`, which alone satisfies "excluded from the default suite yet runnable on demand" (all three behaviors verified in a scratch project).

## Verification Results
- Task 1: `dart test -t integration test/integration/ads_notification_test.dart -n "testAdsNotification|race|hostile|transmission"` → 5 passed.
- Task 2: `dart test -t integration test/integration/notification_parity_test.dart -n "testManyNotifications"` → 1 passed; `grep slow` + `grep testEndurance` present.
- `dart test -t slow --run-skipped -n testEndurance` → passes manually.
- `dart test -t integration <both files>` → 6 passed, 1 skipped (testEndurance excluded by default).
- Full suite `dart test -x slow` → 206 passed; mock `--selftest` OK; goldens reproduce with no drift.

## Next Phase Readiness
- Phase 5 (Device Notifications as Streams) is complete: NOTIF-01..04 delivered and proven end-to-end; the TEST-05 notification slice (testAdsNotification, testManyNotifications, testEndurance) is ported with C++-named groups for the Phase-9 mechanical parity audit.
- No blockers. The `slow`-tag convention is now available for future long-running soak tests.

## Self-Check: PASSED

---
*Phase: 05-device-notifications-as-streams*
*Completed: 2026-07-04*
