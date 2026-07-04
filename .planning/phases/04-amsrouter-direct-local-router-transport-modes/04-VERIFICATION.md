---
phase: 04-amsrouter-direct-local-router-transport-modes
verified: 2026-07-04T00:00:00Z
status: passed
score: 4/4 must-haves verified
overrides_applied: 0
---

# Phase 4: AmsRouter, Direct / Local-Router Transport Modes — Verification Report

**Phase Goal:** The AmsRouter maps AmsNetId to connection and stamps the source NetId, users can select direct-peer or local-TwinCAT-router transport at runtime, and the most common connectivity failure (error 1861) is surfaced actionably.
**Verified:** 2026-07-04
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can select direct-to-peer or local-TwinCAT-router transport at runtime without changing command code | ✓ VERIFIED | `sealed TransportTarget` → `DirectTarget` / `LocalRouterTarget` in `transport_target.dart`; `AmsRouter.connect(targetNetId, amsPort, mode:)` dispatches exhaustively; integration test `ROUTE01` runs identical read/write/readState sequence through both modes with zero command-level change |
| 2 | The embedded AmsRouter maps AmsNetId → connection and allocates local AMS ports | ✓ VERIFIED | `AmsRouter` in `ams_router.dart`: `addRoute`/`getConnection`/`resolve` route table; `openPort`/`closePort` fixed 128-slot allocator at base 30000; unit group `testAdsPortOpenEx` proves all semantics including 0-sentinel exhaustion and 0x0748 for out-of-range/closed ports |
| 3 | User can configure the source AmsNetId and a local route table for direct mode | ✓ VERIFIED | `setLocalAddress`/`getLocalAddress` present; `addRoute(netId, host)` / `removeRoute(netId)` route table; `<ip>.1.1` auto-derive on first `connect()` when unset; unit groups `testAmsRouterSetLocalAddress`, `testAmsRouterAddRoute`, `testAmsRouterDelRoute`, `auto_derive` all pass; `AmsNetId.fromIpv4` factory verified in `ams_net_id_compare_test.dart` |
| 4 | A missing-route failure surfaces as ADS error 1861/0x745 with an actionable message naming the source AmsNetId, never a bare timeout | ✓ VERIFIED | `_DirectTimeoutConnection.request()` catches only `AdsTimeoutException` → rethrows `AdsRoutingException.directTimeout(sourceNetId)` (code 0x0745); integration test `ERR02` asserts `code == 0x0745`, `netId == localNetId`, message contains `localNetId.dotted`, and `isNot(isA<AdsTimeoutException>())`; second ERR02 test asserts local-router mode stays a bare `AdsTimeoutException` (no false enrichment) |

**Score: 4/4 roadmap success criteria VERIFIED**

---

### Plan Must-Haves (All Plans)

#### Plan 04-01 — Transport Seam: localAddress

| Truth | Status | Evidence |
|-------|--------|----------|
| Transport seam exposes connected socket's local IPv4 address | ✓ VERIFIED | `String? get localAddress` on `AdsTransport` interface in `transport.dart` |
| SocketTransport reports non-null dotted local address after connect | ✓ VERIFIED | `SocketTransport.localAddress` returns `_socket?.address.address` (LOCAL address, not remoteAddress); integration assertion in `socket_transport_test.dart` |
| FakeTransport can be given a stub local address for unit tests | ✓ VERIFIED | `FakeTransport.localAddress` is a settable field (default null); unit test in `local_address_test.dart` |

#### Plan 04-02 — AmsNetId/AmsAddr Ordering + fromIpv4

| Truth | Status | Evidence |
|-------|--------|----------|
| AmsNetId values order lexicographically over their 6 bytes (b[0] most significant) | ✓ VERIFIED | `AmsNetId implements Comparable<AmsNetId>` with `compareTo` walking bytes[0..5]; `<` / `<=` / `>` / `>=` operators derived |
| AmsAddr values order by netId first, then port | ✓ VERIFIED | `AmsAddr implements Comparable<AmsAddr>` with `compareTo` comparing `netId` then `port`; `operator<` present |
| IPv4 string derives `<ip>.1.1` source NetId with octets in big-endian order | ✓ VERIFIED | `AmsNetId.fromIpv4("192.168.0.100")` returns `AmsNetId([192,168,0,100,1,1])`; asserted in `ams_net_id_compare_test.dart` |
| testAmsAddrCompare parity assertions all pass | ✓ VERIFIED | `group('testAmsAddrCompare', ...)` present, named 1:1 after C++ method; all lower-byte / lower-port / asymmetry / irreflexivity assertions pass |

#### Plan 04-03 — AmsRouter Registry

| Truth | Status | Evidence |
|-------|--------|----------|
| Router allocates local AMS ports from base 30000, up to 128 slots, returning 0 when exhausted | ✓ VERIFIED | `openPort()` returns `portBase + i` for first free slot, `0` on exhaustion; `testAdsPortOpenEx` unit group proves all 128 distinct in [30000, 30128), 129th = 0 |
| closePort returns 0x0748 for out-of-range or already-closed port | ✓ VERIFIED | `closePort` returns `_adsErrClientPortNotOpen` (0x0748) on index-out-of-range or slot already 0; unit test covers all cases |
| addRoute maps target AmsNetId to an endpoint; getConnection returns it after connect | ✓ VERIFIED | `addRoute` records `_Route(host, port)` metadata; `getConnection` returns the live connect()-dialed connection; `hasRoute` carries C++ parity assertion |
| addRoute for known NetId to different host returns 0x0506 until removeRoute | ✓ VERIFIED | `_routerErrPortAlreadyInUse` (0x0506) returned; old route left intact; unit group `testAmsRouterAddRoute` |
| setLocalAddress overrides source NetId; getLocalAddress reflects it; default is empty | ✓ VERIFIED | `_localAddr` field; `setLocalAddress`/`getLocalAddress`; `emptyLocalAddress` static getter; unit group `testAmsRouterSetLocalAddress` |
| Resolving unrouted NetId throws AdsRoutingException(0x0007) naming the NetId, before any I/O | ✓ VERIFIED | `_requireRoute` throws `AdsRoutingException.missingRoute(netId)` (code 0x0007) before any socket operation; unit group `missing_route` |
| First connection auto-derives source NetId as `<ip>.1.1` when none was set | ✓ VERIFIED | Post-dial `_isDottedIpv4` guard + `AmsNetId.fromIpv4(localIp)` in `connect()`; unit group `auto_derive` |

#### Plan 04-04 — TransportTarget, connect(), ERR-02

| Truth | Status | Evidence |
|-------|--------|----------|
| User selects DirectTarget or LocalRouterTarget at runtime without changing command code | ✓ VERIFIED | `sealed class TransportTarget` with exhaustive `switch` in `connect()`; ROUTE01 integration test |
| router.connect resolves route, opens connection, yields AdsClient with correct source/target addressing | ✓ VERIFIED | `connect()` allocates 30000+ source port, constructs `AmsAddr(localAddr, sourcePort)` → `AmsAddr(targetNetId, amsPort)`, returns `AdsClient`; ROUTE01 asserts distinct 30000+ ports |
| Same command sequence succeeds through both modes against the mock | ✓ VERIFIED | ROUTE01 integration test: `directResult.seed == localResult.seed`, `directResult.readBack == localResult.readBack`, `directResult.state == localResult.state` |
| Direct-mode missing reverse route surfaces as AdsException code 0x0745/1861 naming source AmsNetId, never a bare timeout | ✓ VERIFIED | `_DirectTimeoutConnection` wraps only `AdsTimeoutException`; ERR02 integration test asserts `code == 0x0745`, `netId == localNetId`, `isNot(isA<AdsTimeoutException>())` |
| Local-router mode leaves router's own timeout/errors unchanged (no false 0x0745 enrichment) | ✓ VERIFIED | `LocalRouterTarget` uses plain `AmsConnection` (no wrapper); ERR02 integration test: local-router timeout `isA<AdsTimeoutException>()` and `isNot(isA<AdsException>())` |

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/src/transport/transport.dart` | `localAddress` member on `AdsTransport` interface | ✓ VERIFIED | Line 68: `String? get localAddress` with getsockname doc |
| `lib/src/transport/socket_transport.dart` | `SocketTransport.localAddress` returning local IPv4 | ✓ VERIFIED | Lines 69-74: `_socket?.address.address` — explicitly NOT `.remoteAddress` |
| `lib/src/transport/fake_transport.dart` | Configurable `FakeTransport.localAddress` for unit tests | ✓ VERIFIED | Lines 37-38: `@override String? localAddress` settable field |
| `lib/src/protocol/ams_net_id.dart` | Comparable + operator< on AmsNetId/AmsAddr and AmsNetId.fromIpv4 | ✓ VERIFIED | Lines 26-203; `compareTo`, all comparison operators, `fromIpv4` factory present |
| `lib/src/router/ams_router.dart` | AmsRouter registry: port allocator, route table, localAddr, resolve, connect | ✓ VERIFIED | 549 lines; all five subsystems present with full implementation |
| `lib/src/router/routing_exception.dart` | AdsRoutingException extending AdsException with code + named NetId | ✓ VERIFIED | `AdsRoutingException extends AdsException` with `missingRoute` (0x0007), `directTimeout` (0x0745), `dialTimeout` (0x0745) factories |
| `lib/src/router/transport_target.dart` | sealed TransportTarget → DirectTarget / LocalRouterTarget | ✓ VERIFIED | `sealed class TransportTarget`; `final class DirectTarget`; `final class LocalRouterTarget` |
| `lib/dart_ads.dart` | Barrel exports: AdsRoutingException, AmsRouter, TransportFactory, TransportTarget, DirectTarget, LocalRouterTarget | ✓ VERIFIED | Lines 98, 114, 121-122 |
| `README.md` | Reverse-route requirement note for direct mode, 0x0745 surfacing note | ✓ VERIFIED | Lines 37-52: "Direct mode requires a REVERSE route", `0x0745` (1861) error surfacing documented |
| `test/unit/transport/local_address_test.dart` | Unit tests for localAddress | ✓ VERIFIED | File exists; FakeTransport default-null + settable covered |
| `test/unit/protocol/ams_net_id_compare_test.dart` | testAmsAddrCompare parity port + fromIpv4 | ✓ VERIFIED | `group('testAmsAddrCompare', ...)` + `group('AmsNetId.fromIpv4', ...)` |
| `test/unit/router/ams_router_test.dart` | Four 1:1 C++ parity groups + missing_route + auto_derive + connect_lifecycle + connect_error_policy | ✓ VERIFIED | All groups present; 129 unit tests |
| `test/integration/router_transport_modes_test.dart` | ROUTE01 dual-mode parity + ERR02 enriched-1861 integration | ✓ VERIFIED | Groups `ROUTE01` and `ERR02`; 3 integration tests |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AmsRouter.connect (DirectTarget)` | `AdsException(0x0745) naming source NetId` | `_DirectTimeoutConnection.request()` catches only `AdsTimeoutException` → `AdsRoutingException.directTimeout` | ✓ WIRED | `ams_router.dart` lines 524-547; `routing_exception.dart` lines 57-65 |
| `TransportTarget` | connection endpoint (host/port) | `switch (mode)` exhaustive pattern match in `connect()` | ✓ WIRED | `ams_router.dart` lines 317-319 |
| `AmsRouter auto-derive` | `AdsTransport.localAddress` + `AmsNetId.fromIpv4` | post-dial `_isDottedIpv4` guard then `fromIpv4(localIp)` | ✓ WIRED | `ams_router.dart` lines 416-420 |
| `AmsRouter.resolve` | `AdsRoutingException(0x0007)` | `_requireRoute` throws `missingRoute(netId)` before any I/O | ✓ WIRED | `ams_router.dart` lines 244-251 |
| `AmsRouter addRoute` | route table `_routes` + `_connections` | `_Route` metadata stored; live connection cached by `connect()` | ✓ WIRED | `ams_router.dart` lines 184-194, 456-463 |

---

### Data-Flow Trace (Level 4)

These are library/routing artifacts rather than UI components rendering dynamic data. Key data flows verified:

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|-------------------|--------|
| `_DirectTimeoutConnection.request()` | `AdsTimeoutException` catch | `super.request()` awaited response | ERR-02 enrichment path exercised by integration test with `--delay-ms` mock flag | ✓ FLOWING |
| `AmsRouter.connect()` source port | `openPort()` return value | Fixed 128-slot `_ports` array | Returned to caller as `source.port`; ROUTE01 asserts `inInclusiveRange(30000, 30127)` | ✓ FLOWING |
| `AmsRouter._localAddr` | `getLocalAddress()` return | `setLocalAddress()` or `AmsNetId.fromIpv4(transport.localAddress)` | auto_derive unit test asserts `localNetId == 192.168.0.100.1.1` after connect | ✓ FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| All unit tests (excl. integration) | `dart test -x integration` | 129/129 passing | ✓ PASS |
| Full suite including integration | `dart test` | 155/155 passing | ✓ PASS |
| Static analysis | `dart analyze --fatal-infos` | No issues found | ✓ PASS |

---

### Requirements Coverage

| Requirement | Description | Status | Evidence |
|-------------|-------------|--------|---------|
| ROUTE-01 | User can select transport at runtime — direct-to-peer or via local TwinCAT router | ✓ SATISFIED | `sealed TransportTarget`; ROUTE01 integration test; `connect(mode:)` API |
| ROUTE-02 | Embedded AmsRouter maps AmsNetId → connection and allocates local AMS ports | ✓ SATISFIED | `addRoute`/`getConnection`/`resolve`; `openPort`/`closePort` 128-slot allocator; parity tests |
| ROUTE-03 | User can configure source AmsNetId and local route table for direct mode | ✓ SATISFIED | `setLocalAddress`; `addRoute`/`removeRoute`; `<ip>.1.1` auto-derive |
| ERR-02 | Library surfaces error 1861/0x745 with actionable message naming source AmsNetId | ✓ SATISFIED | `_DirectTimeoutConnection` + `AdsRoutingException.directTimeout`; ERR02 integration test |
| TEST-05 (router slice) | C++ AmsAddr compare; router add/del route + local address; port open/close | ✓ SATISFIED | 1:1-named groups: `testAmsAddrCompare`, `testAdsPortOpenEx`, `testAmsRouterAddRoute`, `testAmsRouterDelRoute`, `testAmsRouterSetLocalAddress` |

**Requirements documentation note (WARNING, non-blocking):** `REQUIREMENTS.md` checkboxes for ROUTE-02 and ROUTE-03 remain `[ ]` (unchecked) and their traceability entries show "Pending". This is a documentation artifact — the implementation fully satisfies both requirements and they are proven by passing tests. The boxes require a manual update to `[x]` and traceability to "Complete" to match the actual state.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/src/router/routing_exception.dart` | 14-15, 55-56 | Stale plan-reference comments ("Plan 04 wires…", "this plan does not wire…") | ℹ️ Info | Plan 04 DID wire the timeout catch. Comments are inaccurate but do not affect runtime behavior. Pre-identified as IN-01 in `04-REVIEW-FIX.md` and explicitly out of scope for the critical/warning fix batch. No functional impact. |

No TBD / FIXME / XXX markers found. No placeholder implementations found. No hardcoded empty returns in non-test code.

---

### Human Verification Required

None — all success criteria are verifiable programmatically. The LocalRouterTarget mock-verified-only limitation is an accepted, documented known limitation per the CONTEXT.md deferred list and the README. CI on GitHub is a known-deferred item excluded per verification context notes.

---

### Gaps Summary

No gaps. All four roadmap success criteria are verified against the current codebase:

- SC-1 (runtime mode selection): `sealed TransportTarget` + `AmsRouter.connect(mode:)` + ROUTE01 integration proof
- SC-2 (AmsRouter maps NetId → connection + port allocation): `addRoute`/`getConnection` + 128-slot `openPort`/`closePort` + parity tests
- SC-3 (configurable source NetId + route table): `setLocalAddress`/`addRoute` + auto-derive + parity tests
- SC-4 (1861/0x745 actionable, never bare timeout): `_DirectTimeoutConnection` ERR-02 wrapper + ERR02 integration test including negative local-router assertion

The full test suite runs at **155/155** and `dart analyze --fatal-infos` is clean.

---

_Verified: 2026-07-04_
_Verifier: Claude (gsd-verifier)_
