/// The runtime transport-mode strategy: a [sealed] [TransportTarget] with the
/// two ways an [AmsRouter] reaches an ADS peer.
///
/// The mode chosen at `router.connect(...)` time only varies the CONNECTION
/// ENDPOINT (host/port) and which side owns onward routing — the six ADS command
/// bodies never change (ROUTE-01). A [DirectTarget] dials the device peer itself
/// (this package's embedded router stamps the source NetId and the target PLC
/// must have a REVERSE route back); a [LocalRouterTarget] dials a local TwinCAT
/// router on `127.0.0.1:48898`, which performs the onward routing for us.
///
/// The `port`/`host` fields are configurable so integration tests can point a
/// mode at the C++ mock's ephemeral port (the mock stands in for a local router
/// unchanged).
///
/// This file is pure: it imports nothing (no `dart:async` / `dart:io`).
library;

/// How the [AmsRouter] reaches a target ADS peer, selectable at runtime.
///
/// Two concrete modes exist — [DirectTarget] and [LocalRouterTarget]. As a
/// `sealed` type, an exhaustive `switch` over the two subtypes is checked by the
/// analyzer, so adding a future mode is a compile-time prompt at every dispatch.
sealed class TransportTarget {
  /// `const` so the modes are compile-time constructible.
  const TransportTarget();
}

/// Connect DIRECTLY to a remote ADS peer at [deviceHost]:[port].
///
/// The embedded Dart router stamps the source AMS NetId onto every frame, so the
/// **target PLC must have a reverse ADS route** back to that source NetId — added
/// out-of-band (TwinCAT route config or `adstool addroute`). Without it the PLC
/// silently drops the response and the request times out; the router surfaces
/// that as an actionable ADS `0x0745`/1861 error naming the source NetId rather
/// than a bare timeout (ERR-02). Programmatic reverse-route creation over UDP
/// `:48899` is a v2 concern (ROUTE-04).
final class DirectTarget extends TransportTarget {
  /// Dials [deviceHost] on [port] (the AMS/TCP default `48898`).
  const DirectTarget(this.deviceHost, {this.port = 48898});

  /// The remote ADS peer's host (IP or resolvable name).
  final String deviceHost;

  /// The remote AMS/TCP port (default `48898`).
  final int port;
}

/// Delegate onward routing to a local TwinCAT router at [host]:[port].
///
/// The local router owns the route table and stamps addressing, so no reverse
/// route on the target is required and the router returns its own routing errors
/// (e.g. `0x0007` missing-route) unchanged — the direct-mode `0x0745` enrichment
/// is intentionally NOT applied in this mode.
final class LocalRouterTarget extends TransportTarget {
  /// Dials the local router at [host]:[port] (defaults to `127.0.0.1:48898`).
  const LocalRouterTarget({this.host = '127.0.0.1', this.port = 48898});

  /// The local router's host — configurable so tests point at the mock's port.
  final String host;

  /// The local router's AMS/TCP port (default `48898`).
  final int port;
}
