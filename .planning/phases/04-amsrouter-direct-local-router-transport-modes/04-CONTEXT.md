# Phase 4: AmsRouter & Direct / Local-Router Transport Modes - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (grey-area recommendations auto-accepted per standing user directive of 2026-07-04)

<domain>
## Phase Boundary

The AmsRouter maps AmsNetId to connection and stamps the source NetId, users select direct-peer or local-TwinCAT-router transport at runtime, and the most common connectivity failure (error 1861 / missing route) is surfaced actionably. Delivers `AmsRouter`, the `TransportTarget` strategy (direct vs local-router), configurable source AmsNetId + local route table, ERR-02's actionable 1861 surfacing, and the router-area C++ parity test ports. No remote AddRoute over UDP :48899 (ROUTE-04, v2). No notifications/sum/symbols.

Requirements: ROUTE-01, ROUTE-02, ROUTE-03, ERR-02 (+ TEST-05 slice: router/AmsAddr parity ports).

</domain>

<decisions>
## Implementation Decisions

### Router API
- `AmsRouter` owns `Map<AmsNetId, AmsConnection>` (one connection per target NetId), allocates local AMS ports from base 30000 (AdsLib parity: PORT_BASE 30000), and holds the local route table (AmsNetId → host/IP)
- `router.connect(targetNetId, port)` (or equivalent) resolves the route, opens/reuses the AmsConnection, and yields an `AdsClient` wired with correct target/source addressing — command code from Phase 3 is unchanged (ROUTE-01 "without changing command code")
- Route management: `addRoute(netId, host)`, `removeRoute(netId)`, `setLocalAddress(netId)` — mirroring AdsLib's AmsRouter surface (also the C++ test parity surface)
- Closing the router closes all owned connections (fan-out reuses Phase 2 semantics)

### Transport Modes
- `TransportTarget` strategy type: `DirectTarget(deviceHost)` — connect to the device IP :48898 with our embedded router stamping source NetId; `LocalRouterTarget({host = '127.0.0.1', port = 48898})` — delegate to an installed TwinCAT router
- Host/port on LocalRouterTarget are configurable so integration tests can point the "local router" at the C++ mock on an ephemeral port
- Mode selectable at runtime per router/connection construction — same framing and command layers underneath (verified project research: framing is identical, only endpoint + source NetId stamping differ)

### Source NetId & Routes (ROUTE-03)
- Source AmsNetId explicitly configurable via `setLocalAddress` (AdsLib parity)
- Direct mode without explicit local address: auto-derive from the socket's local IP + ".1.1" (AdsLib behavior), still overridable
- Local route table used in direct mode to resolve target NetId → host; connecting to an unrouted NetId throws a clear routing error naming the NetId

### ERR-02 — Actionable 1861
- In direct mode, a request timeout is the canonical missing-route symptom: surface it as (or enriched with) ADS error 1861/0x745 semantics with an actionable message that names the source AmsNetId and suggests adding a route on the target (TwinCAT route config) and checking firewall/port 48898 — never a bare timeout
- Implementation detail at Claude's discretion: either enrich AdsTimeoutException with router context or throw AdsException(1861) with the actionable message from the router layer; must remain catchable and carry code 1861
- Documentation: README/dartdoc note that direct connections require a reverse route on the target PLC (added via TwinCAT or adstool addroute; programmatic AddRoute is v2 ROUTE-04)

### C++ Test Parity (TEST-05 slice)
- Port from AdsLibTest/main.cpp: testAmsAddrCompare (AmsAddr/AmsNetId ordering + equality — add Comparable semantics if needed), testAmsRouterAddRoute, testAmsRouterDelRoute, testAmsRouterSetLocalAddress, testAdsPortOpenEx (adapted: port-handle semantics → router/connection lifecycle)
- Name Dart groups 1:1 after C++ scenarios with a header comment mapping adaptations (same convention as ads_parity_test.dart)

### Claude's Discretion
- File layout (suggested lib/src/router/), exact class/constructor shapes, whether AdsClient construction moves behind the router or stays also-public
- Port allocation bookkeeping details (release on close, exhaustion error)
- How LocalRouterTarget testing is staged with the mock (mock speaks the same AMS framing, so it can stand in for a local router)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AmsConnection` (Phase 2): correlation/timeout/fan-out — router owns instances per NetId
- `AdsClient` (Phase 3): target/source held as the explicit Phase-4 seam ("router seam" noted in 03-04 SUMMARY) — router now supplies addressing
- `SocketTransport`/`AdsTransport`/`FakeTransport`; mock launch helper; mock full command set + magic error groups
- `AmsNetId`/`AmsAddr` value types (equality exists; ordering/compare may need adding for testAmsAddrCompare parity)
- Exceptions: AdsTimeoutException, AdsConnectionException, AdsException (code 1861 in table)

### Established Patterns
- protocol/ purity; typed exception families; atomic commits; verify-ordering rule; single --name regex alternation in test filters; dart analyze --fatal-infos in verify commands
- third_party/ADS/AdsLib/AmsRouter.h/.cpp is the reference for router semantics (port base, route table, SetLocalAddress)

### Integration Points
- Phase 5 (notifications) and later phases construct clients through the router
- ERR-02 message references the source NetId the router stamped
- Phase 9 parity audit consumes the 1:1 test-name mapping

</code_context>

<specifics>
## Specific Ideas

- ROUTE-01 success criterion: switching direct ↔ local-router must require zero changes to command-level code — prove with a test that runs the same command sequence through both modes against the mock
- ERR-02 success criterion: a missing-route failure NEVER surfaces as a bare timeout in direct mode
- Reference AdsLib AmsRouter.cpp directly (vendored) when porting semantics — it's in-repo at third_party/ADS

</specifics>

<deferred>
## Deferred Ideas

- Remote AddRoute over UDP :48899 with credentials → v2 (ROUTE-04); CLI `addroute` → v2
- Reconnect/route-recovery semantics → v2 (RECON-01)
- AMS/TCP `0x1000` port-connect registration against a REAL TwinCAT router → v2
  (code-review WR-04): `LocalRouterTarget` currently self-allocates its 30000+
  source port and NetId, which the C++ mock accepts (it echoes any source
  address) but an installed TwinCAT router would not — replies would be
  dropped. Beyond AdsLib parity (the C++ AdsLib IS its own router and never
  dials one); documented as mock-verified-only in the `LocalRouterTarget`
  dartdoc and README until implemented

</deferred>
