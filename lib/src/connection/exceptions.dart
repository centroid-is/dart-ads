/// Transport-error-family exceptions for the ADS connection layer.
///
/// These are deliberately DISTINCT from `MalformedFrameException` (the
/// wire-level framing failure in `protocol/exceptions.dart`) and from future
/// ADS *protocol* errors (a well-formed response carrying a non-zero result
/// code, mapped in Phase 3). Keeping the three families separate lets callers
/// `catch` each independently — e.g. retry on a timeout, tear down on a
/// disconnect, and reject on a malformed frame.
///
/// This file imports nothing from `dart:io`; it stays pure so it can be reused
/// by the in-memory `FakeTransport` test path as well as the real socket path.
library;

/// Thrown when a request does not receive its correlated response before the
/// per-request (or connection-default) timeout expires.
///
/// This is the transport-error family — separate from a device-level ADS error.
/// It carries the [invokeId] and [commandId] of the request that expired so
/// callers and logs can identify exactly which in-flight operation timed out.
/// A timeout removes the pending entry; a late response arriving afterwards is
/// counted as dropped rather than delivered.
class AdsTimeoutException implements Exception {
  /// Creates a timeout exception for the request identified by [invokeId] and
  /// [commandId].
  const AdsTimeoutException(this.invokeId, this.commandId);

  /// The AMS invoke-ID of the request that timed out.
  final int invokeId;

  /// The ADS command-ID of the request that timed out.
  final int commandId;

  @override
  String toString() => 'AdsTimeoutException: request $invokeId '
      '(cmd 0x${commandId.toRadixString(16).padLeft(4, '0')}) timed out';
}

/// Thrown when the connection is broken or unavailable.
///
/// Used in two situations: as the error every pending request is completed with
/// during disconnect fan-out (and the error notification streams are closed
/// with), and when `request()` is called on a connection that is not currently
/// connected. The optional [cause] names the underlying disconnect reason (for
/// example the socket error or the `AdsConnectionException` produced by an
/// `onDone`), or is `null` when the connection was simply never open.
class AdsConnectionException implements Exception {
  /// Creates a connection exception with a human-readable [message] and,
  /// optionally, the underlying [cause] that triggered the disconnect.
  const AdsConnectionException(this.message, {this.cause});

  /// Human-readable description of why the connection is unavailable.
  final String message;

  /// The underlying cause of the disconnect, when one exists. May be `null`
  /// (for example, when the connection was never established).
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (cause: $cause)';
    return 'AdsConnectionException: $message$suffix';
  }
}
