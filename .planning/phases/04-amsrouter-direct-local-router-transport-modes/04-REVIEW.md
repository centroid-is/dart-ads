---
phase: 04-amsrouter-direct-local-router-transport-modes
reviewed: 2026-07-04T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - lib/src/router/ams_router.dart
  - lib/src/router/routing_exception.dart
  - lib/src/router/transport_target.dart
  - lib/src/protocol/ams_net_id.dart
findings:
  critical: 3
  warning: 5
  info: 7
  total: 15
open_findings:
  critical: 0
  warning: 0
  info: 7
status: clean
fixed_at: 2026-07-04T13:00:00Z
fix_iteration: 1
fix_scope: critical_warning
fixed: 8
fix_report: 04-REVIEW-FIX.md
verified_at: 2026-07-04T12:52:54Z
review_iteration: 2
---

# Phase 4: Code Review Report

**Reviewed:** 2026-07-04T00:00:00Z
**Re-reviewed (iteration 2):** 2026-07-04T12:52:54Z
**Depth:** standard
**Files Reviewed:** 4 (plus context: transports, connection, client, tests, README)
**Status:** clean — all 3 Critical + 5 Warning findings verified fixed in
iteration 2 (commits 9ed3130..7ebbf55). Info findings IN-01..IN-06 remain open
by scope decision (`fix_scope: critical_warning`); iteration 2 adds one new
Info observation (IN-07). No new Critical or Warning issues were introduced by
the CR-03 dial-point restructure. See `04-REVIEW-FIX.md` for the per-finding
fix report; per-finding **Resolution** and **Verified** notes below.

## Re-review Verification (iteration 2)

Verification basis: full re-read of `ams_router.dart`, `routing_exception.dart`,
`transport_target.dart`, `socket_transport.dart`, `ams_connection.dart`,
`fake_transport.dart`, both test suites, README, and 04-CONTEXT.md; all 27
router unit tests pass (`dart test --tags unit test/unit/router/...`);
`dart analyze` clean on `lib/src/router`, `lib/src/transport`, `test/unit/router`.

| Finding | Verdict | Evidence |
|---------|---------|----------|
| CR-01 | VERIFIED FIXED | `connect()` ties the slot to the connection via `live.done.whenComplete(() => _release(...))` (`ams_router.dart:459-461`); `_release` frees the slot and prunes `_owned`/`_connections`; `close()` tears down every owned connection. Listener-registration order guarantees the slot is free before `await connection.close()` returns (the done-hook is registered at connect time, before any caller's `await done`), pinned by `connect_lifecycle` slot-reuse tests. |
| CR-02 | VERIFIED FIXED | `AmsAddr` validation precedes `openPort()` (`:364`); one rollback guard spans factory → dial → derive (`:380-446`); `_isDottedIpv4` gates the derive INSIDE the guard and provably cannot throw (4 parts, 1-3 digit-only chars, max value 999 pre-range-check). IPv6-skip, pre-allocation `ArgumentError`, and throwing-factory rollback all unit-tested. |
| CR-03 | VERIFIED FIXED | `_Route` is host/port metadata only; `connect()` is the single dial point; `resolve()` throws `0x0007` for unrouted vs `AdsConnectionException` for routed-but-undialed; `hasRoute()` carries the C++ `GetConnection != nullptr` parity assertion; `removeRoute` closes the live connection (DelRoute parity, tested via `await client.connection.done`); the `auto_derive` group now exercises the REAL post-dial derive through `connect()`. Lazy-dial adaptation documented in the class doc and the parity-test header. |
| WR-01 | VERIFIED FIXED | Direct-mode all-zero-source `StateError` (`:353-359`) fires BEFORE `AmsAddr` construction and `openPort()` — a zero source NetId can never be stamped into `_DirectTimeoutConnection.sourceNetId`, so ERR-02 can never name `0.0.0.0.0.0`. Test asserts no slot consumed. |
| WR-02 | VERIFIED FIXED | Dial raced via `.timeout(_connectTimeout)` (`:408`); dedicated `on TimeoutException` rollback releases the slot, closes the connection, throws typed `dialTimeout` (`0x0745`). Abandoned-dial fd handled by `SocketTransport._closed` guard (destroy + `StateError`, `socket_transport.dart:35-47`); the late error is safely swallowed by `Future.timeout`'s post-expiry onError no-op. Hung-dial unit test pins the 0x0745 + rollback. |
| WR-03 | VERIFIED FIXED | Direct-mode endpoint conflict check (`:335-344`) throws `0x0506` `AdsRoutingException` naming BOTH endpoints, pre-allocation; documented on `DirectTarget` and `connect()`; unit-tested (asserts both hosts appear in the message and no slot consumed). |
| WR-04 | VERIFIED FIXED (documentation option) | `LocalRouterTarget` dartdoc limitation block (`transport_target.dart:60-70`); README section "LocalRouterTarget limitation: no `0x1000` port registration yet" (README.md:58-68); 04-CONTEXT.md deferred list tracks the v2 follow-up (:86-91). |
| WR-05 | VERIFIED FIXED | `connect_error_policy` group covers exhaustion → typed `0x0508`, refused-dial slot rollback, direct-mode request timeout → `0x0745` naming the stamped source NetId, local-router timeout staying bare, and a mid-request disconnect crossing the wrapper un-enriched. Assertions are non-vacuous: `isNot(isA<AdsException>())` is meaningful because `AdsTimeoutException`/`AdsConnectionException` sit OUTSIDE the `AdsException` hierarchy; the disconnect test drives a real `simulateDisconnect()`. Integration test asserts both `addRoute` return values (`router_transport_modes_test.dart:88, 138`). All 27 unit tests pass. |

**Restructure regression sweep (no new Critical/Warning):**

- **No double-release:** `done` is a single-shot `Completer`, so `_release`
  runs exactly once per connection; the rollback paths call `closePort` BEFORE
  the done-hook exists (it is registered only on the success path), so timeout/
  failure rollback and the done-hook can never both free the same slot.
- **Per-NetId replacement correct:** a newer `connect()` to the same NetId
  replaces `_connections[netId]` while the older stays in `_owned`; the
  `identical()` check in `_release` (`:491-493`) prevents the older teardown
  from evicting the newer live entry (unit-tested).
- **`router.close()` + done-hook interplay:** `close()` awaits each owned
  `connection.close()`, whose resolution is ordered AFTER that connection's
  `_release` hook (registration order), so all slots are back in the pool
  before `close()` returns — pinned by the frees-every-slot test. The trailing
  defensive `_owned.clear()`/`_connections.clear()` is a no-op in the normal
  path.
- **ERR-02 wrapper still delegating:** `_DirectTimeoutConnection` overrides
  ONLY `request`, catches ONLY `AdsTimeoutException`, and rethrows
  `directTimeout(sourceNetId)` where `sourceNetId` is guaranteed non-zero in
  direct mode by the WR-01 gate. All other members inherit; non-timeout errors
  cross unchanged (T-4-02, tested).
- **Null-safety of the post-guard promotion:** `final live = connection;`
  after the try is validly promoted to non-null — both catch clauses always
  throw, so the join point is reachable only via the assigning path; compiles
  clean under `dart analyze`.

One NEW Info-level observation from the restructure is recorded as IN-07 below
(a `connect()` whose dial straddles `router.close()` survives the close — no
resource is orphaned, so not Warning-tier).

## Summary

The route-table algebra (0x0506 conflict / idempotent re-add), the 0-sentinel
port allocator primitives, `resolve()`'s pre-I/O 0x0007, the sealed
`TransportTarget` dispatch, and the `Comparable` implementations are all sound
in isolation, and the `_DirectTimeoutConnection` wrapper's inheritance-based
delegation is faithful (only `request` is overridden; all other members are
inherited, and it catches exactly `AdsTimeoutException`, which is provably not
in the `AdsException` family, so non-timeout errors cannot be masked and
local-router timeouts cannot be enriched).

*(Iteration-1 assessment, retained for history:)* The port allocator's
*lifecycle integration* is where this phase breaks. There
is exactly one `closePort` call site in the entire connect flow (the dial-failure
rollback); every other exit — including the normal one — leaks the slot
permanently, so a router can only ever serve 128 `connect()` calls over its
lifetime. Two further leak paths sit outside the rollback guard, one of which
(IPv6 local address feeding `AmsNetId.fromIpv4`) also leaks an open socket. And
the route-table connections built by `addRoute` are never dialed, making the
documented `resolve()`/`getConnection()` request path and the production
auto-derive dead on arrival.

*(Iteration-2 assessment:)* All of the above is resolved. The slot lifecycle is
now airtight across every exit path (success → done-hook, dial timeout →
rollback, any other throw → rollback, pre-allocation failures → nothing to roll
back), the dial-point restructure is internally consistent, and the threat
guarantees T-4-01/T-4-02 are pinned by real tests.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: Source-port slot is never released after a successful connect — router exhausts permanently after 128 lifetime `connect()` calls

**File:** `lib/src/router/ams_router.dart:272-317, 322-326`
**Severity:** BLOCKER
**Issue:** `connect()` allocates a source port (line 272) and releases it ONLY
when the dial itself fails (line 305). On the success path the slot stays
occupied forever: nothing ties the returned client's connection teardown back
to `closePort`, `AmsRouter.close()` neither frees `_ports` nor even knows about
`connect()`-created connections (it only closes route-table entries), and the
`connect()` doc never instructs the caller to release `client.source.port`.
After 128 connects — even if every prior client was closed cleanly — every
subsequent `connect()` throws `0x0508 ROUTERERR_NOMOREQUEUES` on a healthy,
idle router. This is precisely the exhaustion scenario threat T-4-01 claims to
handle, but T-4-01 only covers *reporting* exhaustion, not preventing the
guaranteed leak that causes it. Long-running applications (the library's stated
Flutter/daemon use case) with reconnect cycles will hit this in normal
operation.
**Fix:** Release the slot when the connection finishes, and track owned
connections so `close()` tears them down:
```dart
await connection.connect(host, endpointPort);
// Tie slot lifetime to connection lifetime (done completes on close/disconnect).
unawaited(connection.done.whenComplete(() => closePort(sourcePort)));
_ownedConnections.add(connection); // and close these in AmsRouter.close()
```

**Resolution (2026-07-04, commit b4cff2e):** FIXED. Every `connect()`-created
connection registers a `done` hook that frees its slot and prunes the
owned/live registries; `AmsRouter.close()` now tears down every owned
connection. `connect_lifecycle` unit group pins slot reuse after close, full
release on `close()`, and the newer-entry-survives-older-teardown rule.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### CR-02: Port slot (and an open socket) leak on any throw outside the dial guard — realistic on IPv6/dual-stack hosts via `AmsNetId.fromIpv4`

**File:** `lib/src/router/ams_router.dart:272-315` (leak sites: 277, 279, 312-314)
**Severity:** BLOCKER
**Issue:** The `closePort` rollback guards only `connection.connect` (lines
300-307). Three throw sites between `openPort()` and `return` sit OUTSIDE it:

1. **Line 312-314 (post-dial auto-derive), the worst case:** after a successful
   dial, `AmsNetId.fromIpv4(transport.localAddress!)` is called with whatever
   string the transport reports. `SocketTransport.localAddress` returns
   `_socket?.address.address` verbatim (`socket_transport.dart:54-59`) — on a
   dual-stack host or when the endpoint host resolves to IPv6 (e.g.
   `LocalRouterTarget(host: 'localhost')` picking `::1`, or any `fe80::…%if`
   link-local), that is an IPv6 literal. `AmsNetId.fromIpv4` splits on `.`,
   gets ≠4 parts, and throws `MalformedFrameException`
   (`ams_net_id.dart:88-93`). Result: `connect()` throws a framing exception,
   the port slot leaks, AND the freshly connected `AmsConnection`/socket leaks
   with no handle for the caller to close. This fires only when
   `_localAddr` is still unset, i.e. exactly the first-connection case the
   auto-derive exists for.
2. **Line 279:** `AmsAddr(targetNetId, amsPort)` throws `ArgumentError` for a
   non-u16 `amsPort` (`ams_net_id.dart:169-171`) — after the slot was taken.
   128 calls with a bad port brick the router.
3. **Line 277:** a user-injected `TransportFactory` that throws leaks the slot.

**Fix:** Validate/construct everything fallible before `openPort()`, and widen
the guard so the derive failure cannot leak the connection; treat a non-IPv4
local address as "cannot derive" rather than an error:
```dart
final target = AmsAddr(targetNetId, amsPort);   // validate BEFORE openPort()
final transport = _transportFactory(host, endpointPort);
final sourcePort = openPort();
...
try {
  await connection.connect(host, endpointPort);
  final localIp = transport.localAddress;
  if (_localAddr == _emptyNetId && localIp != null && _looksLikeIpv4(localIp)) {
    _localAddr = AmsNetId.fromIpv4(localIp);
  }
} catch (_) {
  closePort(sourcePort);
  unawaited(connection.close());
  rethrow;
}
```

**Resolution (2026-07-04, commit 0f98c32):** FIXED. `AmsAddr(targetNetId,
amsPort)` validates before `openPort()`; one rollback guard spans factory →
dial → derive (releases slot + closes connection on any throw); the derive
runs only for strictly dotted-decimal IPv4 local addresses (`_isDottedIpv4`),
so IPv6/dual-stack skips gracefully. Unit tests pin the IPv6 skip,
pre-allocation `ArgumentError`, and throwing-factory rollback.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### CR-03: `addRoute` never dials its connection — `resolve()`/`getConnection()` return permanently unusable connections and the production auto-derive is dead code

**File:** `lib/src/router/ams_router.dart:163-179, 194-208`
**Severity:** BLOCKER
**Issue:** `addRoute` constructs an `AmsConnection` (line 172) but never calls
`connection.connect(host, port)`. Consequences:

1. Every connection stored in the route table has `isConnected == false`
   forever. `resolve()` is documented as "C++ `AmsRouter::AdsRequest` parity"
   and `getConnection` as the C++ `GetConnection` — but calling `request()` on
   the returned object unconditionally throws
   `AdsConnectionException('not connected')` (`ams_connection.dart:150-152`).
   A consumer following the documented API gets a guaranteed failure on every
   request. (The route connection is also stamped `source: AmsAddr(_localAddr, 0)`
   — source AMS port 0 — so even a manually dialed one would mis-address frames.)
2. The `<ip>.1.1` auto-derive in `addRoute` (lines 167-170) reads
   `transport.localAddress` on a transport that has never connected. For the
   real `SocketTransport` this is ALWAYS `null` pre-connect
   (`socket_transport.dart:54-59`), so the documented "first-connection
   auto-derive" on `addRoute` can never fire in production — it only works in
   the unit tests because `FakeTransport` lets the test stub `localAddress`
   before connect (`ams_router_test.dart:56-62, 189-207`). The `auto_derive`
   unit group is therefore asserting behavior that is unreachable with the
   shipped transport.

The `connect()` flow itself works only because it ignores these connections and
dials a fresh one, using `resolve()` purely as an existence gate.
**Fix:** Either (a) make `addRoute` an async operation that dials the
connection (true C++ `AddRoute` parity, which connects and derives the local
address from the live socket), or (b) stop storing an `AmsConnection` in
`_Route` at all — store only `host`/`port`, change `getConnection`/`resolve`
to return route metadata or remove them from the public surface, and delete
the dead auto-derive in `addRoute` plus the `auto_derive` unit group that
covers it. Option (b) matches how `connect()` actually uses the table today.

**Resolution (2026-07-04, commit 9ed3130):** FIXED via option (b), refined:
`_Route` stores host/port metadata only; `connect()` is the single dial point
and caches its live connection per NetId; `getConnection`/`resolve` serve
only live entries (`resolve` throws `AdsConnectionException` for
routed-but-undialed, `0x0007` for unrouted); new `hasRoute()` carries the C++
`GetConnection != nullptr` parity assertion; `removeRoute` closes the live
connection (DelRoute parity); the `auto_derive` group now exercises the real
post-dial derive through `connect()`. Lazy-dial adaptation documented in the
class doc and parity-test header.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

## Warnings

### WR-01: First direct connect without `setLocalAddress` stamps the all-zero source NetId — and ERR-02 then names `0.0.0.0.0.0` as the NetId to add a reverse route for

**File:** `lib/src/router/ams_router.dart:278, 285-292, 312-315`
**Issue:** `source = AmsAddr(_localAddr, sourcePort)` (line 278) is captured
BEFORE the post-dial auto-derive (lines 312-315), so the first connection's
frames — and the `_DirectTimeoutConnection.sourceNetId` baked in at line 291 —
carry `0.0.0.0.0.0` whenever no explicit `setLocalAddress` was made. In direct
mode this is a guaranteed-failing configuration (no PLC has a reverse route to
the zero NetId), and the ERR-02 enrichment then instructs the operator to "add
a reverse ADS route back to source NetId 0.0.0.0.0.0" — actively misleading
remediation. The doc comment acknowledges the ordering ("for SUBSEQUENT
connects") but shipping a first connection that is known-misaddressed, with an
error message naming a nonsense NetId, degrades the exact UX ERR-02 exists to
fix.
**Fix:** Fail fast instead: in direct mode with `_localAddr == _emptyNetId`,
either throw a typed error up front ("set a local address before direct
connects") or restructure to dial the transport first, derive, and only then
construct the addressed connection. At minimum, special-case the ERR-02
message when `sourceNetId` is all-zero.

**Resolution (2026-07-04, commit ab0ff52):** FIXED (fail-fast option). Direct
mode with an all-zero local address now throws a `StateError` naming
`setLocalAddress` before any allocation or I/O, so a zero source NetId can
never be stamped and ERR-02 can never name `0.0.0.0.0.0`. Local-router mode
still allows the unset state and its first connect seeds the auto-derive.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### WR-02: `connect()` has no dial timeout — a direct connect to an unreachable host hangs for the OS TCP timeout (minutes)

**File:** `lib/src/router/ams_router.dart:301` (via `socket_transport.dart:27`)
**Issue:** `await connection.connect(host, endpointPort)` bottoms out in
`Socket.connect(host, port)` with no `timeout:` argument. `_defaultTimeout`
(5 s) governs only per-request futures, not the dial. A `DirectTarget`
pointing at a powered-off PLC — the most common field failure — blocks
`router.connect()` for the platform's TCP connect timeout (75 s+ on macOS,
~2 min on Linux) with no way to apply the router's configured timeout. This is
new Phase-4 surface: the router layer introduced the dial path and owns the
timeout policy.
**Fix:** Race the dial against `_defaultTimeout` in `AmsRouter.connect` (and
release the port slot on expiry), e.g.
`await connection.connect(host, endpointPort).timeout(_defaultTimeout)` with
the existing rollback catch, or plumb a timeout into
`AdsTransport.connect`/`Socket.connect(host, port, timeout: …)`.

**Resolution (2026-07-04, commit 62ef2bd):** FIXED. `AmsRouter` gains a
`connectTimeout` constructor parameter (default 5 s); the dial is raced via
`.timeout()`, expiry rolls back the slot + connection and throws a typed
`AdsRoutingException.dialTimeout` (`0x0745`) with dial-specific remediation.
`SocketTransport` destroys a socket whose dial completes after `close()`, so
the abandoned dial cannot leak an fd. Hung-dial unit test pins the behavior.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### WR-03: Direct-mode route gate checks only NetId existence — `DirectTarget.deviceHost` is never reconciled with the routed host

**File:** `lib/src/router/ams_router.dart:263-268` (with `transport_target.dart:37-46`)
**Issue:** `connect()` requires the caller to state the endpoint twice — once
in `addRoute(netId, host)` and again in `DirectTarget(deviceHost)` — and never
checks they agree. `addRoute(netId, 'hostA')` followed by
`connect(netId, …, mode: DirectTarget('hostB'))` passes the 0x0007 gate and
sends every frame to `hostB` while the route table (the thing the gate claims
authority over) says `hostA`. The gate is decorative: it validates presence,
not the route. A typo'd host in one of the two places produces frames to the
wrong device with no diagnostic, which is exactly the misrouting class the
route table exists to prevent.
**Fix:** In direct mode, either derive the endpoint from the route
(`final route = resolve-as-_Route; dial route.host:route.port`, making
`DirectTarget`'s host optional/absent), or throw
`ROUTERERR_PORTALREADYINUSE`-style conflict when
`mode.deviceHost:port != route.host:port`.

**Resolution (2026-07-04, commit 5396788):** FIXED (conflict-throw option).
Direct mode now throws an `AdsRoutingException` with `0x0506`
`ROUTERERR_PORTALREADYINUSE` naming BOTH endpoints when
`DirectTarget.deviceHost:port` disagrees with the route-table entry, before
any allocation or I/O. Documented on `DirectTarget` and `AmsRouter.connect`;
unit-tested.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### WR-04: `LocalRouterTarget` omits the AMS/TCP port-registration handshake a real TwinCAT router requires — self-allocated 30000+ source ports are only valid against the mock

**File:** `lib/src/router/ams_router.dart:272-298`, `transport_target.dart:48-63`
**Issue:** When dialing a local TwinCAT router at `127.0.0.1:48898`, a client
must register with the router (AMS/TCP header type `0x1000` port-connect,
receiving its assigned local AmsNetId + AMS port) before the router will route
replies back to it — this is what reference client implementations do on the
local-router path. Phase 4's local-router mode instead self-allocates a source
port from its private 30000-range and stamps its own source NetId, which a real
router has never heard of; replies would be dropped. The integration suite
cannot catch this because the C++ mock "stands in for a local router
unchanged" (`router_transport_modes_test.dart:10-12`) and echoes any source
address. If the handshake is deliberately deferred to a later phase, the
`LocalRouterTarget` doc and README ("delegate onward routing to an installed
TwinCAT router") overstate what ships today and should say so.
**Fix:** Implement the `0x1000` port-connect exchange in the local-router
connect path (using the router-assigned NetId/port as the source address for
that connection), or document `LocalRouterTarget` as mock-verified only with a
tracked follow-up requirement.

**Resolution (2026-07-04, commit 3a070b0):** FIXED (documentation option, per
review fix scope — the `0x1000` handshake is beyond AdsLib parity: the C++
AdsLib IS its own router and never dials one). `LocalRouterTarget` dartdoc
gains a prominent "mock-verified only" limitation block, README gains a
matching section, and `04-CONTEXT.md`'s deferred list tracks the v2
follow-up.

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

### WR-05: Named threat guarantees T-4-01 and T-4-02 are asserted in docs but untested

**File:** `test/unit/router/ams_router_test.dart` (whole file), `test/integration/router_transport_modes_test.dart:124-201`
**Issue:** No test anywhere calls `router.connect()` in the unit suite, so the
three connect-flow behaviors the phase context and doc comments name as threat
mitigations are unverified:
1. **T-4-01:** `connect()` translating port exhaustion into a typed `0x0508`
   `AdsException` (only the raw `openPort() == 0` sentinel is tested, lines
   78-79);
2. **dial-failure rollback:** `closePort(sourcePort)` on a failed dial (lines
   300-307 of the router) — a `FakeTransport` whose `connect` throws would
   cover it in three lines;
3. **T-4-02 pass-through:** "every OTHER error propagates UNCHANGED" through
   `_DirectTimeoutConnection` — only the timeout-enrichment and local-mode
   non-enrichment sides are tested; nothing proves a device `errorCode`, an
   `AdsConnectionException` disconnect, or a `MalformedFrameException` crosses
   the direct-mode wrapper un-wrapped.
Given CR-01/CR-02 live exactly in this untested region, the gap is not
hypothetical.
**Fix:** Add unit tests: exhaust 128 slots then expect
`connect(...)` to throw `AdsException` with `code == 0x0508`; a throwing-connect
`FakeTransport` then assert the next `openPort()` still returns the same slot;
and a direct-mode connection where `simulateDisconnect()` /a nonzero AMS
`errorCode` reply surfaces as its original family. Also assert the return value
of `router.addRoute(...)` in the integration test (`router_transport_modes_test.dart:88, 137`)
instead of discarding it.

**Resolution (2026-07-04, commit 7cd21ba):** FIXED. New `connect_error_policy`
unit group covers: exhaustion → typed `0x0508` (T-4-01), refused-dial slot
rollback, direct-mode request timeout → `0x0745` naming the real stamped
source NetId, local-router timeout staying a bare `AdsTimeoutException`, and
a mid-request disconnect crossing the direct-mode wrapper un-enriched
(T-4-02). The integration suite now asserts both `addRoute(...)` return
values. Together with the tests added alongside CR-01/CR-02/WR-01/WR-02/WR-03
the unit suite grew from 113 to 129 tests (155 total with integration).

**Verified (2026-07-04, iteration 2):** CONFIRMED. See re-review table above.

## Info

### IN-01: Stale "this plan does NOT wire the timeout catch" docs contradict the shipped wrapper

**File:** `lib/src/router/routing_exception.dart:14-16, 54-55`
**Issue:** Both the library doc and the `directTimeout` factory doc state the
timeout catch is not wired ("Composition only — Plan 04 wires the direct-mode
timeout catch that throws this; this plan does not"), but Phase 4 wired it
(`_DirectTimeoutConnection`). Future readers will conclude the enrichment is
missing.
**Fix:** Update both comments to point at `_DirectTimeoutConnection` as the
throw site.

### IN-02: `AmsNetId.fromIpv4`/`.parse` inherit `int.tryParse` laxity — hex, signs, and whitespace octets are accepted

**File:** `lib/src/protocol/ams_net_id.dart:63-64, 96-97`
**Issue:** `int.tryParse` accepts `0x`-prefixed hex, a leading `+`, and
surrounding whitespace, so `AmsNetId.fromIpv4('0x0A.1.2.3')` yields
`10.1.2.3.1.1` and `' 5'`/`'+5'` octets parse silently instead of throwing the
documented `MalformedFrameException`. The `fromIpv4` input is normally OS
`getsockname` output (clean), but `parse` takes user config strings.
**Fix:** Validate with a digit-only check (e.g.
`RegExp(r'^\d{1,3}$').hasMatch(part)`) before `int.parse`.
*(Iteration-2 note: the router-side derive is no longer exposed to this —
`_isDottedIpv4` pre-filters with a strict digit-only check before
`AmsNetId.fromIpv4` is called — but `AmsNetId.parse` itself retains the
laxity.)*

### IN-03: `directTimeout` enrichment discards the original timeout's `invokeId`/`commandId` — no cause chaining

**File:** `lib/src/router/ams_router.dart:362-363`
**Issue:** `on AdsTimeoutException { throw AdsRoutingException.directTimeout(...) }`
drops the caught exception; the invoke-ID and command-ID that identify which
in-flight request expired are lost from logs.
**Fix:** Pass the caught exception through (add a `cause` field to
`AdsRoutingException` or append `e.invokeId`/`e.commandId` to the message).

### IN-04: `AmsAddr` defines only `<` while `AmsNetId` defines all four relational operators

**File:** `lib/src/protocol/ams_net_id.dart:198-199` (vs `143-152`)
**Issue:** Asymmetric comparable surface introduced this phase: `AmsNetId` has
`<`, `<=`, `>`, `>=`; `AmsAddr` has only `<`. Callers writing `addrA > addrB`
get a compile error and will wonder which type they hold.
**Fix:** Add the remaining three operators to `AmsAddr` (or drop the extras
from `AmsNetId` and standardize on `compareTo`).

### IN-05: `addRoute` host conflict check is raw string equality — no normalization

**File:** `lib/src/router/ams_router.dart:157`
**Issue:** `'192.168.0.1'` vs `'192.168.000.1'` vs a hostname resolving to the
same IP are treated as different endpoints, producing a spurious `0x0506` (or,
inversely, missing a real conflict). The C++ router compares resolved
addresses.
**Fix:** Document that hosts are compared verbatim, or normalize (lowercase +
`InternetAddress.tryParse` canonical form) before comparing.
*(Iteration-2 note: the WR-03 conflict check inherits the same verbatim
comparison — `addRoute(netId, 'localhost')` + `DirectTarget('127.0.0.1')` is a
spurious 0x0506. Same root cause, same fix.)*

### IN-06: `_DirectTimeoutConnection.request` converts the base class's synchronous 'not connected' throw into an async failure

**File:** `lib/src/router/ams_router.dart:354-365`
**Issue:** `AmsConnection.request` is non-`async` and throws
`AdsConnectionException('not connected')` synchronously; the `async` override
turns that into a failed Future. Behavior differs between the two transport
modes for any caller invoking `request` in a synchronous try/catch. `AdsClient`
always awaits, so impact is nil today; noting for API-parity hygiene.
**Fix:** None required; if parity matters, hoist the `isConnected` check or use
a non-async wrapper with `.catchError`-style rethrow on the returned future.

### IN-07 (new, iteration 2): A `connect()` whose dial straddles `router.close()` survives the close untorn

**File:** `lib/src/router/ams_router.dart:500-508` (with `:456-461`)
**Issue:** `close()` snapshots `_owned` and awaits the teardowns; a `connect()`
whose dial is still in flight at that moment is not yet in `_owned`, so when
its dial completes (possibly after `close()` returned) the connection is added
to `_owned`/`_connections` and then immediately stranded by the trailing
defensive `_owned.clear()`/`_connections.clear()` — meaning a SECOND
`router.close()` would not close it either, and `getConnection()` cannot see
it. No resource is orphaned (the caller holds the returned `AdsClient` and can
close it; the `done` hook still frees the source-port slot regardless of
registry membership), and the router is documented as reusable after `close()`,
so this is a benign TOCTOU rather than a leak — but the `close()` doc's "closes
every connect-created connection still alive" is not strictly true under this
race.
**Fix:** None required for v1. If strictness matters later: add a `_closing`
flag that makes an in-flight `connect()` roll back (slot + connection) and
throw instead of completing after `close()` began, or re-check `_closing` after
the dial and self-close.

---

_Reviewed: 2026-07-04T00:00:00Z_
_Re-reviewed (iteration 2): 2026-07-04T12:52:54Z — all Critical/Warning fixes verified; status: clean_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
