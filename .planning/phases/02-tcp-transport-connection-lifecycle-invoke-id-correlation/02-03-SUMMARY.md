---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
plan: 03
subsystem: transport
tags: [ams, invoke-id, correlation, completer, timer, streamcontroller, demux, dart-async]

# Dependency graph
requires:
  - phase: 02-01
    provides: AdsTransport interface, FakeTransport, AdsTimeoutException, AdsConnectionException
  - phase: 01
    provides: AmsHeader/AmsTcpHeader codecs, FrameAssembler, AdsCommandId/AmsStateFlags constants, AmsAddr/AmsNetId
provides:
  - "AmsConnection (L4): monotonic invoke-ID counter + invokeId→PendingRequest correlation map"
  - "Per-request timeout via Timer with map-remove-wins completion claim"
  - "Notification demux hook: cmd 0x08 frames routed before invoke-ID lookup (Phase-5 attaches Streams)"
  - "Single-shot disconnect fan-out: errors all pending + closes notification controllers, done completes"
  - "isConnected / done / droppedResponses / notificationFrames lifecycle surface"
affects: [phase-02-04-integration-tests, phase-03-ads-commands, phase-05-notifications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "map-remove-wins: _pending.remove(id) is the sole completion claim (race-free on Dart's single event loop)"
    - "demux-before-lookup: branch on commandId==0x08 before touching the correlation map"
    - "single-shot _failClose: _closed guard + snapshot-clear-then-error ordering"

key-files:
  created:
    - lib/src/connection/pending_request.dart
    - lib/src/connection/ams_connection.dart
    - test/unit/ams_connection_test.dart
  modified:
    - lib/dart_ads.dart

key-decisions:
  - "request() returns raw response payload (bytes after the 38-byte header); typed decode + errorCode mapping stay in Phase 3"
  - "Disconnect cause normalised via _asConnectionException: existing AdsConnectionException passed through, other errors wrapped as .cause"
  - "PendingRequest kept package-internal (not barrel-exported); the raw Completer is never handed out"

patterns-established:
  - "map-remove-wins: exactly one of {response, timeout, fan-out} claims each request; no locks, no double-complete"
  - "demux-before-lookup: cmd 0x08 bypasses both the pending map and droppedResponses"
  - "single-shot fan-out: set _closed first, snapshot+clear before erroring, complete done once"

requirements-completed: [PROTO-03, PROTO-04, TRANS-02, TRANS-03]

# Metrics
duration: 14min
completed: 2026-07-03
---

# Phase 2 Plan 03: AmsConnection (invoke-ID correlation, timeout, demux, fan-out) Summary

**AmsConnection (L4) correlating AMS/TCP responses to request Futures by invoke-ID over a FakeTransport — with per-request timeout, cmd-0x08 notification demux, and single-shot disconnect fan-out, all proven with zero sockets.**

## Performance

- **Duration:** ~14 min
- **Started:** 2026-07-03
- **Completed:** 2026-07-03
- **Tasks:** 3 (TDD: RED → GREEN → GREEN)
- **Files modified:** 4 (3 created, 1 modified)

## Accomplishments
- `AmsConnection` owns a monotonic u32 invoke-ID counter (1 → wrap 0xFFFFFFFF → 1, never 0) and a `Map<int,PendingRequest>` correlation map, with `_pending.remove(id)` as the sole completion claim — so pipelined and reordered responses each resolve their own Future with zero crossed responses (PROTO-03).
- Per-request `Timer` (5s default + override) removes-and-errors the pending entry with `AdsTimeoutException`; a late response for a timed-out id is counted in `droppedResponses` and never throws — no leak (TRANS-02).
- `_onFrame` branches on `commandId == 0x08` BEFORE the invoke-ID lookup, incrementing `notificationFrames` without touching the pending map or `droppedResponses` (PROTO-04).
- Single-shot `_failClose` (guarded by `_closed`) snapshots+clears the pending map, errors every request with `AdsConnectionException`, closes notification controllers with error, closes the transport, and completes `done` exactly once — no hung Futures on disconnect (TRANS-03).
- `AmsConnection` exported from the public barrel; `PendingRequest` stays package-internal.

## Task Commits

Each task was committed atomically:

1. **Task 1: RED — behaviour tests + PendingRequest + AmsConnection API skeleton** - `462c89c` (test)
2. **Task 2: GREEN — connect, invoke-ID correlation, per-request timeout, notification demux** - `8cfaccf` (feat)
3. **Task 3: GREEN — single-shot disconnect fan-out, close(), barrel export** - `fbdf9ee` (feat)

## Files Created/Modified
- `lib/src/connection/pending_request.dart` - Package-internal `PendingRequest` record (Completer + Timer + expectedCommandId); the raw Completer is never exposed.
- `lib/src/connection/ams_connection.dart` - `AmsConnection`: invoke-ID allocation, `_buildFrame` via real `.encode()` codecs, `request`, `_onFrame` (demux + correlation + command-mismatch), single-shot `_failClose`, `close`.
- `test/unit/ams_connection_test.dart` - FakeTransport-driven tests across five behaviour groups: correlation, reorder, timeout, disconnect (errored + clean-FIN), notification.
- `lib/dart_ads.dart` - Added `export 'src/connection/ams_connection.dart' show AmsConnection;`.

## Decisions Made
- `request()` returns the raw response payload (`Uint8List.sublistView(frame, 38)`), keeping L4 command-agnostic; Phase 3 owns typed decode + `errorCode`→exception mapping (RESEARCH Assumption A3 / resolved Open Question 1).
- Disconnect cause normalised via `_asConnectionException`: an existing `AdsConnectionException` (onDone/close) passes through with its message; any other error (onError raw object, `MalformedFrameException`) is wrapped as `AdsConnectionException('connection lost', cause: e)`. This adapts the RESEARCH Pattern-3 snippet to the Plan-02-01 exception signature (`AdsConnectionException(String message, {Object? cause})`), which takes a `String` message rather than an arbitrary object.
- Defensive command-mismatch guard: a response whose `commandId` differs from the pending's `expectedCommandId` completes-with-error and increments `droppedResponses` rather than crossing responses or hanging.

## Deviations from Plan

None - plan executed as written.

_Intra-plan staging note (not a behaviour deviation): a minimal single-shot `_failClose` guard (plus subscription-cancel) was introduced in the Task 2 commit rather than left absent, because `connect()`'s `onError`/`onDone`/`MalformedFrameException` handlers reference `_failClose` and every commit must stay `dart analyze --fatal-infos` clean. The full fan-out body (error pending, close controllers, complete `done`) landed in Task 3 exactly as planned. Behaviour matches the plan at every commit boundary._

## Issues Encountered
- Skeleton `_connected`/`_closed` fields tripped `prefer_final_fields` under `--fatal-infos` while their bodies still threw `UnimplementedError` (Task 1). Resolved by having the RED `connect`/`close` skeletons mutate the flags before throwing — keeping the file analyze-clean without suppressions and preserving RED semantics.

## User Setup Required
None - no external service configuration required. All logic is unit-tested via `FakeTransport` with zero sockets or C++ toolchain.

## Next Phase Readiness
- Correlation/timeout/fan-out/demux core is complete and unit-proven (61 unit tests green, `dart test -x integration`).
- Plan 02-04 can now wire `SocketTransport` + the `mock_server.dart` launcher for live integration tests (reorder via `--delay-ms`, mid-request disconnect via `--close-after`).
- Phase 3 can build `AdsClient` on top of `AmsConnection.request`, adding per-command decode and `errorCode`→exception mapping.
- Phase 5 will hang real notification `Stream`s off the `_demuxControllers` hook that the disconnect fan-out already closes-with-error.

---
*Phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation*
*Completed: 2026-07-03*
