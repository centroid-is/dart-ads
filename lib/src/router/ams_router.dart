/// The [AmsRouter] registry — the unit-testable "route algebra" ported from the
/// vendored Beckhoff/ADS C++ `AmsRouter` (`third_party/ADS/AdsLib/standalone/
/// AmsRouter.cpp`, `Router.h`).
///
/// It owns three things:
///   * a fixed 128-slot local-AMS-port allocator based at 30000
///     ([openPort] / [closePort]);
///   * the route table mapping a target [AmsNetId] → its endpoint host/port
///     ([addRoute] / [removeRoute] / [hasRoute]), plus the LIVE
///     [AmsConnection]s that [connect] — the single dial point — has opened
///     against those routes ([getConnection] / [resolve]);
///   * the mutable source/local [AmsNetId] ([setLocalAddress] /
///     [getLocalAddress]) with lazy `<ip>.1.1` auto-derivation on the first
///     successful [connect].
///
/// Connections are built through an injected [TransportFactory] so the whole
/// route/port/localAddr algebra is exercised by a `FakeTransport` with no live
/// sockets. [AmsRouter.connect] turns a target NetId + a [TransportTarget]
/// mode into a ready [AdsClient] (source→target addressed), and — in
/// [DirectTarget] mode ONLY — enriches a request timeout into an actionable
/// ADS `0x0745`/1861 error naming the source NetId (ERR-02) instead of a bare
/// timeout.
///
/// Divergences from C++ (documented for the parity tests):
///   * the C++ router shares one refcounted `AmsConnection` across multiple
///     NetIds pointing at the same host; this Dart port keeps ONE live
///     connection per target NetId (`Map<AmsNetId, AmsConnection>`). Every
///     parity assertion (return code + route presence) holds either way — the
///     tests never assert two NetIds share the same connection object.
///   * the C++ `AddRoute` dials its connection eagerly (it is synchronous C++
///     socket code); this async Dart port stores only the endpoint metadata in
///     [addRoute] and dials lazily in [connect]. An `addRoute`d-but-never-
///     `connect`ed NetId therefore has a route ([hasRoute] is true) but no
///     live connection yet ([getConnection] is null). This keeps `addRoute`
///     synchronous (C++ signature parity) without ever exposing an un-dialed,
///     permanently dead `AmsConnection`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../client/ads_client.dart';
import '../connection/ams_connection.dart';
import '../connection/exceptions.dart';
import '../protocol/ads_error.dart';
import '../protocol/ams_net_id.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'routing_exception.dart';
import 'transport_target.dart';

/// Builds the [AdsTransport] a new route connects over, given its [host] and
/// [port]. Defaults to a `dart:io` [SocketTransport]; unit tests inject a
/// `FakeTransport`-returning factory so route logic runs without sockets.
typedef TransportFactory = AdsTransport Function(String host, int port);

/// A single route-table entry: the endpoint [host]/[port] a target NetId is
/// reached at. Pure metadata — no connection object is built until
/// [AmsRouter.connect] dials one (the "same NetId, different host ⇒
/// PORTALREADYINUSE" and "same host ⇒ idempotent" rules are decided on this
/// record alone, before any I/O).
class _Route {
  const _Route(this.host, this.port);

  final String host;
  final int port;
}

/// The AMS routing registry: local-port allocator, route table, and mutable
/// source address, behind an injectable connection/transport factory.
class AmsRouter {
  /// Creates a router that builds route connections via [transportFactory]
  /// (default: a real [SocketTransport] per route), applying [defaultTimeout]
  /// to each owned [AmsConnection]'s requests and bounding each [connect]
  /// dial by [connectTimeout].
  ///
  /// Without [connectTimeout] the dial would hang for the OS TCP connect
  /// timeout (minutes) when the endpoint host is unreachable — the most
  /// common direct-mode field failure (device powered off / wrong IP).
  AmsRouter({
    TransportFactory? transportFactory,
    Duration defaultTimeout = const Duration(seconds: 5),
    Duration connectTimeout = const Duration(seconds: 5),
  })  : _transportFactory =
            transportFactory ?? ((host, port) => SocketTransport()),
        _defaultTimeout = defaultTimeout,
        _connectTimeout = connectTimeout;

  /// Base of the local AMS port range (`PORT_BASE`, `Router.h`). The allocator
  /// hands out `[portBase, portBase + numPortsMax)` = `[30000, 30128)`.
  static const int portBase = 30000;

  /// Number of local AMS port slots (`NUM_PORTS_MAX`, `Router.h`).
  static const int numPortsMax = 128;

  /// `ROUTERERR_PORTALREADYINUSE` — same NetId already routed to a different
  /// host; the old route must be [removeRoute]d first.
  static const int _routerErrPortAlreadyInUse = 0x0506;

  /// `ADSERR_CLIENT_PORTNOTOPEN` — [closePort] of an out-of-range or
  /// already-closed local port.
  static const int _adsErrClientPortNotOpen = 0x0748;

  /// `ROUTERERR_NOMOREQUEUES` — all [numPortsMax] local ports are allocated;
  /// [connect] translates the [openPort] `0` exhaustion sentinel into this typed
  /// error rather than looping or hanging (threat T-4-01).
  static const int _routerErrNoMoreQueues = 0x0508;

  /// The all-zero default source NetId — "no local address set yet".
  static final AmsNetId _emptyNetId = AmsNetId(List<int>.filled(6, 0));

  final TransportFactory _transportFactory;
  final Duration _defaultTimeout;
  final Duration _connectTimeout;

  /// Fixed 128-slot local-port allocator. `_ports[i] == 0` means slot `i` is
  /// free; otherwise it holds the assigned port value `portBase + i`.
  final List<int> _ports = List<int>.filled(numPortsMax, 0);

  /// The route table: target NetId → its endpoint metadata (no connection —
  /// [connect] is the single dial point).
  final Map<AmsNetId, _Route> _routes = <AmsNetId, _Route>{};

  /// Live connections dialed by [connect], keyed by target NetId (one per
  /// NetId; a second [connect] to the same NetId replaces the entry while the
  /// older connection stays owned until it closes).
  final Map<AmsNetId, AmsConnection> _connections = <AmsNetId, AmsConnection>{};

  /// EVERY [connect]-created connection still alive — including ones displaced
  /// from [_connections] by a newer [connect] to the same NetId. [close] tears
  /// these down; each removes itself (and frees its source-port slot) when its
  /// `done` future completes.
  final Set<AmsConnection> _owned = <AmsConnection>{};

  /// The mutable source/local AMS Net ID; all-zero until [setLocalAddress] or
  /// the first-connection `<ip>.1.1` auto-derive sets it.
  AmsNetId _localAddr = _emptyNetId;

  /// Allocates the first free local AMS port, returning `portBase + i`, or `0`
  /// when all [numPortsMax] slots are open (exhaustion sentinel — NOT an
  /// exception; C++ `OpenPort` parity). Allocated ports are distinct and lie in
  /// `[30000, 30128)`.
  int openPort() {
    for (var i = 0; i < numPortsMax; i++) {
      if (_ports[i] == 0) {
        _ports[i] = portBase + i;
        return portBase + i;
      }
    }
    return 0;
  }

  /// Releases a previously [openPort]-ed local AMS [port].
  ///
  /// Returns `0` on success, or `ADSERR_CLIENT_PORTNOTOPEN` (`0x0748`) if [port]
  /// is out of the `[30000, 30128)` range OR the slot is not currently open
  /// (C++ `ClosePort` parity).
  int closePort(int port) {
    final index = port - portBase;
    if (index < 0 || index >= numPortsMax || _ports[index] == 0) {
      return _adsErrClientPortNotOpen;
    }
    _ports[index] = 0;
    return 0;
  }

  /// Maps target [netId] to the endpoint [host]:[port] (metadata only — the
  /// connection is dialed later, by [connect]).
  ///
  /// Decision tree (C++ `AddRoute` parity, lazy-dial variant):
  ///   * new [netId] → record the endpoint, return `0`;
  ///   * existing [netId] to a DIFFERENT [host]/[port] → return
  ///     `ROUTERERR_PORTALREADYINUSE` (`0x0506`), leaving the old route intact
  ///     ([removeRoute] it first);
  ///   * existing [netId] to the SAME [host]/[port] → idempotent `0`;
  ///   * a new [netId] whose [host] is already used by another NetId → `0`
  ///     with its own entry (this port does not share connections across
  ///     NetIds — see the class divergence note).
  ///
  /// Unlike the C++ `AddRoute`, no connection is opened here and the source
  /// NetId is NOT derived here: a real `SocketTransport` has no local address
  /// until it dials, so the `<ip>.1.1` auto-derive runs after the first
  /// successful [connect] instead.
  int addRoute(AmsNetId netId, String host, {int port = 48898}) {
    final existing = _routes[netId];
    if (existing != null) {
      if (existing.host == host && existing.port == port) {
        return 0; // Idempotent: same NetId, same endpoint.
      }
      return _routerErrPortAlreadyInUse; // Same NetId, different endpoint.
    }
    _routes[netId] = _Route(host, port);
    return 0;
  }

  /// Removes the route for [netId], closing its live [connect]-created
  /// connection if one exists (C++ `DelRoute` parity: the route's connection
  /// does not survive the route).
  ///
  /// The mappings are dropped synchronously (so [hasRoute] /
  /// [getConnection] / [resolve] see them gone immediately); the connection
  /// teardown is fire-and-forget. Routes for other NetIds are unaffected. A
  /// no-op if [netId] is not routed.
  void removeRoute(AmsNetId netId) {
    _routes.remove(netId);
    final live = _connections.remove(netId);
    if (live != null) {
      unawaited(live.close());
    }
  }

  /// Whether target [netId] has a route-table entry (the Dart adaptation of
  /// the C++ parity assertion `GetConnection(netId) != nullptr` after
  /// `AddRoute` — this port dials lazily in [connect], so route presence and
  /// live-connection presence are distinct).
  bool hasRoute(AmsNetId netId) => _routes.containsKey(netId);

  /// The LIVE [AmsConnection] the most recent successful [connect] opened for
  /// target [netId], or `null` when none exists (not routed, never connected,
  /// or already closed). Never returns an un-dialed connection.
  AmsConnection? getConnection(AmsNetId netId) => _connections[netId];

  /// Resolves target [netId] to its live [AmsConnection].
  ///
  /// Throws [AdsRoutingException] (`0x0007` `GLOBALERR_MISSING_ROUTE`) naming
  /// [netId] when it is not in the route table — BEFORE any socket I/O (C++
  /// `AmsRouter::AdsRequest` parity) — and [AdsConnectionException] when the
  /// route exists but no live connection has been dialed yet (call [connect]
  /// first; the C++ router has no such state because its `AddRoute` dials
  /// eagerly).
  AmsConnection resolve(AmsNetId netId) {
    _requireRoute(netId);
    final live = _connections[netId];
    if (live == null) {
      throw AdsConnectionException(
        'no live connection for NetId ${netId.dotted}: '
        'connect() dials one (addRoute only records the endpoint)',
      );
    }
    return live;
  }

  /// The route for [netId], or an [AdsRoutingException] (`0x0007`
  /// `GLOBALERR_MISSING_ROUTE`) naming [netId] — the shared pre-I/O gate.
  _Route _requireRoute(AmsNetId netId) {
    final route = _routes[netId];
    if (route == null) {
      throw AdsRoutingException.missingRoute(netId);
    }
    return route;
  }

  /// Overwrites the source/local AMS Net ID (C++ `SetLocalAddress` parity).
  /// Overridable at any time; suppresses the `<ip>.1.1` auto-derive.
  void setLocalAddress(AmsNetId netId) => _localAddr = netId;

  /// The current source/local AMS Net ID — the all-zero [emptyLocalAddress] by
  /// default, an explicit [setLocalAddress] value, or the first-connection
  /// `<ip>.1.1` auto-derived value.
  AmsNetId getLocalAddress() => _localAddr;

  /// The all-zero NetId that [getLocalAddress] returns before any address is
  /// set — exposed so callers/tests can recognise the "unset" state.
  static AmsNetId get emptyLocalAddress => _emptyNetId;

  /// Resolves [targetNetId] over the chosen [mode], opens a connection, and
  /// returns a ready [AdsClient] addressed source→target (ROUTE-01).
  ///
  /// The command bodies never change between modes — only the endpoint and the
  /// routing/error policy differ:
  ///   * [DirectTarget] dials the device peer directly. The target NetId MUST be
  ///     in this router's route table (add it with [addRoute] first) or a
  ///     `0x0007` `GLOBALERR_MISSING_ROUTE` [AdsRoutingException] is thrown
  ///     BEFORE any socket I/O — never a connect-then-timeout probe. The
  ///     [DirectTarget]'s host:port must AGREE with that route-table entry:
  ///     a mismatch throws a `0x0506` `ROUTERERR_PORTALREADYINUSE`
  ///     [AdsRoutingException] naming both endpoints (the route table is the
  ///     routing authority; a typo'd host must not silently misroute). A request
  ///     that later times out is enriched into an actionable `0x0745`/1861
  ///     [AdsRoutingException] naming the stamped source NetId (ERR-02); every
  ///     OTHER error (device errors, disconnects, malformed frames) propagates
  ///     UNCHANGED so a real fault is never masked as a route problem (T-4-02).
  ///   * [LocalRouterTarget] dials a local router that owns onward routing, so no
  ///     route-table entry is required and its timeouts/errors pass through
  ///     unenriched (a real router returns its own `0x0007`).
  ///
  /// A local AMS port (`[30000, 30128)`) is allocated as the SOURCE port; if all
  /// [numPortsMax] are taken, a `0x0508` `ROUTERERR_NOMOREQUEUES` [AdsException]
  /// is thrown (T-4-01). The slot is owned by the returned client's connection:
  /// it is released automatically when that connection finishes (close the
  /// client's `connection`, a peer disconnect, or [AmsRouter.close], which
  /// tears down every `connect`-created connection) — so reconnect cycles never
  /// exhaust the fixed range. The returned client is addressed
  /// `source = AmsAddr(localAddr, allocatedPort)` →
  /// `target = AmsAddr(targetNetId, amsPort)`.
  ///
  /// The dial itself is bounded by the router's `connectTimeout` (constructor
  /// parameter, default 5 s): an unreachable endpoint yields a `0x0745`
  /// [AdsRoutingException] with dial-specific remediation after a clean
  /// rollback — never an OS-length (minutes) TCP connect hang.
  ///
  /// The first successful connection lazily auto-derives the router's source
  /// NetId as `<ip>.1.1` from the socket's local IPv4 (C++ parity) when no
  /// explicit [setLocalAddress] was made. Because the derive can only run
  /// AFTER a dial, a DIRECT connect with the source NetId still all-zero would
  /// send known-misaddressed frames (and ERR-02 would name `0.0.0.0.0.0`) —
  /// so direct mode throws a [StateError] up front in that state: call
  /// [setLocalAddress] before the first direct connect (or connect through a
  /// local router once, letting the auto-derive seed it).
  Future<AdsClient> connect(
    AmsNetId targetNetId,
    int amsPort, {
    required TransportTarget mode,
  }) async {
    // Endpoint + direct-mode flag from the sealed transport target. Exhaustive
    // over the two subtypes (adding a mode is a compile-time prompt here).
    final (String host, int endpointPort, bool direct) = switch (mode) {
      DirectTarget(:final deviceHost, :final port) => (deviceHost, port, true),
      LocalRouterTarget(:final host, :final port) => (host, port, false),
    };

    // Direct mode: the target NetId must be locally routed — surface a 0x0007
    // missing-route up front, before any I/O. Local-router mode delegates
    // routing to the endpoint itself, so no route-table entry is required.
    if (direct) {
      final route = _requireRoute(targetNetId); // throws missingRoute (0x0007)

      // Direct mode states the endpoint twice — addRoute(netId, host) and
      // DirectTarget(deviceHost) — and the route table is the authority the
      // 0x0007 gate claims. If the two disagree, refuse loudly (0x0506, the
      // same same-NetId-different-endpoint conflict code addRoute uses)
      // instead of silently sending every frame to a host the route table
      // never sanctioned (a typo'd host would otherwise misroute with no
      // diagnostic).
      if (route.host != host || route.port != endpointPort) {
        throw AdsRoutingException(
          _routerErrPortAlreadyInUse,
          targetNetId,
          'DirectTarget endpoint $host:$endpointPort conflicts with the '
          'route-table entry ${route.host}:${route.port} for target NetId '
          '${targetNetId.dotted}; fix the DirectTarget host/port, or '
          'removeRoute(...) + addRoute(...) the new endpoint first',
        );
      }

      // A direct connection with the all-zero source NetId is a
      // guaranteed-failing configuration: no PLC has a reverse route to
      // 0.0.0.0.0.0, and the ERR-02 enrichment would then name that nonsense
      // NetId as the one to add a reverse route for. Fail fast with the
      // actual remediation instead of shipping a known-misaddressed frame.
      // (The <ip>.1.1 auto-derive runs POST-dial, so it cannot fix the first
      // direct connect — a prior local-router connect can seed it, though.)
      if (_localAddr == _emptyNetId) {
        throw StateError(
          'direct mode requires a non-zero source NetId before the first '
          'connect: call setLocalAddress(...) first (or make a local-router '
          'connect first so the <ip>.1.1 auto-derive can seed it)',
        );
      }
    }

    // Validate everything fallible BEFORE taking a port slot: a non-u16
    // amsPort throws ArgumentError here, with nothing allocated yet.
    final target = AmsAddr(targetNetId, amsPort);

    // Allocate the local AMS source port. The 0 sentinel means all 128 slots
    // are taken — translate it into a typed 0x0508 rather than looping (T-4-01).
    final sourcePort = openPort();
    if (sourcePort == 0) {
      throw AdsException.fromCode(_routerErrNoMoreQueues);
    }

    final source = AmsAddr(_localAddr, sourcePort);

    // EVERYTHING between the slot allocation and the successful return runs
    // under one rollback guard: any throw — a user-injected factory, the dial
    // itself, or the post-dial derivation — releases the slot and closes the
    // connection (if one was built), so no failure path can leak a slot out
    // of the fixed 128-port range or strand an open socket.
    AmsConnection? connection;
    try {
      final transport = _transportFactory(host, endpointPort);

      // Direct mode wraps the connection so a request timeout — the canonical
      // symptom of a missing REVERSE route on the target — is rethrown as an
      // actionable 0x0745 naming the source NetId (ERR-02). Local-router mode
      // uses a plain connection so its timeouts/errors stay their own family.
      connection = direct
          ? _DirectTimeoutConnection(
              transport,
              source: source,
              target: target,
              defaultTimeout: _defaultTimeout,
              sourceNetId: source.netId,
            )
          : AmsConnection(
              transport,
              source: source,
              target: target,
              defaultTimeout: _defaultTimeout,
            );

      // Bound the dial: Socket.connect alone would block for the platform
      // TCP timeout (75 s+ on macOS, ~2 min on Linux) on an unreachable
      // host. On expiry the rollback below releases the slot and close()s
      // the connection, which tears the transport down (SocketTransport
      // additionally destroys a late-completing socket — see its guard).
      await connection.connect(host, endpointPort).timeout(_connectTimeout);

      // First-connection <ip>.1.1 derivation (C++ parity): once the socket is
      // up, learn the local IPv4 and, if no explicit local address was set,
      // derive the router's source NetId for SUBSEQUENT connects. A local
      // address that is not a dotted IPv4 (an IPv6 literal such as `::1` or
      // `fe80::…%if` on a dual-stack host) simply cannot derive — skip it
      // rather than poisoning a healthy connect with a framing exception.
      final localIp = transport.localAddress;
      if (_localAddr == _emptyNetId &&
          localIp != null &&
          _isDottedIpv4(localIp)) {
        _localAddr = AmsNetId.fromIpv4(localIp);
      }
    } on TimeoutException {
      closePort(sourcePort);
      final failed = connection;
      if (failed != null) {
        unawaited(failed.close());
      }
      // A dial timeout is an unreachable endpoint, not a missing reverse
      // route — surface it as the routing family with dial-specific
      // remediation (still code 0x0745/1861, the client sync-timeout).
      throw AdsRoutingException.dialTimeout(
        targetNetId,
        host,
        endpointPort,
        _connectTimeout,
      );
    } catch (_) {
      closePort(sourcePort);
      final failed = connection;
      if (failed != null) {
        // Fire-and-forget: close() is idempotent and tears the transport down
        // even when the dial never completed.
        unawaited(failed.close());
      }
      rethrow;
    }

    // Tie the source-port slot's lifetime to the connection's lifetime: when
    // the connection finishes (clean close, disconnect, or router close), the
    // slot returns to the pool — so long-running apps with reconnect cycles
    // never exhaust the fixed 128-slot range (threat T-4-01 is about
    // REPORTING exhaustion; this prevents the guaranteed leak causing it).
    // Also cache the live connection so getConnection/resolve serve THIS
    // dialed connection (one live entry per NetId; a newer connect replaces
    // the cache entry while the older connection stays owned until it closes).
    final live = connection; // promoted non-null: the guard always rethrows
    _owned.add(live);
    _connections[targetNetId] = live;
    unawaited(
      live.done.whenComplete(() => _release(live, targetNetId, sourcePort)),
    );

    return AdsClient(live, target: target, source: source);
  }

  /// Whether [address] is a plain dotted-decimal IPv4 literal (exactly four
  /// digit-only octets, each `0..255`). Anything else — IPv6 (`::1`,
  /// `fe80::…%en0`), hostnames, empty strings — is NOT derivable into an
  /// `<ip>.1.1` NetId and must be skipped, never fed to [AmsNetId.fromIpv4]
  /// (whose `MalformedFrameException` would poison a healthy connect).
  static bool _isDottedIpv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      for (final unit in part.codeUnits) {
        if (unit < 0x30 || unit > 0x39) return false; // digits only
      }
      if (int.parse(part) > 255) return false;
    }
    return true;
  }

  /// Post-teardown bookkeeping for one [connect]-created [connection]: frees
  /// its [sourcePort] slot and drops it from the owned/live registries (the
  /// live entry only if it is still THIS connection — a newer [connect] to the
  /// same [netId] must not be evicted by an older connection's teardown).
  void _release(AmsConnection connection, AmsNetId netId, int sourcePort) {
    closePort(sourcePort);
    _owned.remove(connection);
    if (identical(_connections[netId], connection)) {
      _connections.remove(netId);
    }
  }

  /// Closes every [connect]-created connection still alive and clears the
  /// route table (fan-out reuses the Phase-2 [AmsConnection] disconnect
  /// semantics). Each connection's `done` hook frees its source-port slot, so
  /// a closed router leaves the full `[30000, 30128)` range available again.
  Future<void> close() async {
    _routes.clear();
    final owned = List<AmsConnection>.of(_owned);
    await Future.wait(owned.map((c) => c.close()));
    // The done hooks above have already pruned these; clear defensively so a
    // close() racing an in-flight teardown cannot strand an entry.
    _owned.clear();
    _connections.clear();
  }
}

/// A [DirectTarget]-mode [AmsConnection] that enriches a request timeout into an
/// actionable ERR-02 error.
///
/// It overrides [request] to catch ONLY [AdsTimeoutException] — the canonical
/// symptom of the target lacking a reverse ADS route back to [sourceNetId] — and
/// rethrows [AdsRoutingException.directTimeout] (`0x0745`/1861), which stays
/// catchable as the [AdsException] family and names the source NetId plus the
/// remediation. Every other outcome (a device-error `errorCode` returned in the
/// record, a disconnect [AdsConnectionException], a synchronous framing throw)
/// passes through UNCHANGED so a real fault is never masked (threat T-4-02).
///
/// Awaiting `super.request` does not delay pipelining: the outbound frame is sent
/// during the synchronous portion of the base call, before the awaited future.
class _DirectTimeoutConnection extends AmsConnection {
  _DirectTimeoutConnection(
    super.transport, {
    required super.source,
    required super.target,
    required super.defaultTimeout,
    required this.sourceNetId,
  });

  /// The source AMS NetId this router stamped — named in the ERR-02 message.
  final AmsNetId sourceNetId;

  @override
  Future<({int errorCode, Uint8List payload})> request(
    int commandId,
    Uint8List payload, {
    Duration? timeout,
    void Function(int errorCode, Uint8List payload)? onResponseSync,
  }) async {
    try {
      return await super.request(
        commandId,
        payload,
        timeout: timeout,
        onResponseSync: onResponseSync,
      );
    } on AdsTimeoutException {
      throw AdsRoutingException.directTimeout(sourceNetId);
    }
  }
}
