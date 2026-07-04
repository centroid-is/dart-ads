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
/// sockets. The `connect()` / transport-mode / ERR-02 wiring lands in Plan 04 —
/// this file deliberately stops at the registry.
///
/// Divergence from C++ (documented for the parity tests): the C++ router shares
/// one refcounted `AmsConnection` across multiple NetIds pointing at the same
/// host; this Dart port keeps ONE connection per target NetId
/// (`Map<AmsNetId, AmsConnection>`). Every parity assertion (return code +
/// non-null connection) holds either way — the tests never assert two NetIds
/// share the same connection object.
library;

import 'dart:async';

import '../connection/ams_connection.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/constants.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'routing_exception.dart';

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

  /// Closes every owned connection and clears the route table (fan-out reuses
  /// the Phase-2 [AmsConnection] disconnect semantics).
  Future<void> close() async {
    final routes = List<_Route>.of(_routes.values);
    _routes.clear();
    await Future.wait(routes.map((r) => r.connection.close()));
  }
}
