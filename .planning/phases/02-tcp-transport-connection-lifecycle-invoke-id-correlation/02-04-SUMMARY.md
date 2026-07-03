---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
plan: 04
subsystem: testing
tags: [integration-test, dart-io, socket, ams-tcp, mock-server, invoke-id, reorder]

# Dependency graph
requires:
  - phase: 02-01
    provides: SocketTransport (dart:io Socket implementation of AdsTransport)
  - phase: 02-02
    provides: startMockServer helper + C++ mock modes (--delay-ms, --close-after)
  - phase: 02-03
    provides: AmsConnection (connect/request/close, invoke-ID correlation, disconnect fan-out)
provides:
  - Live end-to-end integration tests proving the transport + connection stack over a real loopback socket
  - On-wire proof of invoke-ID correlation under response reordering (--delay-ms)
  - On-wire proof of mid-request disconnect fan-out (--close-after) with no hung Future
affects: [03-ads-commands, phase-gate-verification, ci-integration-job]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Integration tests tagged @Tags(['integration']) with a 30s tag timeout, launched via the shared startMockServer helper on an ephemeral port"
    - "Per-test mock lifecycle: each behaviour-specific test starts its own mock with the relevant flag and tears it down via addTearDown(server.stop)"
    - "Pipelined-request pattern: capture both request Futures before awaiting either, so on-wire reordering has something to reorder"

key-files:
  created:
    - test/integration/socket_transport_test.dart
    - test/integration/ams_connection_live_test.dart
  modified: []

key-decisions:
  - "No CI workflow change: the existing Linux integration job already runs full `dart test`, which picks up these @Tags(['integration']) tests"
  - "Used a comfortably-long 10s per-request timeout in the reorder/disconnect tests so results are provably correlation/connection outcomes, never a timeout firing"

patterns-established:
  - "Live-harness integration test: real dart:io Socket + real TCP segmentation + real mock child process, mirroring the FakeTransport unit tests of Plan 02-03"
  - "Clean teardown contract: SIGTERM + await exitCode (server.stop) in tearDownAll / addTearDown to guard against orphan mock processes"

requirements-completed: [TRANS-01, TRANS-03, PROTO-03, TEST-03]

# Metrics
duration: 7min
completed: 2026-07-03
---

# Phase 2 Plan 04: Live Integration Harness Summary

**Live socket integration tests proving open/round-trip/close, invoke-ID correlation under on-wire response reordering (--delay-ms), and mid-request disconnect fan-out (--close-after) end-to-end against the C++ mock.**

## Performance

- **Duration:** ~7 min
- **Completed:** 2026-07-03
- **Tasks:** 2
- **Files modified:** 2 (both created)

## Accomplishments
- `test/integration/socket_transport_test.dart`: a live `AmsConnection` over a real `SocketTransport` connects to the mock on an ephemeral port, round-trips a real ReadDeviceInfo frame (decodes to `"Dart ADS Mock"`), and cleanly closes — `done` completes and `isConnected` flips false (TRANS-01, TEST-03).
- `test/integration/ams_connection_live_test.dart` reorder test: two pipelined requests receive out-of-order responses on the wire (mock defers response #1 and flushes it last) yet each resolves its OWN Future with `droppedResponses == 0` — the on-wire proof of invoke-ID correlation under reordering (PROTO-03, success criterion 2).
- Disconnect test: under `--close-after 1` the mock drops the socket mid-request; the pending request errors with `AdsConnectionException` (not a timeout) and `done` completes — proving single-shot fan-out leaves no hung Future (TRANS-03).
- Full `dart test` (unit + integration) green: 65 tests pass; `dart analyze --fatal-infos` clean on the new files; no orphan mock processes left by these tests.

## Task Commits

Each task was committed atomically:

1. **Task 1: Live connect / ReadDeviceInfo round-trip / clean close** - `f2a0030` (test)
2. **Task 2: Live reorder (--delay-ms) + mid-request disconnect (--close-after)** - `d3c580d` (test)

## Files Created/Modified
- `test/integration/socket_transport_test.dart` - Live connect + ReadDeviceInfo round-trip + clean close/teardown against the mock through startMockServer.
- `test/integration/ams_connection_live_test.dart` - Live response reordering correlation (--delay-ms) + mid-request disconnect fan-out (--close-after), each with its own mock lifecycle.

## Decisions Made
- No CI workflow change (per plan objective / RESEARCH open question 3): the existing Linux `integration` job already runs full `dart test`, which includes these `@Tags(['integration'])` tests, satisfying the "extend the integration job" intent without a redundant step.
- Passed an explicit 10s per-request timeout in the reorder and disconnect tests so neither is accidentally satisfied by the 5s default timeout firing — the reorder proves correlation, the disconnect proves a CONNECTION error.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. Both test files passed on first run; all acceptance-criteria greps and `dart format` checks passed.

## Threat Surface
No new security-relevant surface introduced. This plan is test-only (no `lib/` changes); it verifies the mitigations for T-2-02 (disconnect fan-out) and T-2-04 (reorder correlation) already dispositioned `mitigate (verify)` in the plan's threat register, and asserts clean mock teardown (T-2-07). No new packages (T-2-SC).

## Next Phase Readiness
- Phase 2's live-harness success criteria are proven end-to-end over a real socket; the transport + connection stack (SocketTransport + FrameAssembler + AmsConnection) is validated against the C++ mock.
- This is the final plan of Phase 2 (single-plan wave 3). Ready for phase verification and Phase 3 (ADS commands) which builds request/response codecs on top of this correlated connection.

---
*Phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation*
*Completed: 2026-07-03*
