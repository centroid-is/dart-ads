---
phase: 05-device-notifications-as-streams
plan: 05
subsystem: api
tags: [dart, streams, notifications, ads, subscribe, lifecycle, stream-controller]

# Dependency graph
requires:
  - phase: 05-01
    provides: buildAddNotificationPayload / buildDeleteNotificationPayload / AdsTransmissionMode / AdsNotification (pure protocol)
  - phase: 05-04
    provides: AmsConnection.addNotification / deleteNotification (demux registration + teardown)
provides:
  - "AdsClient.subscribe() — lazy single-subscription Stream<AdsNotification> with Add-on-first-listen / Delete-on-cancel lifecycle"
  - "Cancel-never-throws + no-handle-leak guarantees (pending-add cancel, dead-connection swallow)"
  - "Public barrel exports for AdsNotification + AdsTransmissionMode"
affects: [05-06, cli-subscribe, symbol-access]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Single-subscription StreamController(onListen:, onCancel:) as the subscribe lifecycle state machine"
    - "_deleteQuietly: cancel-side Delete that swallows all errors (never rethrows)"
    - "handle/cancelled flag pair to resolve the cancel-during-pending-add race"

key-files:
  created:
    - test/unit/client/subscribe_test.dart
  modified:
    - lib/src/client/ads_client.dart
    - lib/dart_ads.dart
    - test/unit/public_api_test.dart

key-decisions:
  - "Barrel export of the notification types folded into Task 1 GREEN because subscribe_test.dart references AdsTransmissionMode through the public barrel — Task 1's verify depends on Task 2's export"
  - "onCancel defers the Delete when the Add is still pending; onListen performs the deferred Delete once the handle arrives (no leak, no throw)"

patterns-established:
  - "subscribe lifecycle: lazy Add on first listen, always-Delete on cancel via _deleteQuietly, addError on Add failure"
  - "Internal payload builders / parseNotificationStream stay package-private; only AdsNotification + AdsTransmissionMode are public"

requirements-completed: [NOTIF-01, NOTIF-02, NOTIF-04]

# Metrics
duration: 9min
completed: 2026-07-04
---

# Phase 5 Plan 5: subscribe() Notification Lifecycle Summary

**AdsClient.subscribe() — a lazy single-subscription Stream<AdsNotification> whose onListen sends AddDeviceNotification and whose onCancel always sends DeleteDeviceNotification without throwing or leaking a handle, plus public barrel exports for the notification types.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-07-04T13:40:00Z
- **Completed:** 2026-07-04T13:49:00Z
- **Tasks:** 2
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments
- `subscribe()` returns a lazy single-subscription `Stream<AdsNotification>` — zero frames written until the first `.listen(...)`.
- On first listen it builds the 40-byte AddDeviceNotification payload (mode.code @12, maxDelay @16, cycleTime @20, all Duration→100ns via `inMicroseconds * 10`) and calls `connection.addNotification`, which registers the stream's controller as the demux target.
- `onCancel` always attempts a DeleteDeviceNotification via `_deleteQuietly`, which never rethrows — cancel always completes (threats T-5-10 / T-5-12).
- Cancel-during-pending-add releases the just-created handle the moment the Add resolves (threat T-5-01); an Add failure surfaces via `addError` with no leaked handle.
- `AdsNotification` and `AdsTransmissionMode` are exported from `package:dart_ads/dart_ads.dart`; the internal builders / decoders / `parseNotificationStream` stay package-private.

## Task Commits

Each task was committed atomically (Task 1 is TDD → test then feat):

1. **Task 1 (RED): failing subscribe lifecycle test** - `51b3ac8` (test)
2. **Task 1 (GREEN): implement subscribe() + export types** - `fbddde6` (feat)
3. **Task 2: assert notification types in public barrel** - `26e1b42` (test)

**Plan metadata:** committed separately (docs: complete plan)

## Files Created/Modified
- `test/unit/client/subscribe_test.dart` - FakeTransport coverage: lazy-Add, 40-byte Add payload, onCancel Delete, Add-failure, cancel-during-pending-add, dead-connection swallow (7 tests)
- `lib/src/client/ads_client.dart` - `subscribe()` lifecycle state machine + private `_deleteQuietly` helper
- `lib/dart_ads.dart` - `export 'src/protocol/notifications.dart' show AdsNotification, AdsTransmissionMode;`
- `test/unit/public_api_test.dart` - assertion that the notification value types are reachable through the barrel

## Decisions Made
- **Barrel export folded into Task 1 GREEN.** `subscribe_test.dart` (a Task 1 artifact) references `AdsTransmissionMode` through the public barrel, so Task 1's verify command cannot pass without the export that the plan nominally assigns to Task 2. The export was added during the GREEN step to keep the RED→GREEN cycle honest; Task 2 then contributed the `public_api_test.dart` assertions. Net public surface is exactly as the plan specified.
- **Deferred Delete on pending-add cancel.** When `onCancel` fires before the Add resolves, `handle` is still null, so no Delete is issued there; the `onListen` continuation sees `cancelled` and releases the handle once it arrives — one owner of the deferred Delete, no double-delete.

## Deviations from Plan

None affecting behavior or scope. The only sequencing nuance is the barrel export being committed in the Task 1 GREEN commit rather than a standalone Task 2 commit (see Decisions) — the exported symbols and privacy boundary match the plan exactly. No Rule 1–4 auto-fixes were required.

## Issues Encountered
- The first GREEN test run failed to compile because `AdsTransmissionMode` was not yet public (barrel export pending). Resolved by adding the `notifications.dart` export, which is required for the feature to be usable at all. All 7 subscribe tests then passed.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `subscribe()` is the user-facing surface for NOTIF-01/02/04; 05-06 can now build the leak-proof / many-notifications stress and C++ parity coverage on top of it.
- Full unit suite green (174 tests), analyzer clean with `--fatal-infos` on both modified library files. No regressions.

## Self-Check: PASSED

- FOUND: lib/src/client/ads_client.dart (subscribe + _deleteQuietly)
- FOUND: lib/dart_ads.dart (AdsNotification + AdsTransmissionMode export)
- FOUND: test/unit/client/subscribe_test.dart
- FOUND: test/unit/public_api_test.dart (notification types assertion)
- FOUND commit: 51b3ac8 (test RED)
- FOUND commit: fbddde6 (feat GREEN)
- FOUND commit: 26e1b42 (test Task 2)

---
*Phase: 05-device-notifications-as-streams*
*Completed: 2026-07-04*
