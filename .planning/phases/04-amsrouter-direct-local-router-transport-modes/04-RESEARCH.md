# Phase 4: AmsRouter & Direct / Local-Router Transport Modes — Research

**Researched:** 2026-07-04
**Domain:** AMS routing layer (port allocation, route table, source-NetId stamping, transport-mode strategy) ported from the vendored Beckhoff/ADS C++ `AmsRouter`
**Confidence:** HIGH (primary source is the in-repo vendored C++ at `third_party/ADS`; all router semantics read directly from source)

## Summary

Phase 4 adds an `AmsRouter` that sits between `AdsClient` (Phase 3) and `AmsConnection` (Phase 2): it maps a target `AmsNetId` → an owned `AmsConnection`, allocates local AMS ports from base 30000, holds the local route table (`AmsNetId` → host), owns the mutable source/local `AmsNetId`, and selects between two transport modes (`DirectTarget` vs `LocalRouterTarget`). All wire behaviour is already implemented in Phase 2/3 — the router only fills the *addressing seam* that `AdsClient` explicitly reserved (`target`/`source` fields, currently held but unused). ROUTE-01's success criterion — switching direct ↔ local-router requires zero command-code changes — is structurally already true because the command bodies never touch addressing; the router just supplies the two `AmsAddr`s and the endpoint. `[VERIFIED: third_party/ADS/AdsLib/standalone/AmsRouter.cpp, lib/src/client/ads_client.dart]`

The router semantics to mirror are small and fully specified in `AmsRouter.cpp` (254 lines): `OpenPort`/`ClosePort` (128-slot fixed array, base 30000), `AddRoute`/`DelRoute` (route table with a hard "same NetId, different IP ⇒ `ROUTERERR_PORTALREADYINUSE`" rule), `SetLocalAddress`/`GetLocalAddress`, and `GetConnection`. The five C++ parity tests (`testAmsAddrCompare`, `testAmsRouterAddRoute`, `testAmsRouterDelRoute`, `testAmsRouterSetLocalAddress`, `testAdsPortOpenEx`) are transcribed below assertion-by-assertion. The `AmsNetId` value type needs `operator<` (lexicographic on the 6 bytes) and `AmsAddr` needs `operator<` (netId first, then port) added; `Comparable` is the idiomatic Dart shape. `[VERIFIED: third_party/ADS/AdsLib/AdsDef.cpp lines 13-29, AdsLibTest/main.cpp lines 75-174, 309-331]`

**Primary recommendation:** Build `lib/src/router/` with (1) an `AmsRouter` that owns a `Map<AmsNetId, AmsConnection>` plus a 128-slot port allocator and a mutable `localAddr`, accepting an injected **connection/transport factory** so the add/del/setLocalAddress/port logic is unit-testable with `FakeTransport` (no live sockets); (2) a `TransportTarget` sealed strategy (`DirectTarget(host)` / `LocalRouterTarget({host='127.0.0.1', port=48898})`) that only varies the endpoint + which side derives the source NetId; (3) add `Comparable` `operator<` to `AmsNetId`/`AmsAddr`; (4) surface ERR-02 by enriching the direct-mode timeout (which *is* ADS 1861/0x745 `ADSERR_CLIENT_SYNCTIMEOUT`) with an actionable message naming the source NetId, and throwing a clear routing error (0x0007 `GLOBALERR_MISSING_ROUTE`) up-front when the target NetId is not in the route table.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| NetId → connection resolution | Router (`lib/src/router/`) | — | C++ `AmsRouter::GetConnection`; the router owns the mapping |
| Local AMS port allocation (30000+) | Router | — | C++ `AmsRouter::OpenPort`/`ClosePort`; fixed 128-slot array |
| Route table (NetId → host) | Router | — | C++ `AddRoute`/`DelRoute`; direct-mode target resolution (ROUTE-03) |
| Source-NetId stamping onto frames | Connection (Phase 2, unchanged) | Router (supplies the value) | `AmsConnection._buildFrame` already stamps `_source`; router decides *what* source is |
| Source-NetId derivation (explicit or `<ip>.1.1`) | Router | Transport (exposes local IP) | C++ derives `localAddr` from first connection's `ownIp`; needs socket local IP |
| Transport-mode endpoint selection | Router / `TransportTarget` | — | Direct = device:48898; local-router = 127.0.0.1:48898 |
| Command encode/decode | Client + protocol (Phase 3, unchanged) | — | ROUTE-01: command code must not change |
| Missing-route / timeout surfacing (ERR-02) | Router (wrap/enrich) | Client exceptions (carries code) | Router has the source NetId + mode context the message needs |

## Standard Stack

No new external packages. This phase is pure-Dart, built entirely on existing in-repo layers.

### Core (existing, reused)
| Component | Location | Purpose | Why |
|-----------|----------|---------|-----|
| `AmsConnection` | `lib/src/connection/ams_connection.dart` | Correlation, timeout, fan-out; router owns one per NetId | Phase 2 correctness core; unchanged |
| `AdsClient` | `lib/src/client/ads_client.dart` | Six-command async API; `target`/`source` are the reserved router seam | Phase 3; router now supplies addressing |
| `AdsTransport` / `SocketTransport` / `FakeTransport` | `lib/src/transport/` | Injectable socket seam | Router injects a factory → unit-testable route logic |
| `AmsNetId` / `AmsAddr` | `lib/src/protocol/ams_net_id.dart` | Value types; equality exists, ordering to be added | parity `testAmsAddrCompare` |
| `AdsException` + error table | `lib/src/protocol/ads_error.dart` | 0x0007 and 0x0745 already present | ERR-02 codes already mapped |
| `AdsTimeoutException` | `lib/src/connection/exceptions.dart` | Direct-mode missing-reverse-route symptom | ERR-02 enrichment target |

**Installation:** none — no `pubspec.yaml` change. `[VERIFIED: lib/dart_ads.dart barrel, no new deps]`

## Package Legitimacy Audit

Not applicable — this phase installs **no external packages**. All work is pure-Dart on existing in-repo layers. slopcheck / registry verification not required.

## Runtime State Inventory

Not applicable — this is an additive feature phase (new `lib/src/router/`), not a rename/refactor/migration. No stored data, live-service config, OS-registered state, secrets, or build artifacts embed a renamed string. **None — verified: no string-rename or datastore-key change in scope.**

## C++ Router Semantics to Mirror (PRIMARY — read from source)

Constants (`third_party/ADS/AdsLib/Router.h`): `[VERIFIED: Router.h lines 11-12]`
- `PORT_BASE = 30000`
- `NUM_PORTS_MAX = 128`
- Valid port range: `[30000, 30128)`.

### Port allocation — `OpenPort` / `ClosePort` / `GetLocalAddress`
`[VERIFIED: AmsRouter.cpp lines 125-161]`
- `OpenPort()`: linear scan of a fixed 128-slot array; first `!IsOpen()` slot is opened with port `PORT_BASE + i` and that port is returned. **When all 128 are open, returns 0** (exhaustion sentinel, not an exception).
- A port `IsOpen()` iff its stored port value is non-zero (`AmsPort.cpp` line 53-56). `Open(p)` sets `port = p`; `Close()` resets `port = 0` and `tmms = DEFAULT_TIMEOUT (5000)`.
- `ClosePort(port)`: returns `ADSERR_CLIENT_PORTNOTOPEN` (0x0748) if port is out of range **or** the slot is not open; otherwise closes and returns 0.
- `GetLocalAddress(port, &addr)`: range-check → if open, writes `addr.netId = localAddr`, `addr.port = port`, returns 0; else `ADSERR_CLIENT_PORTNOTOPEN`.

### Route table — `AddRoute` / `DelRoute` / `GetConnection`
`[VERIFIED: AmsRouter.cpp lines 29-123, 191-199]`
- `AddRoute(ams, host)` decision tree:
  1. If a connection already maps for `ams` **and it is NOT connected to `host`** → return `ROUTERERR_PORTALREADYINUSE` (0x0506). *(The old route must be `DelRoute`d first.)*
  2. If any existing connection **is** connected to `host` → reuse it (`refCount++`, `mapping[ams] = conn`), return 0. *(This is the "new AMS, existing IP" reuse-by-host case.)*
  3. Otherwise open a new `AmsConnection` to `host`, insert, and **if `localAddr` is still empty, derive it from the connection's `ownIp`** (see below); `refCount++`, `mapping[ams] = conn`, return 0 (or `!ownIp` → nonzero if the socket had no IPv4).
- `DelRoute(ams)`: find mapping; `--refCount`; **only when refCount hits 0** erase the mapping and delete the connection *if no other NetId still maps to it* (`DeleteIfLastConnection`). So a connection shared by two NetIds survives one `DelRoute`.
- `GetConnection(ams)`: `mapping.find(ams)` → pointer or null.

**Design note (connection sharing):** the C++ router shares one `AmsConnection` across multiple NetIds pointing at the same host, refcounted. The Phase-4 CONTEXT decision is "one connection per target NetId" (`Map<AmsNetId, AmsConnection>`). **These do NOT conflict for the parity tests** — `testAmsRouterAddRoute` asserts only the return code (0 / `ROUTERERR_PORTALREADYINUSE`) and `GetConnection != null`; it never asserts that two NetIds share the *same* connection object (see assertion transcript below). A simple `Map<AmsNetId, AmsConnection>` with an explicit host recorded per entry passes every parity assertion, provided it reproduces:
  - same NetId + **different** host ⇒ `ROUTERERR_PORTALREADYINUSE` (0x0506) until removed; `[ASSUMED — recommendation]`
  - same NetId + **same** host ⇒ idempotent success (return 0, no second connection); `[ASSUMED — recommendation]`
  - `DelRoute` closes and unmaps that NetId's connection.
Host-sharing-by-refcount is an optional optimization deferrable to v2. **Recommend the simple one-per-NetId model** to honour the CONTEXT decision literally; document the divergence-from-C++ (no cross-NetId sharing) in the parity test header, same convention as `ads_parity_test.dart`.

### Source NetId derivation — `SetLocalAddress` and the `<ip>.1.1` convention
`[VERIFIED: AmsRouter.cpp lines 72-76, 163-167; AdsDef.cpp AmsNetId(uint32_t) lines 10-18; Sockets.cpp TcpSocket::Connect lines 267-289]`
- `SetLocalAddress(netId)` simply overwrites `localAddr` (mutable). Overridable at any time (ROUTE-03).
- **Auto-derive convention** (`AmsNetId(uint32_t ipv4Addr)`): `b[0..3]` = the four IPv4 octets in **big-endian order** (b[0] = most-significant octet), `b[4] = 1`, `b[5] = 1`. So local IP `192.168.0.100` → source NetId `192.168.0.100.1.1`. `[VERIFIED: AdsDef.cpp lines 10-18]`
- The uint32 fed in is the **socket's local IPv4** obtained via `getsockname` (`TcpSocket::Connect()` returns `ntohl(sin_addr)`; IPv6 → `0xffffffff`, other → 0). Derivation happens lazily on the **first** successful connection, only if no explicit `localAddr` was set. `[VERIFIED: Sockets.cpp lines 267-289, AmsRouter.cpp lines 73-76]`
- **Dart implication:** the transport interface must expose the connected socket's local IPv4 so the router can derive `<ip>.1.1`. `SocketTransport` currently does NOT expose it (`transport.dart` has only `connect/add/inbound/close`). `dart:io Socket.address` is the **local** `InternetAddress` (`.remoteAddress` is the peer) — add a `String? get localAddress` (or `InternetAddress?`) to `AdsTransport`, returning `_socket?.address.address` in `SocketTransport` and a configurable value in `FakeTransport`. `[VERIFIED: lib/src/transport/transport.dart, socket_transport.dart — member absent]`

### Request dispatch & the missing-route return path
`[VERIFIED: AmsRouter.cpp lines 201-213; AdsConnection.cpp AdsRequest lines 144-160]`
- `AmsRouter::AdsRequest`: `GetConnection(destNetId)` → if null, **return `GLOBALERR_MISSING_ROUTE` (0x0007)** immediately (never touches the socket). This is the *local* missing-route case → in Dart, throw the actionable routing error before any I/O.
- Otherwise delegates to the connection with the port's timeout. The connection reads `localAddr` via `router.GetLocalAddress(port)` and stamps it as the source on every frame — exactly the seam `AmsConnection._buildFrame` already occupies in Dart.

## C++ Parity Test Ports (TEST-05 slice) — exact assertions

Name the Dart `group(...)`s 1:1 after these C++ methods (Phase-9 mechanical audit convention). `[VERIFIED: AdsLibTest/main.cpp]`

### `testAmsAddrCompare` (main.cpp lines 75-96) — pure, no sockets
Fixtures: `testee = {192.168.0.231.1.1, 1000}`.
Assertions to reproduce:
- `{192.168.0.231.1.0, 1000} < testee` — differs in **last** NetId byte (lower).
- `{192.168.0.1.1.1, 1000} < testee` — differs in a **middle** NetId byte.
- `{192.168.0.231.1.1, 999} < testee` — same NetId, **lower port**.
- `!(testee < lower_last)`, `!(testee < lower_middle)`, `!(testee < lower_port)` — asymmetry.
- `!(testee < testee)` — irreflexive.

Ordering semantics to implement `[VERIFIED: AdsDef.cpp lines 13-29]`:
- `AmsNetId`: lexicographic over the 6 bytes, `b[0]` most significant.
- `AmsAddr`: compare `netId` first; if equal, compare `port`.
- **Dart shape:** implement `Comparable<AmsNetId>` / `Comparable<AmsAddr>` with `compareTo`, and add `operator<`/`<=`/`>`/`>=` (or just `compareTo` + a small helper). Keep existing `operator==`/`hashCode` unchanged. Add to the pure `ams_net_id.dart` (no new imports).

### `testAmsRouterAddRoute` (main.cpp lines 107-133)
Sequence (all against a fresh `AmsRouter`):
1. New NetId + new host → `AddRoute == 0`; `GetConnection != null`.
2. Same NetId + **different** host → `AddRoute == ROUTERERR_PORTALREADYINUSE (0x0506)`; `GetConnection != null` (old route intact).
3. `DelRoute(netId)`; then same NetId + (that different host) → `AddRoute == 0`; `GetConnection != null`.
4. **New** NetId + an already-used host → `AddRoute == 0`; `GetConnection != null`. *(Return-code only; no same-object assertion — one-per-NetId is fine.)*
5. Same NetId + same host again → `AddRoute == 0` (idempotent); `GetConnection != null`.

Dart staging: inject `FakeTransport` (route-table logic is unit-testable, no live socket). To trigger case 2 the router should detect "existing mapping to a different endpoint" **before** connecting — compare the stored host/port, no second live connection needed.

### `testAmsRouterDelRoute` (main.cpp lines 135-156)
1. Add then `DelRoute` → `GetConnection == null`.
2. Add netId_1 (host A), add netId_2 (host B, **different** host), `DelRoute(netId_1)` → `GetConnection(netId_1) == null`, `GetConnection(netId_2) != null`.

### `testAmsRouterSetLocalAddress` (main.cpp lines 158-174)
1. `port = OpenPort()`.
2. `GetLocalAddress(port, &empty) == 0`; `empty.netId` is falsy (default/empty NetId). *(Dart: an all-zero `AmsNetId`; add an `isEmpty`/`bool` notion or compare to `AmsNetId([0,0,0,0,0,0])`.)*
3. `SetLocalAddress({1,2,3,4,5,6})`; `GetLocalAddress(port, &changed) == 0`; `changed.netId == {1,2,3,4,5,6}`; `changed.port == port`.

### `testAdsPortOpenEx` (main.cpp lines 309-331) — pure, no sockets
1. Open `NUM_PORTS_MAX` (128) ports; each returned port is non-zero (and distinct, 30000..30127).
2. The **129th** `OpenPort()` returns **0** (exhaustion).
3. Close all 128 ports → each `ClosePort` returns 0.
4. Close an already-closed port → `ADSERR_CLIENT_PORTNOTOPEN (0x0748)`.

**Adaptation note for the parity header:** the C++ `testAdsPortOpenEx` exercises the process-global `AdsPortOpenEx`/`AdsPortCloseEx` free functions over the singleton router; in Dart these map to **instance methods on `AmsRouter`** (`openPort()` / `closePort(port)`) — no global singleton. The port-handle *lifecycle* (allocate → release) maps onto router-owned local AMS ports exactly; the C++ "provide out-of-range port ⇒ `ADSERR_CLIENT_PORTNOTOPEN`" cases are reproduced against the instance. This mirrors the Phase-3 "port handles → connection lifecycle" adaptation already documented in `ads_parity_test.dart`.

## Architecture Patterns

### System Architecture Diagram

```
 caller (app / CLI)
        │  router.connect(targetNetId, port) / addRoute / setLocalAddress
        ▼
 ┌─────────────────────── AmsRouter (lib/src/router/) ───────────────────────┐
 │  localAddr: AmsNetId (mutable; explicit OR auto <ip>.1.1)                  │
 │  ports[128]  ── OpenPort/ClosePort ── base 30000                          │
 │  routes: Map<AmsNetId, {host, port}>   (route table, direct mode)         │
 │  connections: Map<AmsNetId, AmsConnection>                                │
 │  mode: TransportTarget (DirectTarget | LocalRouterTarget)                 │
 └───────────┬───────────────────────────────────────────────┬──────────────┘
             │ GetConnection(targetNetId)                     │ derive source
             │   null → GLOBALERR_MISSING_ROUTE (0x0007)      │ (localAddress
             ▼   (throw actionable routing error, no I/O)     │  from socket)
      AmsConnection (Phase 2, unchanged) ◄─── endpoint: ──────┘
             │   Direct: deviceHost:48898
             │   LocalRouter: 127.0.0.1:48898 (or mock ephemeral port)
             ▼
        AdsClient (Phase 3, unchanged) ── six commands, no addressing code
             │
             ▼
   stamps source=localAddr / target=targetNetId onto every frame
             │  request times out in Direct mode → 0x0745 (1861) SYNCTIMEOUT
             ▼  → router enriches to actionable ERR-02 message (source NetId)
        wire (AMS/TCP)
```

### Recommended Project Structure
```
lib/src/router/
├── ams_router.dart       # AmsRouter: port alloc + route table + localAddr + connect()
├── transport_target.dart # sealed TransportTarget → DirectTarget / LocalRouterTarget
└── routing_exception.dart # (or reuse connection/exceptions) actionable ERR-02 / missing-route
```
Add `Comparable` `operator<` to the existing `lib/src/protocol/ams_net_id.dart` (do NOT create a new file — keep the value type cohesive and pure). Export `AmsRouter`, `TransportTarget`/`DirectTarget`/`LocalRouterTarget`, and any new exception from `lib/dart_ads.dart` via `show` clauses (barrel convention: curated surface, `export ... show`). `[VERIFIED: lib/dart_ads.dart export style]`

### Pattern 1: Sealed `TransportTarget` strategy
**What:** a sealed class picks the endpoint + source-derivation policy; the command layers are identical underneath (verified: framing is byte-identical between modes — the mock swaps source/target regardless of NetId).
**When:** at router/connection construction, selectable at runtime (ROUTE-01).
```dart
// Source: derived from CONTEXT decisions + AmsRouter.cpp endpoint semantics
sealed class TransportTarget {
  const TransportTarget();
}
class DirectTarget extends TransportTarget {   // device peer; embedded router stamps source
  const DirectTarget(this.deviceHost, {this.port = 48898});
  final String deviceHost;
  final int port;
}
class LocalRouterTarget extends TransportTarget { // delegate to an installed TwinCAT router
  const LocalRouterTarget({this.host = '127.0.0.1', this.port = 48898});
  final String host;   // configurable so integration tests point at the mock's ephemeral port
  final int port;
}
```

### Pattern 2: Injected connection factory (unit-testable route logic)
**What:** `AmsRouter` accepts a factory `AmsConnection Function(String host, int port, AmsAddr source, AmsAddr target)` (or a transport factory), defaulting to `SocketTransport`. Unit tests inject a `FakeTransport`-backed factory so `addRoute`/`delRoute`/`setLocalAddress`/port allocation are pure logic tests; integration tests use the real socket against the mock.
**Why:** the C++ parity tests open real sockets; Dart can test the route-table algebra without I/O and keep the socket-touching parity in an `@Tags(['integration'])` file. `[VERIFIED: AmsConnection takes an injectable AdsTransport]`

### Anti-Patterns to Avoid
- **Refactoring `AmsConnection` addressing this phase.** The `_source`/`_target` stamping already works; the router supplies the values. Touching `_buildFrame` risks the Phase-2/3 parity. (CONTEXT: "AmsConnection addressing is deliberately not refactored this phase.")
- **Colliding with the existing `AmsPort` constants class.** `lib/src/protocol/constants.dart` already defines `abstract final class AmsPort` (well-known service ports: `plcTc3 = 851`). The router's *local port allocation* (30000+) is a different concept — do NOT name the allocator `AmsPort`. Use e.g. `_LocalPort` / an internal slot list. `[VERIFIED: constants.dart line 71]`
- **Surfacing a bare timeout in direct mode.** ERR-02 forbids it (see below).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Source-NetId `<ip>.1.1` derivation | Custom IP-string math | `AmsNetId` factory mirroring `AmsNetId(uint32_t)`: octets big-endian + `.1.1` | Exact C++ convention; off-by-one on octet order silently mis-addresses `[VERIFIED: AdsDef.cpp]` |
| AmsAddr/NetId ordering | ad-hoc comparisons in the router | `Comparable`/`operator<` on the value types (lexicographic bytes, then port) | Parity test asserts it; also lets the route map use ordered structures if desired |
| Local IP discovery | parse `ifconfig` / guess | `Socket.address.address` (dart:io local address) exposed through the transport | `getsockname` equivalent; portable |
| Missing-route detection | connect-then-timeout probing | up-front `routes.containsKey(targetNetId)` → throw `GLOBALERR_MISSING_ROUTE` | Mirrors `AmsRouter::AdsRequest` returning 0x0007 before I/O |

**Key insight:** every router behaviour here is 250 lines of specified C++ in-repo — port it, don't reinvent it. The only genuinely new Dart concern is exposing the socket's local IP through the transport seam.

## ERR-02 Design — actionable 1861 / missing route

Two DISTINCT failure modes, two DISTINCT codes (both already in the Dart error table): `[VERIFIED: ads_error.dart lines 34-38, 190-194; AdsDef.h lines 138-140, 261-262]`

| Condition | Where detected | ADS code | Surfacing |
|-----------|----------------|----------|-----------|
| **Local** route missing (target NetId not in our route table) | `router.connect` / dispatch, **before any I/O** | `0x0007` `GLOBALERR_MISSING_ROUTE` ("target machine not found, possibly missing ADS routes") | Throw a routing exception **naming the unrouted target NetId** and how to add a route (`addRoute`). Never reaches the socket. |
| **Target-side** reverse route missing (direct mode: the PLC receives our request but drops the response because it has no route back to our source NetId) | request **times out** — the canonical symptom | `0x0745` = **1861** `ADSERR_CLIENT_SYNCTIMEOUT` ("timeout elapsed") | Enrich the timeout into an actionable ERR-02 message naming the **source** NetId the router stamped, suggesting a reverse route on the target (TwinCAT / `adstool addroute`) + firewall / port 48898 check. **Never a bare timeout.** |

**Clarification (important):** the CONTEXT phrase "error 1861/0x745 (missing route)" refers to `ADSERR_CLIENT_SYNCTIMEOUT` (0x0745 = 1861 decimal), **not** `GLOBALERR_MISSING_ROUTE` (0x0007). 1861 is exactly what an operator sees when the *target* lacks a reverse route in direct mode: the request is silently dropped and the client times out. `[VERIFIED: AdsDef.h line 261 (0x45+0x0700), python: 0x745==1861]`

**Recommended implementation (Claude's-discretion area, per CONTEXT):**
- Add a router-layer exception (e.g. `AdsRoutingException`) OR reuse `AdsException(0x0745)` with an enriched message. Requirement: it must **carry code 1861/0x0745**, remain **catchable** as the existing exception family, and its `toString()` must name the source `AmsNetId` and the remediation. Simplest catchable-and-code-carrying option: in `DirectTarget` mode, the router catches `AdsTimeoutException` from `AmsConnection.request` and rethrows an `AdsException`-family error whose code is `0x0745` and whose message is the actionable text (source NetId + "add a reverse route on the target for this NetId; check firewall/port 48898"). Because `AdsException` already exists and 0x0745 is already in the table, `AdsException.fromCode(0x0745)` gives the canonical name/text to compose with the router context. `[VERIFIED: ads_error.dart AdsException.fromCode]`
- Keep local-router mode's timeout as-is (a real router returns 0x0007 itself when it lacks the route — no enrichment needed there; surface the code as the normal `AdsException`).
- **Docs (CONTEXT):** README/dartdoc must note that direct connections require a **reverse** route on the target PLC (added via TwinCAT or `adstool addroute`); programmatic AddRoute over UDP :48899 is v2 (ROUTE-04).

## Mock / Local-Router Test Staging

**Confirmed: the C++ mock stands in for a local TwinCAT router UNCHANGED.** The mock **inverts** the request's addressing for every response (response target = request source, response source = request target) and does **not** validate or match on the target NetId — it answers whatever NetId arrives. `[VERIFIED: test_harness/mock_server.cpp lines 480-485]`

Implications for `LocalRouterTarget` tests:
- Point `LocalRouterTarget(host: '127.0.0.1', port: server.port)` at the mock's ephemeral port (`startMockServer()` → `MockServer.port`). No mock tweak needed. `[VERIFIED: test/support/mock_server.dart]`
- The **same command sequence** through `DirectTarget(host:'127.0.0.1', port: server.port)` and `LocalRouterTarget(host:'127.0.0.1', port: server.port)` against the mock proves ROUTE-01 (zero command-code change) — the only difference is which constructor is used and which side derives the source NetId; the wire bytes and command bodies are identical.
- For the **direct-mode missing-reverse-route** ERR-02 test, the mock must **not** answer, forcing a timeout. The mock already supports leaving a request unanswered: `--close-after N` (leaves a request unanswered, line 475-476) and `--delay-ms` exist; a request that never gets a reply is exactly the Phase-3 `testAdsTimeout` fixture. Reuse that to assert the enriched 1861 message rather than a bare timeout. `[VERIFIED: mock_server.cpp --close-after / --delay-ms options]`
- For the **local missing-route** test (target NetId not in the route table), no mock is needed at all — the router throws `GLOBALERR_MISSING_ROUTE` before any I/O (pure unit test).

## Common Pitfalls

### Pitfall 1: Octet order in `<ip>.1.1` derivation
**What goes wrong:** deriving the source NetId with reversed octets (little-endian) mis-addresses every direct-mode frame.
**Why:** `AmsNetId(uint32_t)` writes `b[0]` = most-significant octet (big-endian), `b[4]=b[5]=1`.
**Avoid:** transcribe `AdsDef.cpp` lines 10-18 exactly; unit-test `192.168.0.100 → 192.168.0.100.1.1`. `[VERIFIED]`

### Pitfall 2: Confusing the two "missing route" codes
**What goes wrong:** throwing 0x0007 for a direct-mode timeout, or 0x0745 for an unrouted NetId.
**Why:** they are different conditions (local table miss vs target has no reverse route).
**Avoid:** table above — local miss = 0x0007 up-front; direct-mode timeout = 0x0745/1861 enriched.

### Pitfall 3: `AmsPort` name collision
**What goes wrong:** naming the port allocator `AmsPort` shadows the existing well-known-ports constants class.
**Avoid:** use a distinct internal name for the 30000+ local-port slots. `[VERIFIED: constants.dart]`

### Pitfall 4: Port-exhaustion returns 0, not an exception (C++ parity)
**What goes wrong:** throwing on the 129th `openPort()` breaks `testAdsPortOpenEx` (expects `0 == OpenPort()`).
**Why:** C++ returns 0 as the sentinel.
**Avoid:** `openPort()` returns `int` (0 = exhausted); a higher-level `connect()` may translate 0 into `ROUTERERR_NOMOREQUEUES`/an exception, but the low-level primitive returns 0 for parity.

### Pitfall 5: Transport doesn't expose local IP
**What goes wrong:** cannot derive `<ip>.1.1` without the socket's local address.
**Avoid:** add `localAddress` to `AdsTransport`/`SocketTransport`/`FakeTransport` as an explicit sub-task before wiring auto-derivation. `[VERIFIED: transport.dart member absent]`

## Code Examples

### Ordering on `AmsNetId` / `AmsAddr` (to add)
```dart
// Source: mirrors third_party/ADS/AdsLib/AdsDef.cpp operator< (lines 13-29)
class AmsNetId implements Comparable<AmsNetId> {
  // ...existing bytes/equality unchanged...
  @override
  int compareTo(AmsNetId other) {
    for (var i = 0; i < byteLength; i++) {
      final d = _bytes[i] - other._bytes[i];
      if (d != 0) return d < 0 ? -1 : 1;
    }
    return 0;
  }
  bool operator <(AmsNetId o) => compareTo(o) < 0;
}

class AmsAddr implements Comparable<AmsAddr> {
  @override
  int compareTo(AmsAddr other) {
    final n = netId.compareTo(other.netId);
    return n != 0 ? n : port.compareTo(other.port);
  }
  bool operator <(AmsAddr o) => compareTo(o) < 0;
}
```

### Auto-derived source NetId
```dart
// Source: AdsDef.cpp AmsNetId(uint32_t ipv4Addr), lines 10-18
AmsNetId amsNetIdFromIpv4(String dottedIpv4) {
  final o = dottedIpv4.split('.').map(int.parse).toList(); // [192,168,0,100]
  return AmsNetId([o[0], o[1], o[2], o[3], 1, 1]);          // 192.168.0.100.1.1
}
```

## State of the Art

| Old Approach | Current Approach | When | Impact |
|--------------|------------------|------|--------|
| Client constructed directly with explicit `source`/`target` (Phase 3 seam) | Client constructed **through the router**, which supplies addressing | Phase 4 | `AdsClient` stays public; router becomes the primary construction path (CONTEXT: "whether AdsClient construction moves behind the router or stays also-public" — recommend **both**: router.connect() is primary, direct construction stays for tests/advanced use) |

**Deprecated/outdated:** the C++ `AddRoute(AmsNetId, IpV4)` overload is `[[deprecated]]` in favour of the string-host overload — mirror only the **host-string** form. `[VERIFIED: AmsRouter.h line 25]`

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | One-connection-per-NetId (no cross-NetId host sharing) is sufficient for all five parity tests | Router semantics / parity | LOW — verified the tests assert only return code + non-null, not connection identity; if a future test asserts sharing, add refcount-by-host |
| A2 | ERR-02 is best surfaced as `AdsException(0x0745)` enriched with router context (vs a new exception subtype) | ERR-02 design | LOW — CONTEXT explicitly leaves this to Claude's discretion; must stay catchable + carry code 1861 either way |
| A3 | `router.connect()` is the primary construction path while `AdsClient`/`AmsConnection` stay also-public | Structure | LOW — CONTEXT lists this as discretion; keeping both is strictly additive |
| A4 | `AdsTransport.localAddress` returning the local IPv4 string is the cleanest way to feed `<ip>.1.1` derivation | Source NetId | LOW — `Socket.address` is the documented local address; FakeTransport makes it configurable |

## Open Questions (RESOLVED)

1. **Does `router.connect()` open a *local AMS port* per client, or per connection?**
   - What we know: C++ `AdsPortOpenEx` (per client handle) and `AddRoute` (per connection) are independent; a port is the source port, a connection is per host.
   - What's unclear: whether the Dart API exposes `openPort` publicly (parity needs it) or folds it into `connect()`.
   - Recommendation: expose `openPort()`/`closePort()` as public router methods (parity requires the exact semantics) AND have `connect()` allocate a port internally — the two are not mutually exclusive.

2. **Source AMS port for direct mode** — C++ uses the allocated 30000+ port as the source port. Confirm the Dart client's source `AmsAddr.port` is the router-allocated local port (30000+), not a fixed value. Recommendation: yes — mirror C++; the allocated port is the source port stamped into frames.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | all | ✓ (existing project) | as pinned in `pubspec.yaml` | — |
| CMake + C++ toolchain | integration parity tests (mock build) | ✓ (used since Phase 1) | existing | unit tests (route algebra, ordering, port alloc) run with FakeTransport, no toolchain |
| Vendored `third_party/ADS` | primary source reference | ✓ in-repo (commit 57d63747) | pinned | — |

No new external dependency. Missing-toolchain path already handled by `startMockServer` (fails loudly).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` (Dart) |
| Config file | none dedicated; `@Tags(['integration'])` gates live-socket suites |
| Quick run command | `dart test test/unit/ -x integration` |
| Full suite command | `dart test` (unit + integration; builds mock via CMake) + `dart analyze --fatal-infos --fatal-warnings` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ROUTE-02 | Port allocation 30000+, 128 slots, exhaustion→0, close semantics | unit | `dart test test/unit/router/ams_router_test.dart -N testAdsPortOpenEx` | ❌ Wave 0 |
| ROUTE-02 | NetId→connection mapping (add/reuse/PORTALREADYINUSE/del) | unit (FakeTransport) | `dart test test/unit/router/ams_router_test.dart -N "testAmsRouterAddRoute\|testAmsRouterDelRoute"` | ❌ Wave 0 |
| ROUTE-03 | `setLocalAddress` overrides; empty default; auto `<ip>.1.1` derive | unit | `dart test test/unit/router/ams_router_test.dart -N testAmsRouterSetLocalAddress` | ❌ Wave 0 |
| ROUTE-03 | Route table resolves target NetId→host; unrouted throws naming NetId | unit | `dart test test/unit/router/ams_router_test.dart -N routing` | ❌ Wave 0 |
| ROUTE-01 | Same command sequence works through Direct AND LocalRouter mode | integration | `dart test test/integration/router_transport_modes_test.dart` | ❌ Wave 0 |
| ERR-02 | Direct-mode timeout surfaces enriched 1861/0x745 naming source NetId (never bare timeout) | integration (mock unanswered) | `dart test test/integration/router_transport_modes_test.dart -N ERR02` | ❌ Wave 0 |
| ERR-02 | Unrouted NetId throws 0x0007 missing-route before I/O | unit | `dart test test/unit/router/ams_router_test.dart -N missing_route` | ❌ Wave 0 |
| TEST-05 | `testAmsAddrCompare` ordering parity | unit (pure) | `dart test test/unit/protocol/ams_net_id_compare_test.dart -N testAmsAddrCompare` | ❌ Wave 0 |
| TEST-05 | 5 router/AmsAddr parity ports, 1:1 C++-named groups | unit + integration | `dart test -N "testAmsAddrCompare\|testAmsRouterAddRoute\|testAmsRouterDelRoute\|testAmsRouterSetLocalAddress\|testAdsPortOpenEx"` | ❌ Wave 0 |

*(Single `-N` regex alternation per project convention; `dart analyze --fatal-infos` in every verify command.)*

### Sampling Rate
- **Per task commit:** `dart test test/unit/router/ -x integration && dart analyze --fatal-infos <touched files>`
- **Per wave merge:** `dart test` (full unit + integration, mock built)
- **Phase gate:** full suite green + `dart analyze --fatal-infos --fatal-warnings` clean before `/gsd:verify-work`.

### Wave 0 Gaps
- [ ] `test/unit/protocol/ams_net_id_compare_test.dart` — `testAmsAddrCompare` (pure ordering)
- [ ] `test/unit/router/ams_router_test.dart` — port alloc, add/del route, setLocalAddress, missing-route (FakeTransport)
- [ ] `test/integration/router_transport_modes_test.dart` — ROUTE-01 dual-mode parity + ERR-02 enriched-1861 (mock unanswered)
- [ ] `FakeTransport.localAddress` configurable + `AdsTransport.localAddress` member added (prerequisite for auto-derive tests)
- [ ] No new framework install — `package:test` already present.

## Security Domain

`security_enforcement` is absent from config (= enabled), but this is a **pure-Dart protocol client library** with no auth/session/crypto surface. Most ASVS categories are N/A.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | ADS route auth (UDP :48899 credentials) is v2 / ROUTE-04, out of scope |
| V3 Session Management | no | connection-oriented TCP, no sessions |
| V4 Access Control | no | client library; access control is the PLC's concern |
| V5 Input Validation | yes | inbound frame bounds already guarded by `FrameAssembler` (max-frame) + decoder length checks (Phase 1/3); router adds no new untrusted-input parsing |
| V6 Cryptography | no | ADS is plaintext TCP by design; no crypto to hand-roll |

### Known Threat Patterns for a Dart ADS router
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed/oversized inbound frame | Denial of Service | Existing `FrameAssembler` max-frame guard + decoder bounds (unchanged this phase) |
| NetId spoofing in responses | Spoofing | Invoke-ID correlation already binds response→request (Phase 2); router does not weaken it |
| Route table pointing at attacker host | Tampering | Routes are explicitly configured by the caller (no auto-discovery — explicitly out of scope); document that route hosts are trusted config |
| Firewall/port 48898 exposure guidance | Information | ERR-02 message directs operators to check firewall/port — operational, not a code vuln |

## Sources

### Primary (HIGH confidence)
- `third_party/ADS/AdsLib/standalone/AmsRouter.cpp` — port alloc, AddRoute/DelRoute, SetLocalAddress, GetConnection, AdsRequest, `<ip>.1.1` derivation
- `third_party/ADS/AdsLib/Router.h` — `PORT_BASE=30000`, `NUM_PORTS_MAX=128`
- `third_party/ADS/AdsLib/AmsPort.h` + `standalone/AmsPort.cpp` — IsOpen/Open/Close semantics
- `third_party/ADS/AdsLib/AdsDef.cpp` — `operator<` for AmsNetId (lexicographic) and AmsAddr (netId then port); `AmsNetId(uint32_t)` `<ip>.1.1`
- `third_party/ADS/AdsLib/standalone/AmsConnection.cpp` + `Sockets.cpp` — `ownIp` from getsockname, source stamping via GetLocalAddress
- `third_party/ADS/AdsLib/standalone/AdsLib.cpp` — AdsPortOpenEx/AddLocalRoute/SetLocalAddress surface
- `third_party/ADS/AdsLibTest/main.cpp` lines 75-174, 309-331 — the five parity tests, assertion-by-assertion
- `third_party/ADS/AdsLib/standalone/AdsDef.h` — `GLOBALERR_MISSING_ROUTE=0x07`, `ROUTERERR_PORTALREADYINUSE=0x506`, `ADSERR_CLIENT_SYNCTIMEOUT=0x745(1861)`, `ADSERR_CLIENT_PORTNOTOPEN=0x748`
- `lib/src/**` — current Dart layers (ams_net_id, ads_client, ams_connection, ads_error, exceptions, transport, constants, barrel)
- `test_harness/mock_server.cpp` lines 480-485 — response addressing inverts request (mock = drop-in local router)
- `test/support/mock_server.dart`, `test/integration/ads_parity_test.dart` — mock launch + parity-test conventions

### Secondary / Derived
- `.planning/phases/04-.../04-CONTEXT.md`, `.planning/REQUIREMENTS.md`, `.planning/STATE.md` — locked decisions & requirement IDs

### Tertiary (LOW confidence)
- None — every load-bearing claim is verified against in-repo source.

## Metadata

**Confidence breakdown:**
- Router semantics / port alloc / route table: HIGH — read directly from vendored C++.
- Parity test assertions: HIGH — transcribed line-by-line from `AdsLibTest/main.cpp`.
- Ordering semantics: HIGH — `AdsDef.cpp operator<` read directly.
- ERR-02 code identification (1861=0x745 SYNCTIMEOUT vs 0x07 MISSING_ROUTE): HIGH — verified in `AdsDef.h` + Dart error table.
- Mock-as-local-router: HIGH — verified inversion logic in `mock_server.cpp`.
- One-per-NetId sufficiency for parity: MEDIUM-HIGH — verified tests don't assert connection identity, but flagged as A1.

**Research date:** 2026-07-04
**Valid until:** stable — the vendored C++ is pinned (commit 57d63747); re-verify only if the submodule is re-pinned.
