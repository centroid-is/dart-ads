/// Shared connection bootstrap for the `ads` CLI verbs.
///
/// [connectFromGlobals] turns the runner's global connection flags
/// (`--host/--port/--target/--ams-port/--source/--timeout/--mode`) into a live
/// [AdsSession] — an [AmsRouter] + a connected [AdsClient] + an idempotent
/// [AdsSession.close]. Every connection verb calls it so the dial, source-NetId
/// policy, and teardown are defined once.
///
/// Flag-value parsing (`--port/--ams-port/--timeout` ints, `--target/--source`
/// NetIds) raises [UsageException]/[FormatException] here so a bad value maps
/// to exit code `2` (never a crash or a bogus dial) — threat T-8-02a.
///
/// `dart:io` is not imported directly; the socket work lives inside the router,
/// and a refused/timed-out dial surfaces as the library's transport family for
/// the caller's `guarded(...)` to map to exit code `3`.
library;

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

/// A live CLI session: the [router] that owns the dialed connection, the
/// ready-to-use [client], and an idempotent [close] safe to call from both a
/// SIGINT handler and the normal-exit path.
class AdsSession {
  /// Wraps the [router] and its connected [client].
  AdsSession(this.router, this.client);

  /// The router that dialed (and owns the teardown of) [client]'s connection.
  final AmsRouter router;

  /// The connected ADS client the verb issues commands through.
  final AdsClient client;

  bool _closed = false;

  /// Tears down every connection + notification handle the session opened.
  ///
  /// Idempotent: the first call closes the router; later calls are no-ops, so
  /// closing once on SIGINT and once on normal exit is safe.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await router.close();
  }
}

/// Bootstraps an [AdsSession] from the runner's global [globals].
///
/// Steps: parse the numeric flags (bad values → exit 2); require `--target` and
/// `--host` (a connection verb cannot run without them); build an [AmsRouter]
/// whose request + dial timeouts are `--timeout` ms; set the source NetId
/// (explicit `--source`, else a derived `<ip>.1.1` in direct mode with a dotted
/// IPv4 host, else a usage error naming `--source`); then dial via the chosen
/// [mode]. On any failure between building the router and a successful connect,
/// the router is closed before rethrowing so no slot/socket leaks.
Future<AdsSession> connectFromGlobals(ArgResults globals) async {
  final host = (globals['host'] as String?)?.trim();
  final targetStr = (globals['target'] as String?)?.trim();
  final sourceStr = (globals['source'] as String?)?.trim();
  final mode = globals['mode'] as String; // constrained to direct|router.

  final port = _parseInt(globals, 'port');
  final amsPort = _parseInt(globals, 'ams-port');
  final timeoutMs = _parseInt(globals, 'timeout');

  if (targetStr == null || targetStr.isEmpty) {
    throw UsageException(
      'missing required --target <AmsNetId> for a connection verb',
      '',
    );
  }
  if (host == null || host.isEmpty) {
    throw UsageException(
      'missing required --host <ip|name> for a connection verb',
      '',
    );
  }

  // Bad NetId text surfaces as a FormatException -> exit 2.
  final target = AmsNetId.parse(targetStr);
  final timeout = Duration(milliseconds: timeoutMs);
  final router = AmsRouter(defaultTimeout: timeout, connectTimeout: timeout);

  // Source NetId policy (see AmsRouter: direct mode needs a non-zero source
  // BEFORE the first connect, so it cannot rely on the post-dial auto-derive).
  if (sourceStr != null && sourceStr.isNotEmpty) {
    router.setLocalAddress(AmsNetId.parse(sourceStr));
  } else if (mode == 'direct') {
    if (_isDottedIpv4(host)) {
      router.setLocalAddress(AmsNetId.fromIpv4(host));
    } else {
      throw UsageException(
        'direct mode needs a source NetId: pass --source <AmsNetId> '
            '(host "$host" is not a dotted IPv4 to derive <ip>.1.1 from)',
        '',
      );
    }
  }

  final AdsClient client;
  try {
    if (mode == 'direct') {
      router.addRoute(target, host, port: port);
      client = await router.connect(
        target,
        amsPort,
        mode: DirectTarget(host, port: port),
      );
    } else {
      client = await router.connect(
        target,
        amsPort,
        mode: LocalRouterTarget(host: host, port: port),
      );
    }
  } catch (_) {
    // A refused/timed-out dial (or any bootstrap throw) must not leak the
    // router's open connection/port slot — tear it down, then rethrow so the
    // caller's guarded() maps it (transport -> 3, etc.).
    await router.close();
    rethrow;
  }

  return AdsSession(router, client);
}

/// Parses global int option [name] from [globals], raising a [FormatException]
/// (→ exit 2) with an operator-facing message on a non-integer value.
int _parseInt(ArgResults globals, String name) {
  final raw = (globals[name] as String).trim();
  final value = int.tryParse(raw);
  if (value == null) {
    throw FormatException('--$name must be an integer, got "$raw"');
  }
  return value;
}

/// Whether [address] is a plain dotted-decimal IPv4 literal (four `0..255`
/// digit-only octets) — the only shape [AmsNetId.fromIpv4] can derive a
/// `<ip>.1.1` source NetId from. Mirrors the router's private guard so a
/// non-IPv4 host (IPv6, a hostname) takes the explicit-`--source` path instead
/// of feeding `fromIpv4` a value it would reject.
bool _isDottedIpv4(String address) {
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
