/// The router-layer [AdsRoutingException] — an [AdsException] enriched with the
/// [AmsNetId] the routing failure concerns plus actionable remediation text.
///
/// Two distinct routing failures share this type, distinguished by their ADS
/// code (both already in the `AdsDef.h` error table):
///
///   * `0x0007` `GLOBALERR_MISSING_ROUTE` — the *local* missing-route case: the
///     target NetId is not in the router's route table. Detected up front,
///     before any socket I/O (mirrors C++ `AmsRouter::AdsRequest` returning
///     `GLOBALERR_MISSING_ROUTE` without touching the socket).
///   * `0x0745` `ADSERR_CLIENT_SYNCTIMEOUT` (1861 decimal) — the direct-mode
///     ERR-02 case: the target received the request but silently dropped the
///     reply because it has no *reverse* route back to our source NetId, so the
///     request times out. The composition is provided here for Plan 04 to use
///     when it catches the direct-mode timeout; this plan does NOT wire the
///     timeout catch.
///
/// [AdsRoutingException] extends [AdsException] so callers can `catch` it either
/// specifically OR as part of the broader ADS error family, and it still carries
/// the raw [code] for programmatic branching.
library;

import '../protocol/ads_error.dart';
import '../protocol/ams_net_id.dart';

/// An ADS routing failure carrying the offending [netId] and actionable
/// [remediation] guidance, surfaced as an [AdsException] subtype.
class AdsRoutingException extends AdsException {
  /// Creates a routing exception for [code] concerning [netId], with actionable
  /// [remediation] text.
  ///
  /// The [code] resolves to its canonical `AdsDef.h` constant name via
  /// [adsErrorName]; the [remediation] becomes the exception [message] so the
  /// operator-facing text is the actionable guidance, not just the terse table
  /// text. Prefer the [AdsRoutingException.missingRoute] /
  /// [AdsRoutingException.directTimeout] named constructors for the two known
  /// cases.
  AdsRoutingException(int code, this.netId, this.remediation)
      : super(code, adsErrorName(code), remediation);

  /// The local missing-route case (`0x0007` `GLOBALERR_MISSING_ROUTE`): [netId]
  /// is not in the route table. Thrown up front, before any I/O.
  factory AdsRoutingException.missingRoute(AmsNetId netId) =>
      AdsRoutingException(
        0x0007,
        netId,
        'no route to target NetId ${netId.dotted}; '
        'add one with addRoute(netId, host) before connecting',
      );

  /// The direct-mode ERR-02 case (`0x0745` `ADSERR_CLIENT_SYNCTIMEOUT`, 1861):
  /// the request timed out because the target has no reverse route back to our
  /// source [netId].
  ///
  /// Composition only — Plan 04 wires the direct-mode timeout catch that throws
  /// this; this plan does not.
  factory AdsRoutingException.directTimeout(AmsNetId netId) =>
      AdsRoutingException(
        0x0745,
        netId,
        'request timed out with no reply: the target has no reverse ADS route '
        'back to source NetId ${netId.dotted}. Add a reverse route on the '
        'target PLC (TwinCAT route config or `adstool addroute`) and check the '
        'firewall / AMS port 48898 — never surface this as a bare timeout',
      );

  /// The dial-timeout case (`0x0745` `ADSERR_CLIENT_SYNCTIMEOUT`, 1861): the
  /// TCP connect to [host]:[port] for target [netId] did not complete within
  /// [timeout] — the endpoint is unreachable (device powered off, wrong
  /// IP/host, or a firewall dropping AMS/TCP), NOT a missing reverse route
  /// (no request was ever sent). Thrown by `AmsRouter.connect` after rolling
  /// back the allocated source-port slot.
  factory AdsRoutingException.dialTimeout(
    AmsNetId netId,
    String host,
    int port,
    Duration timeout,
  ) =>
      AdsRoutingException(
        0x0745,
        netId,
        'TCP connect to $host:$port for target NetId ${netId.dotted} timed '
        'out after ${timeout.inMilliseconds} ms: the endpoint is unreachable. '
        'Check the host/IP, that the device is powered and on the network, '
        'and that no firewall is blocking AMS/TCP port $port',
      );

  /// The AMS Net ID this routing failure concerns (the unrouted target for the
  /// missing-route case, or the source NetId lacking a reverse route for the
  /// direct-mode timeout case).
  final AmsNetId netId;

  /// Actionable remediation guidance naming [netId] and how to fix the route.
  final String remediation;

  @override
  String toString() =>
      'AdsRoutingException: ADS error 0x${code.toRadixString(16).padLeft(4, '0')} '
      '($name) for NetId ${netId.dotted}: $remediation';
}
