/// Stable process exit codes for the `ads` CLI (the CLI-08 UX contract).
///
/// The codes mirror the library's typed exception families so a script can
/// branch on WHY a command failed without parsing stderr:
///   * `0` success;
///   * `1` an ADS/protocol error (a device or router `AdsException`);
///   * `2` a usage error (bad flags / bad values — `UsageException`,
///     `FormatException`, `ArgumentError`);
///   * `3` a connection/transport error (`AdsTimeoutException`,
///     `AdsConnectionException`, `SocketException`).
///
/// This file is pure: it imports nothing, so it is safe to reference from both
/// `bin/` and `lib/src/cli/`.
library;

/// Success — the command completed normally.
const int exitOk = 0;

/// An ADS/protocol error: a device or router `AdsException` (incl.
/// `AdsRoutingException`) surfaced from the PLC/mock or the router.
const int exitAdsError = 1;

/// A usage error: unknown/invalid flags or unparseable values.
const int exitUsage = 2;

/// A connection/transport error: the dial was refused, timed out, or the
/// socket dropped mid-request.
const int exitTransport = 3;
