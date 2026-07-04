---
phase: 04-amsrouter-direct-local-router-transport-modes
fixed_at: 2026-07-04T13:00:00Z
review_path: .planning/phases/04-amsrouter-direct-local-router-transport-modes/04-REVIEW.md
iteration: 1
fix_scope: critical_warning
findings_in_scope: 8
fixed: 8
skipped: 0
status: all_fixed
---

# Phase 4: Code Review Fix Report

**Fixed at:** 2026-07-04T13:00:00Z
**Source review:** 04-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 8 (3 Critical + 5 Warning; Info findings IN-01..IN-06 out of scope per `fix_scope: critical_warning`)
- Fixed: 8
- Skipped: 0

**Verification:** `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed` clean on every touched file; full suite green — **155 tests** (was 139; +16 new unit tests). Wire behavior unchanged (no codec/golden files touched; goldens byte-identical by construction).

> Note: `dart format --set-exit-if-changed .` repo-wide flags 3 files
> (`lib/src/protocol/ads_error.dart`, `test/integration/socket_transport_test.dart`,
> `test/unit/ads_error_test.dart`) that were NOT touched by any fix — the
> drift pre-exists on `main` (formatter tall-style skew) and is out of this
> session's scope.

## Fixed Issues

### CR-03: `addRoute` never dials its connection — dead connections from `resolve()`/`getConnection()`

**Files modified:** `lib/src/router/ams_router.dart`, `lib/dart_ads.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** 9ed3130
**Applied fix:** Option (b) from the review, refined per the fix guidance: `_Route` now stores endpoint host/port metadata only; `connect()` is the single dial point and caches its live connection per target NetId. `getConnection()`/`resolve()` serve only live entries — `resolve()` throws `AdsConnectionException` for a routed-but-undialed NetId and keeps `0x0007` for unrouted ones. New `hasRoute(netId)` carries the C++ `GetConnection != nullptr` parity assertion (adaptation documented in the parity-test header and class doc). `removeRoute` closes the live connection (DelRoute parity). The dead `addRoute` auto-derive was deleted; the `auto_derive` unit group now exercises the real post-dial derive through `connect()`. Applied first because CR-01/CR-02 build on the restructured `connect()`.

### CR-01: Source-port slot never released after a successful connect (router exhausts after 128 lifetime connects)

**Files modified:** `lib/src/router/ams_router.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** b4cff2e
**Applied fix:** Each `connect()`-created connection registers a `done.whenComplete` hook that frees its source-port slot and prunes the owned/live registries (with an `identical()` guard so an older connection's teardown cannot evict a newer live entry for the same NetId). `AmsRouter.close()` now tears down every `connect()`-created connection, not just route-table state. New `connect_lifecycle` unit group pins slot reuse after client close, full slot release on `router.close()`, and the newer-entry survival rule.

### CR-02: Port slot (and open socket) leak on any throw outside the dial guard; IPv6 local address threw an opaque framing exception

**Files modified:** `lib/src/router/ams_router.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** 0f98c32
**Applied fix:** `AmsAddr(targetNetId, amsPort)` validates BEFORE `openPort()` (bad arguments can never consume a slot). One rollback guard now spans the transport-factory call → dial → post-dial auto-derive: any throw releases the slot and closes the connection. The auto-derive only runs for a strictly dotted-decimal IPv4 local address (`_isDottedIpv4`); IPv6/dual-stack values (`::1`, `fe80::…%if`) skip gracefully, leaving the local address unset instead of poisoning a healthy connect with `MalformedFrameException`. Unit tests pin the IPv6 skip (incl. no-leak), pre-allocation `ArgumentError`, and throwing-factory rollback.

### WR-01: First direct connect without `setLocalAddress` stamps `0.0.0.0.0.0` and ERR-02 names it

**Files modified:** `lib/src/router/ams_router.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** ab0ff52
**Applied fix:** Fail-fast option: direct mode with the all-zero local address throws a `StateError` naming `setLocalAddress` (and the local-router-first seeding alternative) before any allocation or I/O. `_DirectTimeoutConnection.sourceNetId` can therefore never be zero, so the ERR-02 message can never name `0.0.0.0.0.0`. Local-router mode still permits the unset state and its first connect seeds the `<ip>.1.1` auto-derive. **Requires human verification** only in the sense that this is a deliberate behavior change: a direct connect that previously "worked" against the echo-mock without `setLocalAddress` now refuses — the locked ERR-02 decision ("never misleading remediation") supports it, and the integration suite (which always sets a local address) is green.

### WR-02: No dial timeout — unreachable direct host hung `connect()` for the OS TCP timeout

**Files modified:** `lib/src/router/ams_router.dart`, `lib/src/router/routing_exception.dart`, `lib/src/transport/socket_transport.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** 62ef2bd
**Applied fix:** `AmsRouter` gains `connectTimeout` (default 5 s, configurable). The dial is raced via `.timeout()`; expiry rolls back the slot, closes the connection, and throws the new typed `AdsRoutingException.dialTimeout` (`0x0745`/1861, routing family) naming the endpoint with dial-specific remediation — wording distinct from the reverse-route `directTimeout` case. `SocketTransport` gains a `_closed` guard that destroys a socket whose dial completes after `close()`, so the abandoned dial cannot leak an fd. Hung-dial unit test pins the typed error + slot rollback.

### WR-03: `DirectTarget.deviceHost` never reconciled with the route table

**Files modified:** `lib/src/router/ams_router.dart`, `lib/src/router/transport_target.dart`, `test/unit/router/ams_router_test.dart`
**Commit:** 5396788
**Applied fix:** Conflict-throw option (documented): when `DirectTarget`'s host:port disagrees with the route-table entry for the target NetId, `connect()` throws an `AdsRoutingException` with `0x0506` `ROUTERERR_PORTALREADYINUSE` (the same same-NetId-different-endpoint code `addRoute` uses) naming BOTH endpoints, before any allocation or I/O. Documented in `DirectTarget` and `AmsRouter.connect` dartdoc; unit test pins the conflict and the no-allocation guarantee.

### WR-04: `LocalRouterTarget` omits the AMS/TCP `0x1000` port-registration handshake

**Files modified:** `lib/src/router/transport_target.dart`, `README.md`, `.planning/phases/04-amsrouter-direct-local-router-transport-modes/04-CONTEXT.md`
**Commit:** 3a070b0
**Applied fix:** Documentation option per the review's fix-scope decision (the handshake is beyond AdsLib parity — the C++ AdsLib IS its own router and never dials one; no code change). `LocalRouterTarget` dartdoc gains a prominent "mock-verified only" limitation block naming the missing `0x1000` registration and pointing real-PLC users at `DirectTarget`; README gains a matching limitation section; `04-CONTEXT.md`'s deferred list tracks the v2 follow-up.

### WR-05: Zero unit coverage for `router.connect()` paths (T-4-01/T-4-02 asserted but untested)

**Files modified:** `test/unit/router/ams_router_test.dart`, `test/integration/router_transport_modes_test.dart`
**Commit:** 7cd21ba
**Applied fix:** New `connect_error_policy` unit group (FakeTransport-backed): exhaustion of all 128 slots → typed `0x0508` `ROUTERERR_NOMOREQUEUES` from `connect()`; refused-dial rollback (next `openPort()` returns 30000); direct-mode request timeout → `0x0745` `AdsRoutingException` naming the real stamped source NetId (never a bare timeout); local-router request timeout stays a bare `AdsTimeoutException`; a mid-request disconnect crosses `_DirectTimeoutConnection` as the original `AdsConnectionException` family, un-enriched. Integration suite now asserts both `addRoute(...)` return values. Combined with the tests added alongside the other fixes, the unit suite grew 113 → 129 tests (155 total).

## Skipped Issues

None — all 8 in-scope findings were fixed. (IN-01..IN-06 were out of scope by `fix_scope: critical_warning` and remain open; note that IN-01's stale "this plan does not wire the timeout catch" comment in `routing_exception.dart` is still present and can be cleaned up with the Info batch.)

---

_Fixed: 2026-07-04T13:00:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
