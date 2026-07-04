---
phase: 04-amsrouter-direct-local-router-transport-modes
plan: 03
subsystem: routing
tags: [ams-router, port-allocator, route-table, ads, dart, parity-test]

# Dependency graph
requires:
  - phase: 04-01
    provides: AdsTransport.localAddress seam + FakeTransport.localAddress stub (feeds <ip>.1.1 auto-derive)
  - phase: 04-02
    provides: AmsNetId.fromIpv4 + AmsNetId/AmsAddr Comparable ordering
  - phase: 02
    provides: AmsConnection (correlation/timeout/fan-out) owned per-NetId by the router
  - phase: 03
    provides: AdsClient target/source addressing seam; AdsException family + 0x0007/0x0506/0x0748/0x0745 table
provides:
  - AmsRouter registry - 128-slot local-AMS-port allocator (base 30000)
  - AmsRouter route table - addRoute/removeRoute/getConnection/resolve (NetId -> AmsConnection)
  - AmsRouter mutable source address - setLocalAddress/getLocalAddress + first-connection <ip>.1.1 auto-derive
  - AdsRoutingException - AdsException subtype carrying NetId + remediation (0x0007 missing-route; 0x0745 direct-timeout composed for Plan 04)
  - TransportFactory injection seam - route algebra unit-testable with FakeTransport, no live sockets
  - Router-registry C++ parity ports (TEST-05 Phase-4 slice)
affects: [04-04, phase-05-notifications, phase-06-sum-commands]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Injected TransportFactory so route/port/localAddr algebra is pure-unit-testable (no sockets)"
    - "Fixed-slot integer allocator with 0 as the exhaustion sentinel (C++ OpenPort parity, not an exception)"
    - "One-connection-per-NetId route table (documented divergence from C++ refcounted host sharing)"
    - "Routing exception subtypes AdsException so it is catchable both specifically and as the ADS family"

key-files:
  created:
    - lib/src/router/routing_exception.dart
    - lib/src/router/ams_router.dart
    - test/unit/router/ams_router_test.dart
  modified:
    - lib/dart_ads.dart

key-decisions:
  - "getLocalAddress() returns the source AmsNetId directly (plan behavior form), not the C++ GetLocalAddress(port,&addr)+code form"
  - "addRoute is synchronous (returns int) and reads transport.localAddress without connecting — keeps route algebra socket-free; real connect() deferred to Plan 04"
  - "AmsConnection is constructed with a placeholder source port 0 + target port plcTc3; real per-request addressing is Plan 04's connect()"
  - "removeRoute drops the mapping synchronously and fire-and-forgets connection.close() (matches C++ sync DelRoute + parity checks getConnection==null immediately)"

patterns-established:
  - "1:1 C++-named parity groups + adaptation header comment (same convention as ads_parity_test.dart) for the Phase-9 mechanical audit"

requirements-completed: [ROUTE-02, ROUTE-03, TEST-05]

# Metrics
duration: 14min
completed: 2026-07-04
---

# Phase 4 Plan 03: AmsRouter Registry Summary

**AmsRouter route algebra ported from the C++ AmsRouter — 128-slot port allocator (base 30000), NetId->AmsConnection route table with the 0x0506/idempotent/one-per-NetId decision tree, mutable source address with `<ip>.1.1` auto-derive, and up-front 0x0007 missing-route detection — all behind an injectable TransportFactory and covered by four 1:1 C++-named parity groups plus missing-route and auto-derive.**

## Performance

- **Duration:** ~14 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 3
- **Files modified:** 4 (3 created, 1 modified)

## Accomplishments
- `AdsRoutingException` (extends `AdsException`) carrying the offending `AmsNetId` + actionable remediation, with `missingRoute` (0x0007) and `directTimeout` (0x0745/1861, composed for Plan 04) factories; barrel-exported with the ADS error family.
- `AmsRouter` registry: fixed 128-slot local-port allocator (`openPort` 30000+/0-sentinel, `closePort` 0x0748), route table (`addRoute`/`removeRoute`/`getConnection`/`resolve`) mirroring the C++ decision tree, mutable `localAddr` with lazy `<ip>.1.1` derivation, and injectable `TransportFactory` seam. Barrel-exported (`AmsRouter`, `TransportFactory`).
- Router parity test suite (`test/unit/router/ams_router_test.dart`): four 1:1 C++-named groups (`testAdsPortOpenEx`, `testAmsRouterAddRoute`, `testAmsRouterDelRoute`, `testAmsRouterSetLocalAddress`) + `missing_route` (0x0007) and `auto_derive` groups — 11 tests, all green, no live sockets.

## Task Commits

Each task was committed atomically:

1. **Task 1: AdsRoutingException + barrel export** - `8febffe` (feat)
2. **Task 2: AmsRouter registry — port allocator, route table, localAddr, resolve** - `0c77265` (feat)
3. **Task 3: Router registry parity ports (FakeTransport) — TEST-05 slice** - `a69e4c3` (test)

_Note: Tasks 1 and 2 carry `tdd="true"`; the plan front-loads the library code (verified by `dart analyze`) and lands the full parity suite as Task 3 (verified by `dart test`), matching the plan's own task ordering and per-task verify gates._

## Files Created/Modified
- `lib/src/router/routing_exception.dart` - `AdsRoutingException` (AdsException subtype) + missingRoute/directTimeout factories.
- `lib/src/router/ams_router.dart` - `AmsRouter` registry: port allocator, route table, localAddr, resolve; `TransportFactory` typedef.
- `test/unit/router/ams_router_test.dart` - Six groups (4 parity + missing_route + auto_derive), FakeTransport-injected.
- `lib/dart_ads.dart` - Curated `show` exports for `AdsRoutingException`, `AmsRouter`, `TransportFactory`.

## Decisions Made
- **getLocalAddress() shape:** implemented the plan's behavior-block form (`AmsNetId getLocalAddress()`) rather than the C++ `GetLocalAddress(port, &addr)`+code form. The plan's Task-2 behavior block and Task-3 description both specify the no-port form, and the parity truth drops the port check.
- **addRoute is synchronous + socket-free:** it reads `transport.localAddress` (a stub for FakeTransport) without calling connect, keeping the route algebra pure. Real connect()/transport-mode wiring is explicitly Plan 04.
- **Placeholder AmsConnection addressing:** source port 0 + target port `AmsPort.plcTc3` are placeholders (never asserted by the parity tests); real per-request addressing is Plan 04's `connect()`.
- **One-connection-per-NetId:** followed the CONTEXT decision literally; documented the divergence from C++ refcounted host-sharing in the AmsRouter class doc and the parity-test header.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Corrected the parity test-filter flag from `-N` to `-n`**
- **Found during:** Task 3 (running the parity groups)
- **Issue:** The plan's verify command uses `dart test ... -N "A|B|C|D"`. `-N` is a plain-text substring match and cannot express a regex alternation, so it matched zero tests ("No tests match").
- **Fix:** Used `-n` (regex name filter), which is the correct flag for the alternation the plan intended. No source/test code changed — verification-command-only fix.
- **Files modified:** none (command invocation only)
- **Verification:** `dart test test/unit/router/ams_router_test.dart -n "testAdsPortOpenEx|testAmsRouterAddRoute|testAmsRouterDelRoute|testAmsRouterSetLocalAddress"` → all four groups green.
- **Committed in:** n/a (no file change)

---

**Total deviations:** 1 auto-fixed (1 blocking, verification-command only)
**Impact on plan:** No source/test behavior change; the plan's `-N` was a typo for `-n`. No scope creep.

## Issues Encountered
None - all 11 router tests, the full 113-test unit suite, and `dart analyze --fatal-infos --fatal-warnings` are green.

## User Setup Required
None - no external service configuration required (pure-Dart, no pubspec change).

## Next Phase Readiness
- Route/port/localAddr algebra + `AdsRoutingException` are in place for **Plan 04-04** to build `connect()`, the `TransportTarget` (Direct/LocalRouter) strategy, the ERR-02 direct-mode timeout catch (via `AdsRoutingException.directTimeout`, already composed), and the dual-mode ROUTE-01 integration parity.
- Deferred to Plan 04 by design: `connect()` port allocation + real socket connect, per-request target addressing, and the `-N`→`-n` fix should be carried into any Plan-04 verify commands that reuse the alternation filter.

---
*Phase: 04-amsrouter-direct-local-router-transport-modes*
*Completed: 2026-07-04*
