---
phase: 04-amsrouter-direct-local-router-transport-modes
plan: 02
subsystem: protocol
tags: [ams, amsnetid, amsaddr, ordering, comparable, ipv4, parity]

# Dependency graph
requires:
  - phase: 01-framing
    provides: AmsNetId/AmsAddr value types with equality/hashCode and MalformedFrameException
provides:
  - AmsNetId is Comparable (lexicographic over 6 bytes, bytes[0] most significant) with < <= > >=
  - AmsAddr is Comparable (netId first, then port) with operator<
  - AmsNetId.fromIpv4 deriving <ip>.1.1 (big-endian octets) for router source-NetId auto-derive
  - testAmsAddrCompare 1:1 C++ parity port (TEST-05 Phase-4 slice)
affects: [ams-router, transport-modes, source-netid-derivation, route-table]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Value-type ordering via Comparable.compareTo with derived comparison operators (no new imports; protocol/ stays pure)"
    - "1:1 C++-named test groups (testAmsAddrCompare) for the Phase-9 mechanical parity audit"

key-files:
  created:
    - test/unit/protocol/ams_net_id_compare_test.dart
  modified:
    - lib/src/protocol/ams_net_id.dart

key-decisions:
  - "AmsNetId.fromIpv4 reuses the existing 6-byte constructor validation path rather than re-implementing range checks — a malformed IPv4 throws MalformedFrameException (T-4-02-VAL mitigation)"
  - "Octet order transcribed big-endian exactly (bytes[0] = most-significant octet), unit-tested 192.168.0.100 -> 192.168.0.100.1.1 (T-4-02-ORD / Pitfall 1 mitigation)"

patterns-established:
  - "Comparable value types: compareTo returns -1/0/1; operator< (and friends) delegate to compareTo"

requirements-completed: [TEST-05, ROUTE-03]

# Metrics
duration: 2min
completed: 2026-07-04
---

# Phase 4 Plan 02: AmsNetId/AmsAddr Ordering + fromIpv4 Summary

**AmsNetId/AmsAddr are now Comparable (lexicographic bytes, then port) and AmsNetId.fromIpv4 derives the `<ip>.1.1` source NetId, with a 1:1 testAmsAddrCompare parity port.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-07-04T11:50:17Z
- **Completed:** 2026-07-04T11:51:53Z
- **Tasks:** 2
- **Files modified:** 2 (1 created, 1 modified)

## Accomplishments
- Added `Comparable<AmsNetId>` with `compareTo` (lexicographic over the 6 bytes, `bytes[0]` most significant) plus `<`/`<=`/`>`/`>=`
- Added `Comparable<AmsAddr>` with `compareTo` (netId first, then port) plus `operator<`
- Added `AmsNetId.fromIpv4` mirroring the C++ `AmsNetId(uint32_t)` `<ip>.1.1` convention (big-endian octets), validating via the existing 6-byte constructor
- Ported `testAmsAddrCompare` 1:1 (all lower-byte / lower-port / asymmetry / irreflexivity assertions) plus a fromIpv4 derivation + error-case unit group

## Task Commits

Each task was committed atomically:

1. **Task 1: Add ordering and fromIpv4 to AmsNetId/AmsAddr** - `f13f36d` (feat)
2. **Task 2: Port testAmsAddrCompare 1:1 + fromIpv4 unit test** - `0cd4a87` (test)

## Files Created/Modified
- `lib/src/protocol/ams_net_id.dart` - Added Comparable ordering + comparison operators to AmsNetId and AmsAddr, and the `AmsNetId.fromIpv4` factory; equality/hashCode/toString unchanged, no new imports
- `test/unit/protocol/ams_net_id_compare_test.dart` - `testAmsAddrCompare` 1:1 parity group + `AmsNetId.fromIpv4` derivation/error group

## Decisions Made
- Kept `AmsNetId.fromIpv4` on the value type (not a free function) so the octet-order convention lives with the type it constructs; reused the 6-byte constructor's validation so a bad IPv4 throws `MalformedFrameException` rather than mis-addressing frames.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## Verification
- `dart test test/unit/protocol/ams_net_id_compare_test.dart` — 8/8 passing (5 testAmsAddrCompare + 3 fromIpv4)
- `dart analyze --fatal-infos --fatal-warnings lib/src/protocol/ams_net_id.dart test/unit/protocol/ams_net_id_compare_test.dart` — clean

## Threat Model Coverage
- **T-4-02-VAL** (mitigate): `fromIpv4` reuses constructor validation; malformed IPv4 (short + out-of-range) throws `MalformedFrameException` — unit-tested.
- **T-4-02-ORD** (mitigate): big-endian octet order transcribed exactly; `192.168.0.100 -> 192.168.0.100.1.1` unit-asserted (Pitfall 1).
- **T-4-SC** (accept): no package installs — pure-Dart, no pubspec change.

## Next Phase Readiness
- Ordering + `fromIpv4` are the value-type primitives the AmsRouter needs for source-NetId auto-derive (ROUTE-03) and route-table ordering; ready for the router plan(s).

## Self-Check: PASSED
- FOUND: lib/src/protocol/ams_net_id.dart
- FOUND: test/unit/protocol/ams_net_id_compare_test.dart
- FOUND: commit f13f36d
- FOUND: commit 0cd4a87

---
*Phase: 04-amsrouter-direct-local-router-transport-modes*
*Completed: 2026-07-04*
