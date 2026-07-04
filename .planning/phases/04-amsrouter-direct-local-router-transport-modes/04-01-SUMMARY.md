---
phase: 04-amsrouter-direct-local-router-transport-modes
plan: 01
subsystem: transport
tags: [dart, dart-io, socket, getsockname, ams-router, netid]

# Dependency graph
requires:
  - phase: 02-connection-lifecycle
    provides: AdsTransport seam (connect/add/inbound/close) with SocketTransport + FakeTransport implementations
provides:
  - AdsTransport.localAddress — the connected socket's LOCAL IPv4 (getsockname equivalent), null before connect / after close
  - SocketTransport.localAddress delegating to dart:io Socket.address.address
  - FakeTransport.localAddress as a settable stub field for unit tests
affects: [amsrouter, source-netid-derivation, route-management, transport-modes]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Transport seam grows by pure getter delegation — no connection-state surface added (isConnected/done stay out of the byte pipe)"

key-files:
  created:
    - test/unit/transport/local_address_test.dart
  modified:
    - lib/src/transport/transport.dart
    - lib/src/transport/socket_transport.dart
    - lib/src/transport/fake_transport.dart
    - test/integration/socket_transport_test.dart

key-decisions:
  - "localAddress is nullable and documented null-before-connect/after-close; consumers must null-check before deriving <ip>.1.1 (mitigates T-4-01-NULL)"
  - "SocketTransport reads dart:io Socket.address.address (LOCAL), explicitly NOT .remoteAddress (peer)"

patterns-established:
  - "Transport seam extension: add member to AdsTransport interface + both implementations + a unit (Fake) and live (Socket) test pair"

requirements-completed: [ROUTE-03]

# Metrics
duration: 6min
completed: 2026-07-04
---

# Phase 4 Plan 01: localAddress transport seam Summary

**Added `AdsTransport.localAddress` (getsockname-equivalent local IPv4) with `SocketTransport` delegation to `Socket.address.address` and a stubbable `FakeTransport` field, unblocking ROUTE-03 `<ip>.1.1` source-NetId auto-derivation.**

## Performance

- **Duration:** ~6 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments
- Extended the transport seam from four to five members with `String? get localAddress`, documented as the `getsockname` equivalent used for `<ip>.1.1` source-NetId derivation (null before connect / after close).
- `SocketTransport.localAddress` delegates to `dart:io` `Socket.address.address` (the LOCAL address), explicitly avoiding `.remoteAddress` (the peer).
- `FakeTransport.localAddress` is a settable field (default null) so unit tests can inject a stub local IPv4 such as `192.168.0.100`.
- Proven by a new unit test (default-null + settable + resettable) and a live loopback integration assertion against the CMake mock server.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add localAddress to the transport seam and both implementations** - `32346df` (feat)
2. **Task 2: Test localAddress — FakeTransport unit + live SocketTransport integration** - `be9e1cb` (test)

## Files Created/Modified
- `lib/src/transport/transport.dart` - Declared `String? get localAddress` on `AdsTransport` with getsockname/`<ip>.1.1` rationale and null-check contract.
- `lib/src/transport/socket_transport.dart` - Implemented `localAddress` as `_socket?.address.address` (LOCAL address, not peer).
- `lib/src/transport/fake_transport.dart` - Added settable `localAddress` field (default null) for unit stubbing.
- `test/unit/transport/local_address_test.dart` - Unit coverage: default-null, settable, resettable.
- `test/integration/socket_transport_test.dart` - Live case: connected `SocketTransport` reports a non-null dotted IPv4; null before connect / after close.

## Decisions Made
- Kept the interface at exactly five members: `localAddress` is a read-only getter and no connection-state surface (`isConnected`/`done`) was added, preserving the "dumb byte pipe" rationale.
- No barrel change needed — `AdsTransport`/`SocketTransport` are already exported and adding a member does not alter the export list.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## Threat Surface

Threat register handled as planned:
- **T-4-01-NULL (mitigate):** `localAddress` is nullable and its doc comment mandates a null-check before `<ip>.1.1` derivation — the mitigation is present in the interface contract.
- **T-4-01-INFO / T-4-SC (accept):** No logging of the local IP by this plan; no package installs / pubspec change (pure-Dart).

No new security-relevant surface beyond the plan's threat model.

## Next Phase Readiness
- The `localAddress` seam is ready for the AmsRouter / source-NetId derivation plans in this phase to consume (`<ip>.1.1`).
- Full suite green: `dart analyze --fatal-infos --fatal-warnings` clean; `dart test` = 117 passing (incl. the live SocketTransport localAddress assertion).

## Self-Check: PASSED

All created/modified files verified present on disk; all task commits (`32346df`, `be9e1cb`, `f75c1d7`) verified in git log.

---
*Phase: 04-amsrouter-direct-local-router-transport-modes*
*Completed: 2026-07-04*
