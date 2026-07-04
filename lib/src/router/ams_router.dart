/// The [AmsRouter] registry — the unit-testable "route algebra" ported from the
/// vendored Beckhoff/ADS C++ `AmsRouter` (`third_party/ADS/AdsLib/standalone/
/// AmsRouter.cpp`, `Router.h`).
///
/// It owns three things:
///   * a fixed 128-slot local-AMS-port allocator based at 30000
///     ([openPort] / [closePort]);
///   * the route table mapping a target [AmsNetId] → an owned [AmsConnection]
///     ([addRoute] / [removeRoute] / [getConnection] / [resolve]);
///   * the mutable source/local [AmsNetId] ([setLocalAddress] /
///     [getLocalAddress]) with lazy `<ip>.1.1` auto-derivation on the first
///     connection.
///
/// The connection is built through an injected [TransportFactory] so the whole
/// route/port/localAddr algebra is exercised by a `FakeTransport` with no live
/// sockets. Plan 04 adds [AmsRouter.connect]: it turns a target NetId + a
/// [TransportTarget] mode into a ready [AdsClient] (source→target addressed),
/// and — in [DirectTarget] mode ONLY — enriches a request timeout into an
/// actionable ADS `0x0745`/1861 error naming the source NetId (ERR-02) instead
/// of a bare timeout.
///
/// Divergence from C++ (documented for the parity tests): the C++ router shares
/// one refcounted `AmsConnection` across multiple NetIds pointing at the same
/// host; this Dart port keeps ONE connection per target NetId
/// (`Map<AmsNetId, AmsConnection>`). Every parity assertion (return code +
/// non-null connection) holds either way — the tests never assert two NetIds
/// share the same connection object.
library;

import 'dart:async';
import 'dart:typed_data';

import '../client/ads_client.dart';
import '../connection/ams_connection.dart';
import '../connection/exceptions.dart';
import '../protocol/ads_error.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/constants.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'routing_exception.dart';
import 'transport_target.dart';

/// Builds the [AdsTransport] a new route connects over, given its [host] and
/// [port]. Defaults to a `dart:io` [SocketTransport]; unit tests inject a
/// `FakeTransport`-returning factory so route logic runs without sockets.
typedef TransportFactory = AdsTransport Function(String host, int port);

/// A single route-table entry: the owned [connection] plus the [transport] it
/// wraps and the [host]/[port] it targets (recorded so the "same NetId,
/// different host ⇒ PORTALREADYINUSE" and "same host ⇒ idempotent" rules are
/// decided BEFORE any second connection is built).
class _Route {
  _Route(this.connection, this.transport, this.host, this.port);

  final AmsConnection connection;
  final AdsTransport transport;
  final String host;
  final int port;
}

/// The AMS routing registry: local-port allocator, route table, and mutable
/// source address, behind an injectable connection/transport factory.
class AmsRouter {
  /// Creates a router that builds route connections via [transportFactory]
  /// (default: a real [SocketTransport] per route), applying [defaultTimeout] to
  /// each owned [AmsConnection].
  AmsRouter({
    TransportFactory? transportFactory,
    Duration defaultTimeout = const Duration(seconds: 5),
  })  : _transportFactory =
            transportFactory ?? ((host, port) => SocketTransport()),
        _defaultTimeout = defaultTimeout;

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

  /// Fixed 128-slot local-port allocator. `_ports[i] == 0` means slot `i` is
  /// free; otherwise it holds the assigned port value `portBase + i`.
  final List<int> _ports = List<int>.filled(numPortsMax, 0);

  /// The route table: target NetId → its owned route entry.
  final Map<AmsNetId, _Route> _routes = <AmsNetId, _Route>{};

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

  /// Maps target [netId] to a connection reached via [host]:[port].
  ///
  /// Decision tree (C++ `AddRoute` parity, one-per-NetId variant):
  ///   * new [netId] → build a connection via the factory, map it, return `0`
  ///     (and, if no local address is set yet, auto-derive `<ip>.1.1` from the
  ///     transport's `localAddress`);
  ///   * existing [netId] to a DIFFERENT [host]/[port] → return
  ///     `ROUTERERR_PORTALREADYINUSE` (`0x0506`), leaving the old route intact
  ///     ([removeRoute] it first);
  ///   * existing [netId] to the SAME [host]/[port] → idempotent `0`, no second
  ///     connection built;
  ///   * a new [netId] whose [host] is already used by another NetId → `0` with
  ///     its own connection (this port does not share connections across
  ///     NetIds — see the class divergence note).
  int addRoute(AmsNetId netId, String host, {int port = 48898}) {
    final existing = _routes[netId];
    if (existing != null) {
      if (existing.host == host && existing.port == port) {
        return 0; // Idempotent: same NetId, same endpoint.
      }
      return _routerErrPortAlreadyInUse; // Same NetId, different endpoint.
    }

    final transport = _transportFactory(host, port);

    // First-connection source-NetId derivation: only when no explicit local
    // address has been set AND the transport exposes a local IPv4.
    final localIp = transport.localAddress;
    if (_localAddr == _emptyNetId && localIp != null) {
      _localAddr = AmsNetId.fromIpv4(localIp);
    }

    final connection = AmsConnection(
      transport,
      source: AmsAddr(_localAddr, 0),
      target: AmsAddr(netId, AmsPort.plcTc3),
      defaultTimeout: _defaultTimeout,
    );
    _routes[netId] = _Route(connection, transport, host, port);
    return 0;
  }

  /// Removes the route for [netId], closing its owned connection.
  ///
  /// The mapping is dropped synchronously (so [getConnection]/[resolve] see it
  /// gone immediately); the connection teardown is fire-and-forget. Routes for
  /// other NetIds are unaffected. A no-op if [netId] is not routed.
  void removeRoute(AmsNetId netId) {
    final route = _routes.remove(netId);
    if (route != null) {
      unawaited(route.connection.close());
    }
  }

  /// The owned [AmsConnection] for target [netId], or `null` if not routed
  /// (C++ `GetConnection` parity — a plain map lookup, never throws).
  AmsConnection? getConnection(AmsNetId netId) => _routes[netId]?.connection;

  /// Resolves target [netId] to its [AmsConnection], throwing
  /// [AdsRoutingException] (`0x0007` `GLOBALERR_MISSING_ROUTE`) naming [netId]
  /// when it is not in the route table — BEFORE any socket I/O (C++
  /// `AmsRouter::AdsRequest` parity).
  AmsConnection resolve(AmsNetId netId) {
    final route = _routes[netId];
    if (route == null) {
      throw AdsRoutingException.missingRoute(netId);
    }
    return route.connection;
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
  ///     BEFORE any socket I/O — never a connect-then-timeout probe. A request
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
  /// is thrown (T-4-01). The returned client is addressed
  /// `source = AmsAddr(localAddr, allocatedPort)` →
  /// `target = AmsAddr(targetNetId, amsPort)`.
  ///
  /// The first successful connection lazily auto-derives the router's source
  /// NetId as `<ip>.1.1` from the socket's local IPv4 (C++ parity) when no
  /// explicit [setLocalAddress] was made — so a deterministic source NetId on
  /// the very first direct connection is best obtained by calling
  /// [setLocalAddress] up front.
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
      resolve(targetNetId); // throws AdsRoutingException.missingRoute (0x0007)
    }

    // Allocate the local AMS source port. The 0 sentinel means all 128 slots
    // are taken — translate it into a typed 0x0508 rather than looping (T-4-01).
    final sourcePort = openPort();
    if (sourcePort == 0) {
      throw AdsException.fromCode(_routerErrNoMoreQueues);
    }

    final transport = _transportFactory(host, endpointPort);
    final source = AmsAddr(_localAddr, sourcePort);
    final target = AmsAddr(targetNetId, amsPort);

    // Direct mode wraps the connection so a request timeout — the canonical
    // symptom of a missing REVERSE route on the target — is rethrown as an
    // actionable 0x0745 naming the source NetId (ERR-02). Local-router mode uses
    // a plain connection so its timeouts/errors stay their own family.
    final AmsConnection connection = direct
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

    try {
      await connection.connect(host, endpointPort);
    } catch (_) {
      // Release the just-allocated source port so a failed dial never leaks a
      // slot out of the fixed 128-port range.
      closePort(sourcePort);
      rethrow;
    }

    // First-connection <ip>.1.1 derivation (C++ parity): once the socket is up,
    // learn the local IPv4 and, if no explicit local address was set, derive the
    // router's source NetId for SUBSEQUENT connects.
    final localIp = transport.localAddress;
    if (_localAddr == _emptyNetId && localIp != null) {
      _localAddr = AmsNetId.fromIpv4(localIp);
    }

    return AdsClient(connection, target: target, source: source);
  }

  /// Closes every owned connection and clears the route table (fan-out reuses
  /// the Phase-2 [AmsConnection] disconnect semantics).
  Future<void> close() async {
    final routes = List<_Route>.of(_routes.values);
    _routes.clear();
    await Future.wait(routes.map((r) => r.connection.close()));
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
  }) async {
    try {
      return await super.request(commandId, payload, timeout: timeout);
    } on AdsTimeoutException {
      throw AdsRoutingException.directTimeout(sourceNetId);
    }
  }
}
