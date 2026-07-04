---
phase: 04-amsrouter-direct-local-router-transport-modes
plan: 04
subsystem: routing
tags: [ams-router, transport-mode, sealed-class, err-02, ads, dart, integration-test]

# Dependency graph
requires:
  - phase: 04-03
    provides: AmsRouter registry (openPort/closePort, addRoute/resolve, localAddr) + AdsRoutingException.directTimeout(0x0745) composed
  - phase: 04-02
    provides: AmsNetId.fromIpv4 for <ip>.1.1 auto-derive
  - phase: 04-01
    provides: AdsTransport.localAddress seam feeding source-NetId derivation
  - phase: 03
    provides: AdsClient (six commands; target/source addressing seam) + AdsException family + 0x0745/0x0508 table
  - phase: 02
    provides: AmsConnection (correlation/timeout/fan-out) wrapped per connect()
provides:
  - "sealed TransportTarget -> DirectTarget / LocalRouterTarget (runtime transport-mode selection, ROUTE-01)"
  - "AmsRouter.connect(targetNetId, amsPort, {mode}) -> ready AdsClient addressed source->target"
  - "DirectTarget ERR-02: AdsTimeoutException enriched to 0x0745/1861 AdsRoutingException naming the source NetId; all other errors unchanged (T-4-02)"
  - "connect() 0x0007 direct-mode route gate before I/O; 0x0508 on local-port exhaustion (T-4-01)"
  - "ROUTE-01 dual-mode parity + ERR-02 enriched-1861 integration tests against the C++ mock (TEST-05 router slice)"
affects: [phase-05-notifications, phase-06-sum-commands, phase-07-cli]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sealed transport-mode strategy: endpoint + routing/error policy vary, command bodies do not (ROUTE-01 structural)"
    - "AmsConnection subclass (_DirectTimeoutConnection) intercepts ONLY AdsTimeoutException at request() to enrich ERR-02 without touching AmsConnection addressing"
    - "connect() gates 0x0007 before I/O, allocates a 30000+ source port (0x0508 on exhaustion), releases the port on dial failure"
    - "Two mocks for a two-mode parity test against the single-threaded server (avoids serial-accept deadlock)"

key-files:
  created:
    - lib/src/router/transport_target.dart
    - test/integration/router_transport_modes_test.dart
    - README.md
  modified:
    - lib/src/router/ams_router.dart
    - lib/dart_ads.dart

key-decisions:
  - "ERR-02 enrichment lives in a private AmsConnection subclass whose request() catches ONLY AdsTimeoutException -> AdsRoutingException.directTimeout; AmsConnection itself is untouched (honours the 'do not refactor AmsConnection addressing' anti-pattern)"
  - "connect() opens a FRESH AmsConnection per call rather than reusing the addRoute placeholder (which carries a placeholder source port 0 and is unconnected); resolve() is used purely as the 0x0007 presence gate for direct mode"
  - "DirectTarget endpoint (deviceHost:port) drives the actual dial; the route table entry is only the 0x0007 gate (both point at the same host in tests)"
  - "<ip>.1.1 auto-derive is applied post-connect for SUBSEQUENT connects; a deterministic source NetId on the first direct connection is obtained via setLocalAddress() (used by the tests) — documented on connect()"
  - "ROUTE-01 parity test uses one mock PER mode because the mock serves one connection to close before accepting the next (single-threaded accept loop)"

patterns-established:
  - "Runtime transport-mode selection via a sealed TransportTarget passed to router.connect()"
  - "Mode-gated error enrichment: direct-only 0x0745, local-router timeouts stay their own family"

requirements-completed: [ROUTE-01, ERR-02, TEST-05]

# Metrics
duration: 11min
completed: 2026-07-04
---

# Phase 4 Plan 04: Transport Modes, connect() & ERR-02 Summary

**Runtime transport-mode selection (`sealed TransportTarget` → `DirectTarget` / `LocalRouterTarget`) wired through `AmsRouter.connect()` into a ready `AdsClient`, with a direct-mode timeout enriched into an actionable ADS `0x0745`/1861 error naming the source NetId — proven end-to-end by dual-mode parity and enriched-1861 integration tests against the C++ mock.**

## Performance

- **Duration:** ~11 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments
- `sealed TransportTarget` with `DirectTarget(deviceHost, {port})` and `LocalRouterTarget({host, port})` — runtime mode selection with zero command-code change (ROUTE-01), barrel-exported.
- `AmsRouter.connect(targetNetId, amsPort, {mode})`: exhaustive endpoint selection over the sealed modes, a `0x0007` missing-route gate before any I/O in direct mode, a `30000+` local source-port allocation (`0x0508` on exhaustion, port released on dial failure), `<ip>.1.1` auto-derive, and a returned `AdsClient` addressed `source=(localAddr, allocatedPort)` → `target=(targetNetId, amsPort)`.
- ERR-02: a private `_DirectTimeoutConnection` subclass enriches ONLY `AdsTimeoutException` into `AdsRoutingException.directTimeout` (`0x0745`/1861) naming the source NetId; every other error (device errors, disconnects, framing throws) propagates unchanged (threat T-4-02). `AmsConnection` addressing is untouched.
- `test/integration/router_transport_modes_test.dart`: ROUTE01 group proves the identical read/write/readState sequence succeeds through both modes; ERR02 group proves direct-mode enrichment (`0x0745`, source-NetId-named, never a bare timeout) AND that local-router mode stays an un-enriched `AdsTimeoutException`.
- README documents the direct-mode reverse-route requirement and the `0x0745` surfacing.

## Task Commits

Each task was committed atomically:

1. **Task 1: TransportTarget sealed + connect() wiring + ERR-02 enrichment + docs** - `85c2a7c` (feat)
2. **Task 2: Dual-mode + ERR-02 integration (ROUTE-01, ERR-02, TEST-05 slice)** - `b532b1a` (test)

_Note: Task 1 carries `tdd="true"`; per the plan's own task ordering (verify = `dart analyze`), the library code is front-loaded in Task 1 and its behaviour is proven by the Task 2 integration tests (verify = `dart test`) — the same structure used in Plan 04-03._

## Files Created/Modified
- `lib/src/router/transport_target.dart` - `sealed TransportTarget` + `DirectTarget` / `LocalRouterTarget` modes.
- `lib/src/router/ams_router.dart` - `connect()` (endpoint selection, 0x0007 gate, 0x0508 exhaustion, `<ip>.1.1` derive) + `_DirectTimeoutConnection` ERR-02 subclass + `_routerErrNoMoreQueues` constant.
- `lib/dart_ads.dart` - Curated `show` export of `TransportTarget`, `DirectTarget`, `LocalRouterTarget`.
- `README.md` - Package intro + transport-mode usage + direct-mode reverse-route requirement note.
- `test/integration/router_transport_modes_test.dart` - ROUTE01 dual-mode parity + ERR02 enriched-1861 / bare-timeout groups.

## Decisions Made
- **ERR-02 via connection subclass:** `_DirectTimeoutConnection.request()` catches only `AdsTimeoutException` and rethrows `AdsRoutingException.directTimeout(sourceNetId)`. Awaiting `super.request` preserves pipelining (the frame is sent in the synchronous portion of the base call). This keeps `AmsConnection` addressing untouched (plan anti-pattern) while intercepting exactly the timeout path AdsClient flows through.
- **Fresh connection per connect():** the `addRoute` placeholder connection is unconnected and carries source port 0, so `connect()` builds a fresh `AmsConnection`; `resolve()` is used only as the 0x0007 direct-mode presence gate.
- **Source-NetId determinism:** the tests call `setLocalAddress()` so the stamped source NetId (and thus the ERR-02 message) is deterministic; `<ip>.1.1` auto-derive is applied post-connect for subsequent connects and documented on `connect()`.
- **Two mocks for the parity test:** the C++ mock serves one connection to close before accepting the next, so each ROUTE01 mode uses its own mock to keep both connections open concurrently.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Verify-command test filter `-N` → `-n` (carried forward from Plan 04-03)**
- **Found during:** Task 2 (running the `ROUTE01|ERR02` groups)
- **Issue:** The plan's `<verify>` uses `dart test ... -N "ROUTE01|ERR02"`. `-N` is a plain-text substring match and cannot express a regex alternation, so it matches zero tests.
- **Fix:** Used `-n` (regex name filter), the correct flag for the alternation the plan intended. Verification-command only — no source/test code changed. Groups are named `ROUTE01` and `ERR02` so the alternation matches.
- **Files modified:** none (command invocation only)
- **Verification:** `dart test test/integration/router_transport_modes_test.dart -n "ROUTE01|ERR02"` → all 3 tests green.
- **Committed in:** n/a (no file change)

**2. [Rule 2 - Missing critical] Added a local-router bare-timeout assertion + source-port distinctness checks**
- **Found during:** Task 2 (encoding the must_haves truths)
- **Issue:** The plan's ERR02 group specified only the direct-mode enriched path. The plan truth "Local-router mode leaves the router's own timeout/errors unchanged (no false 0x0745 enrichment)" and threat T-4-02 need an explicit assertion that local-router mode does NOT enrich.
- **Fix:** Added an ERR02 test asserting a local-router-mode timeout is a bare `AdsTimeoutException` and NOT an `AdsException`; added source-port range/distinctness checks in ROUTE01.
- **Files modified:** test/integration/router_transport_modes_test.dart
- **Verification:** both new assertions green under the same `-n` run.
- **Committed in:** `b532b1a` (Task 2 commit)

**3. [Rule 3 - Blocking] Created README.md (did not exist)**
- **Found during:** Task 1 (adding the reverse-route note)
- **Issue:** The plan lists `README.md` under files_modified and requires the reverse-route note, but no README existed at the repo root.
- **Fix:** Created `README.md` with a package intro, transport-mode usage, and the required direct-mode reverse-route / `0x0745` note.
- **Files modified:** README.md
- **Verification:** contains "reverse route" and the `0x0745` surfacing text (artifact contract).
- **Committed in:** `85c2a7c` (Task 1 commit)

---

**Total deviations:** 3 (2 blocking, 1 missing-critical). No scope creep — all serve the plan's stated truths/artifacts.
**Impact on plan:** ERR-02 and ROUTE-01 fully proven; the extra local-router assertion strengthens the T-4-02 mitigation.

## Issues Encountered
- The C++ mock is single-threaded (serves one connection to close before accepting the next); a naive one-mock ROUTE-01 test keeping both mode connections open would deadlock the accept loop. Resolved by giving each mode its own mock. The direct-mode timeout is forced with `--delay-ms`, which holds a connection's only response until close — a genuine per-request timeout distinct from the `--close-after` disconnect path.

## User Setup Required
None - no external service configuration required (pure-Dart, no pubspec change).

## Next Phase Readiness
- Phase 4 is complete: `AmsRouter.connect()` is the primary construction path producing an addressed `AdsClient`; transport modes are runtime-selectable (ROUTE-01) and ERR-02 surfaces the actionable `0x0745`/1861 with the source NetId.
- Phase 5 (notifications) and Phase 6 (sum commands) build on the router-produced `AdsClient`/`AmsConnection`; the notification demux hook in `AmsConnection` is already reserved.
- Carry the `-N`→`-n` verify-command fix into any future plan reusing an alternation filter.

---
*Phase: 04-amsrouter-direct-local-router-transport-modes*
*Completed: 2026-07-04*

## Self-Check: PASSED

- FOUND: lib/src/router/transport_target.dart
- FOUND: test/integration/router_transport_modes_test.dart
- FOUND: README.md
- FOUND: .planning/phases/04-amsrouter-direct-local-router-transport-modes/04-04-SUMMARY.md
- FOUND commits: 85c2a7c (Task 1), b532b1a (Task 2)
