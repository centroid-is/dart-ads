---
phase: 05-device-notifications-as-streams
plan: 04
subsystem: api
tags: [ads, notifications, streams, demux, dart, race-condition, containment]

# Dependency graph
requires:
  - phase: 05-01
    provides: AdsNotification value type, parseNotificationStream, decodeAddNotificationResponse, Add/Delete payload builders
  - phase: 02
    provides: AmsConnection (invoke-ID correlation, per-request timeout, _failClose disconnect fan-out)
provides:
  - "AmsConnection.addNotification with TRUE synchronous demux registration (onResponseSync hook fires inside _onFrame before completer.complete)"
  - "AmsConnection.deleteNotification (removes handle, fire-and-forget closes controller)"
  - "0x08 branch: parse + per-sample dispatch to _demuxControllers with local hostile-frame containment"
  - "droppedNotifications counter; _demuxControllers retyped to StreamController<AdsNotification>"
  - "PendingRequest.onResponseSync synchronous response hook"
affects: [05-05, subscribe-stream-orchestration, cli-subscribe]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Synchronous demux registration via a per-request onResponseSync hook (option A) — beats the same-chunk first-listen race"
    - "Per-frame error containment: local try/catch in the 0x08 branch isolates hostile notifications from the assembler-level _failClose"

key-files:
  created:
    - test/unit/connection/notification_demux_test.dart
  modified:
    - lib/src/connection/ams_connection.dart
    - lib/src/connection/pending_request.dart
    - lib/src/router/ams_router.dart
    - test/unit/ams_connection_test.dart

key-decisions:
  - "Option A (true synchronous registration inside _onFrame) over option B (holding buffer) — direct analogue of C++ CreateNotifyMapping, no buffering state"
  - "deleteNotification fire-and-forgets controller.close() — a single-subscription controller with no live listener never completes its close() future, so awaiting it would hang"

patterns-established:
  - "onResponseSync hook: request() side-effects that MUST run in the response-correlation turn (before the Future completes and before later same-chunk frames dispatch)"
  - "0x08 branch contains its own errors by design: MalformedFrameException from parse is swallowed + counted, never reaches the connect() listener's _failClose"

requirements-completed: [NOTIF-01, NOTIF-02, NOTIF-03]

# Metrics
duration: 22min
completed: 2026-07-04
---

# Phase 5 Plan 04: Notification Demux Fill Summary

**AmsConnection notification demux with true synchronous handle registration (onResponseSync hook closes the same-chunk first-listen race) and local hostile-frame containment via droppedNotifications, so one bad 0x08 frame cannot kill the connection.**

## Performance

- **Duration:** ~22 min
- **Completed:** 2026-07-04
- **Tasks:** 2 (both TDD)
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments
- `addNotification` registers its `StreamController<AdsNotification>` SYNCHRONOUSLY inside `_onFrame`'s response-correlation branch — via a new `PendingRequest.onResponseSync` hook invoked before `completer.complete`. A 0x08 frame arriving in the SAME inbound chunk as its Add-response is now delivered, not dropped (proven by the same-chunk race test).
- `deleteNotification` removes the handle from the demux map and closes its controller.
- The cmd 0x08 branch parses the nested stream and dispatches each sample to `_demuxControllers[handle]` (unknown handle silently ignored), wrapped in a LOCAL `try/catch` that increments `droppedNotifications` and never rethrows — a hostile frame is contained, the connection survives, and later good frames are still delivered.
- Existing `_failClose` fan-out now error-closes real `AdsNotification` controllers and clears the map on disconnect (verified by a two-handle disconnect test).

## Task Commits

1. **Task 1 (RED): failing sync-registration tests** - `b1f97b9` (test)
2. **Task 1 (GREEN): addNotification/deleteNotification + onResponseSync hook + dispatch** - `c85d68d` (feat)
3. **Task 2 (RED): dispatch/unknown/hostile/disconnect tests** - `f707a5c` (test)
4. **Task 2 (GREEN): local hostile-frame containment** - `b5bfa27` (feat)
5. **Formatting** - `bc2ea78` (style)

## Files Created/Modified
- `lib/src/connection/ams_connection.dart` - addNotification/deleteNotification, onResponseSync param on request(), filled 0x08 branch with containment, droppedNotifications counter, AdsNotification-typed demux map
- `lib/src/connection/pending_request.dart` - optional `onResponseSync` synchronous response hook
- `lib/src/router/ams_router.dart` - `_DirectTimeoutConnection.request` override updated to forward `onResponseSync` (Rule 3)
- `test/unit/ams_connection_test.dart` - existing 0x08 test now feeds a well-formed empty stream (Rule 3)
- `test/unit/connection/notification_demux_test.dart` - FakeTransport coverage for registration race, dispatch, unknown-handle ignore, hostile-frame containment, disconnect fan-out

## Decisions Made
- **Option A (true synchronous registration)** chosen exactly as the checker mandated: the controller is mapped in the `onResponseSync` hook that fires inside `_onFrame` before `completer.complete`. A post-`await` registration would run one microtask too late and drop a same-chunk notification.
- **Task 1 fills the 0x08 dispatch (happy-path); Task 2 adds the containment try/catch.** The race test (Task 1's own verify) requires a working dispatch to be observable, so the dispatch loop landed in Task 1 and the hostile-frame containment in Task 2 — giving Task 2 a genuine RED (the malformed frame tripped `_failClose` until the try/catch was added).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `_DirectTimeoutConnection.request` override signature mismatch**
- **Found during:** Task 1 (GREEN)
- **Issue:** Adding the `onResponseSync` named param to `AmsConnection.request` broke the `_DirectTimeoutConnection` subclass override in `ams_router.dart` (fewer named args than the overridden method), failing compilation across the test suite.
- **Fix:** Added the `onResponseSync` param to the override and forwarded it to `super.request`.
- **Files modified:** lib/src/router/ams_router.dart
- **Verification:** `dart analyze --fatal-infos` clean; full unit suite (166 tests) green.
- **Committed in:** c85d68d

**2. [Rule 3 - Blocking] Existing 0x08 test fed an unparseable empty payload**
- **Found during:** Task 1 (GREEN)
- **Issue:** `ams_connection_test.dart`'s "cmd 0x08 routes to demux" test fed a 0x08 frame with an EMPTY payload — valid only while the branch didn't parse. Once the branch parses, an empty payload throws `MalformedFrameException` and (pre-containment) tripped `_failClose`, breaking the regression test.
- **Fix:** Updated the test to feed a well-formed zero-stamp stream (`length=4, stamps=0`); a real PLC never sends an empty 0x08 payload, so this is the correct fixture.
- **Files modified:** test/unit/ams_connection_test.dart
- **Verification:** Regression test green.
- **Committed in:** c85d68d

**3. [Rule 1 - Bug] `deleteNotification` hang on unlistened controller close()**
- **Found during:** Task 1 (GREEN)
- **Issue:** `await _demuxControllers.remove(handle)?.close()` hung: a single-subscription `StreamController` with no live listener only completes its `close()` future once listened, so the await never returned (30s test timeouts).
- **Fix:** Fire-and-forget the close via `unawaited(...)` — the stream is done regardless; the caller need not observe teardown completion. (This also matches the plan's `.close()` without await.)
- **Files modified:** lib/src/connection/ams_connection.dart
- **Verification:** deleteNotification tests green.
- **Committed in:** c85d68d

---

**Total deviations:** 3 auto-fixed (all Rule 3/1 blocking or bug)
**Impact on plan:** All fixes necessary to compile and pass tests. No scope creep — the demux surface matches the plan's must-haves exactly.

## Issues Encountered
- The race test fundamentally requires a working 0x08 dispatch to be observable (without dispatch, sync vs async registration are indistinguishable). Resolved by landing the happy-path dispatch in Task 1 and the hostile-frame containment (the true Task 2 feature) in Task 2, preserving a real RED for Task 2.

## TDD Gate Compliance
Both tasks followed RED → GREEN. Task 1: test `b1f97b9` (compile-fail RED) → feat `c85d68d`. Task 2: test `f707a5c` (hostile-frame RED tripping `_failClose`) → feat `b5bfa27`.

## Verification
- `dart analyze --fatal-infos` — clean (whole project).
- `dart test test/unit/connection/notification_demux_test.dart` — green (registration race, 2x2 dispatch, unknown-handle ignore, hostile-frame containment, disconnect fan-out).
- `dart test test/unit/ams_connection_test.dart` — green (retype + hook did not break existing behavior).
- Full `dart test -t unit` — 166 tests, all pass.
- `grep -n "droppedNotifications" lib/src/connection/ams_connection.dart` — counter incremented inside the 0x08 catch (line 369).

## Next Phase Readiness
- The demux correctness core is complete: 05-05 can layer the `subscribe()` Stream orchestration (onListen → addNotification, onCancel → deleteNotification, disconnect discipline) on top of this without touching frame routing.
- No stubs. No blockers.

## Self-Check: PASSED

- FOUND: lib/src/connection/ams_connection.dart, lib/src/connection/pending_request.dart (modified)
- FOUND: test/unit/connection/notification_demux_test.dart (created)
- FOUND commits: b1f97b9, c85d68d, f707a5c, b5bfa27, bc2ea78

---
*Phase: 05-device-notifications-as-streams*
*Completed: 2026-07-04*
