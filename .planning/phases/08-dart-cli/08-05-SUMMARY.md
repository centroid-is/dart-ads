---
phase: 08-dart-cli
plan: 05
subsystem: cli
tags: [dart, cli, notifications, subscribe, sigint, streams, teardown]

# Dependency graph
requires:
  - phase: 08-01
    provides: BaseAdsCommand guarded exit-code contract, connectFromGlobals/AdsSession, runner global flags
  - phase: 08-02
    provides: value_parsing (formatHex) seam and CLI subprocess integration test pattern
  - phase: 05
    provides: AdsClient.subscribe Stream lifecycle (lazy Add, Always-Delete onCancel), mock --notify-burst trigger + 0xE7700002 handle-count group
provides:
  - "subscribe verb (CLI-04) over AdsClient.subscribe with single idempotent SIGINT/SIGTERM teardown"
  - "Timestamped ISO8601 + hex streaming line format for notification samples"
  - "cli_subscribe_test integration proof: stream a sample, SIGINT, clean exit 0 + handle-release marker"
affects: [08-06, 08-07, phase-09-packaging, phase-09-parity-audit]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Single idempotent teardown closure runs on every exit path (signal/done/error)"
    - "Snapshot-before-await: signal handlers installed only after the subscription local is built"
    - "--notify-burst as the same-connection notification trigger for subprocess CLI tests"

key-files:
  created:
    - test/integration/cli_subscribe_test.dart
  modified:
    - lib/src/cli/commands/subscribe_command.dart

key-decisions:
  - "Used --notify-burst 1 to trigger the subscriber's sample because the mock's write-triggered emission is connection-scoped (an external Write cannot reach the subprocess's handle table)"
  - "Used the plan's documented connection-scope fallback for the leak assertion: exit 0 after SIGINT + a handle-release teardown marker, since a cross-connection 0xE7700002 read is trivially 0"
  - "Raw --group/--offset/--len subscription path in the test to avoid a browseSymbols Add, keeping the subscription the only AddDeviceNotification"

patterns-established:
  - "Idempotent teardown: cancel StreamSubscription (fires DeleteDeviceNotification) then session.close(), guarded by a tornDown flag and awaited from a finally block"
  - "Completer<int> gates the run: signal/done complete it with exitOk, stream error completes it with the mapped error"

requirements-completed: [CLI-04]

# Metrics
duration: 14min
completed: 2026-07-04
---

# Phase 8 Plan 05: subscribe verb Summary

**`subscribe` streams timestamped ISO8601 + hex notification lines and tears the PLC notification handle down cleanly on Ctrl-C via a single idempotent SIGINT/SIGTERM teardown, proven end-to-end against the mock.**

## Performance

- **Duration:** 14 min
- **Started:** 2026-07-04T17:35:00Z
- **Completed:** 2026-07-04T17:49:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Filled `SubscribeCommand.run()`: `--name` or raw `--group/--offset/--len` target resolution, `--on-change`/`--cycle`/`--max-delay` transmission-mode selection, and per-sample streaming lines.
- Single idempotent teardown closure releases the notification handle (subscription cancel → DeleteDeviceNotification) and closes the session on EVERY exit path — SIGINT, SIGTERM, stream done, or stream error — with snapshot-before-await so a signal never races a half-built session.
- Integration test drives the CLI as a subprocess, receives a timestamped sample (triggered by `--notify-burst 1`), sends SIGINT, and asserts a clean exit 0 plus the handle-release teardown marker.

## Task Commits

1. **Task 1: subscribe verb with clean SIGINT teardown** - `c7eed9d` (feat)
2. **Task 2: subscribe integration test + teardown marker** - `147a3bc` (test)

## Files Created/Modified
- `lib/src/cli/commands/subscribe_command.dart` - Real `run()` body: target/mode resolution, streaming, and the idempotent signal/done/error teardown that releases the handle (contains `ProcessSignal.sigint`, `subscribe(`, `session.close()`).
- `test/integration/cli_subscribe_test.dart` - `@Tags(['integration'])` end-to-end case: stream a sample, SIGINT, assert exit 0 + release marker.

## Decisions Made
- **`--notify-burst 1` as the trigger:** the mock's write-triggered serverOnChange emission fans out only to handles on the SAME connection as the writer (its `notes` table is per-connection), and the `subscribe` verb never writes — so no external Write can reach the subprocess's notification table. `--notify-burst` emits one frame for the new handle right after the Add response, on the subscriber's own connection.
- **Connection-scope leak fallback:** because `notes` dies with the connection, a fresh connection reading `0xE7700002` sees only its own empty table (always 0) and cannot prove THIS process released its handle. Used the plan's documented fallback — exit 0 after SIGINT + a handle-release teardown marker. The same-connection zero-handle proof lives at library level in `test/integration/ads_notification_test.dart`, and the CLI's SIGINT path drives that exact `StreamSubscription.cancel()` teardown.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added a connection-local handle-release teardown marker**
- **Found during:** Task 2 (integration test)
- **Issue:** The plan's Task 2 fallback (used here because the cross-connection leak read is unobservable) requires "a stderr/stdout teardown marker" to assert clean teardown, but the Task 1 command emitted none — leaving the headline no-leak property unobservable from the subprocess.
- **Fix:** `teardown()` now writes `subscribe: notification handle released, session closed` to stderr once, gated on a live subscription having existed, after cancel + `session.close()`.
- **Files modified:** lib/src/cli/commands/subscribe_command.dart
- **Verification:** `dart analyze --fatal-infos` clean; the integration test asserts the marker is present after SIGINT.
- **Committed in:** `147a3bc` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing-critical observability)
**Impact on plan:** The marker is the connection-local evidence the plan's own fallback contract calls for; no scope creep.

## Issues Encountered
- The plan's suggested trigger (a second CLI `write` or a direct library write to the watched region) cannot work: the mock emits write-triggered notifications only to the writer's own connection, so it could never reach the subscribe subprocess. Resolved by switching to `--notify-burst 1` (the mock's same-connection Add-time emission), matching how `ads_notification_test.dart` triggers its first-listen case.

## Threat Flags

None - the verb only formats parsed `AdsNotification` values and opens no new network/auth/file surface beyond 08-01's shared connect backbone. Threat T-8-03 (SIGINT handle teardown) is mitigated as planned: a single idempotent teardown releases the handle on every exit path, asserted by the integration test.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Five of seven CLI verbs now have live bodies (browse, read, write, subscribe done; pull/push/action remain for 08-06/08-07).
- Phase 9 parity/packaging: the connection-scope limitation of the mock's cross-connection notification-handle read is documented in the test for the audit; the CLI serves as a living streaming example.

---
*Phase: 08-dart-cli*
*Completed: 2026-07-04*

## Self-Check: PASSED

All created files exist; both task commits (c7eed9d, 147a3bc) are present in history.
