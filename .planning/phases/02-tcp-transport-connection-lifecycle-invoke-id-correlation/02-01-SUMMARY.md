---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
plan: 01
subsystem: transport
tags: [dart-io, socket, dart-async, transport, streamcontroller, ads]

# Dependency graph
requires:
  - phase: 01-protocol-framing-codecs-golden-harness
    provides: "curated public barrel (dart_ads.dart) with intentional export...show style; MalformedFrameException typed-exception convention"
provides:
  - "AdsTransport interface — the fakeable byte-pipe seam AmsConnection is built against (TRANS-04)"
  - "SocketTransport — dart:io Socket implementation with flush()+destroy() teardown (TRANS-01)"
  - "FakeTransport — in-memory transport double (written/feed/simulateDisconnect) for socket-free unit tests"
  - "AdsTimeoutException + AdsConnectionException — transport-error exception family, distinct from MalformedFrameException"
affects: [ams-connection, invoke-id-correlation, disconnect-fan-out, integration-tests, notifications]

# Tech tracking
tech-stack:
  added: []  # no new pub packages — all SDK (dart:io, dart:async, dart:typed_data)
  patterns:
    - "AdsTransport as the single I/O seam: dart:io enters at the transport layer; protocol/ stays pure"
    - "Test-double reached via src/ path, kept out of the public barrel"
    - "flush()-then-destroy() teardown (never bare close()) to release both socket directions"

key-files:
  created:
    - lib/src/transport/transport.dart
    - lib/src/transport/socket_transport.dart
    - lib/src/transport/fake_transport.dart
    - lib/src/connection/exceptions.dart
    - test/unit/fake_transport_test.dart
  modified:
    - lib/dart_ads.dart

key-decisions:
  - "Transport interface kept to exactly four members; isConnected/done deferred to AmsConnection (Plan 02-03)"
  - "FakeTransport excluded from the public barrel — a test double reached via its src/ path"
  - "AdsTimeoutException carries invokeId+commandId; AdsConnectionException carries an optional cause"
  - "SocketTransport tears down via flush()+destroy(), tolerating a flush failure on a dead peer (T-2-01)"

patterns-established:
  - "AdsTransport seam: SocketTransport and FakeTransport are symmetric, making correlation logic socket-free testable"
  - "Transport-error exception family lives under src/connection/, imports no dart:io"

requirements-completed: [TRANS-01, TRANS-04]

# Metrics
duration: 6min
completed: 2026-07-03
---

# Phase 2 Plan 01: Transport Seam Summary

**ADS-agnostic `AdsTransport` byte-pipe with a `dart:io` `SocketTransport` (flush-then-destroy teardown), an in-memory `FakeTransport` test double, and the `AdsTimeoutException`/`AdsConnectionException` transport-error family — the fakeable seam that unlocks socket-free correlation testing.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-03T20:36Z
- **Completed:** 2026-07-03
- **Tasks:** 3
- **Files modified:** 6 (5 created, 1 modified)

## Accomplishments
- Defined `abstract interface class AdsTransport` — exactly four locked members (connect/add/inbound/close), no `dart:io` import, the seam `AmsConnection` (Plan 02-03) will be constructed against.
- Implemented `SocketTransport` over a nullable `dart:io` `Socket`: `tcpNoDelay`, `Socket`-as-`Stream<Uint8List>` inbound, and `flush()`-then-`destroy()` teardown that tolerates a dead-peer flush (T-2-01) and never uses a bare `close()`.
- Implemented `FakeTransport`: records outbound bytes (defensively copied) in `written`, drives inbound via `feed()`, and simulates clean/errored disconnect via `simulateDisconnect()` — zero sockets.
- Added the transport-error exception family (`AdsTimeoutException` with invokeId+commandId, `AdsConnectionException` with optional cause), distinct from `MalformedFrameException`.
- Proved `FakeTransport` behaviour with a 5-case `unit` test (TRANS-04) and exported the public surface through the curated barrel, keeping `FakeTransport` internal.

## Task Commits

Each task was committed atomically:

1. **Task 1: AdsTransport interface + transport-family exceptions** - `1f99416` (feat)
2. **Task 2: SocketTransport + FakeTransport implementations** - `6b34194` (feat)
3. **Task 3: FakeTransport unit test + public barrel export** - `35ba4f3` (test)

**Plan metadata:** committed with this SUMMARY (docs).

## Files Created/Modified
- `lib/src/transport/transport.dart` - `AdsTransport` interface (four members, dart:io-free)
- `lib/src/transport/socket_transport.dart` - `dart:io` Socket implementation with flush()+destroy() teardown
- `lib/src/transport/fake_transport.dart` - in-memory test double (written/feed/simulateDisconnect)
- `lib/src/connection/exceptions.dart` - `AdsTimeoutException` + `AdsConnectionException`
- `test/unit/fake_transport_test.dart` - 5-case behavioural test (TRANS-04)
- `lib/dart_ads.dart` - barrel now exports `AdsTransport`, `SocketTransport`, `AdsTimeoutException`, `AdsConnectionException`

## Decisions Made
- Kept the transport interface minimal (four members); `isConnected`/`done` belong to `AmsConnection` per the locked CONTEXT decision.
- `FakeTransport` stays out of the barrel — a test double reached via its `src/` path in same-package unit tests.
- Task 3's `tdd="true"` implementation (`FakeTransport`) legitimately already existed from Task 2 by design, so the Task 3 test is green-on-first-run as expected (not a RED-phase violation): it characterises the double and locks TRANS-04.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. All three tasks analysed clean (`--fatal-infos`), formatted clean, and the full unit suite is green (55 tests: 50 Phase-1 + 5 new, no regression).

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The transport seam is ready for Plan 02-03's `AmsConnection` (invoke-ID correlation, timeout, disconnect fan-out), which will be unit-tested entirely against `FakeTransport`.
- `SocketTransport` open/close lifecycle (TRANS-01) is implemented; its live round-trip against the C++ mock is verified downstream in the integration plan (02-04) once `mock_server.dart` and the `--delay-ms`/`--close-after` mock modes land.
- No new pub dependencies introduced; import-purity of `protocol/` preserved (dart:io enters only at `socket_transport.dart`).

---
*Phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation*
*Completed: 2026-07-03*

## Self-Check: PASSED

All 6 created/modified files exist on disk; all 3 task commits (1f99416, 6b34194, 35ba4f3) are present in git history.
