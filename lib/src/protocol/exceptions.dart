/// Exception types for the pure-Dart ADS protocol codec.
///
/// This file is pure: it imports nothing (no `dart:async` / `dart:io`) so the
/// whole `protocol/` subtree stays unit-testable in isolation.
library;

/// Thrown when raw bytes cannot be parsed as a well-formed AMS/TCP or AMS
/// frame — a wire-level / structural failure.
///
/// This is deliberately distinct from an ADS *protocol* error (a well-formed
/// response carrying a non-zero `errorCode` / `result`). A
/// [MalformedFrameException] means "these bytes are not a valid frame"
/// (truncated, over the max-frame guard, a bad length prefix, or a NetId of the
/// wrong width), whereas an ADS protocol error means "a valid frame reported a
/// device-level failure". Callers can therefore `catch` framing failures
/// separately from device errors.
class MalformedFrameException implements Exception {
  /// Creates a malformed-frame exception with a human-readable [message] and,
  /// optionally, the offending [length] and byte [offset] that triggered it.
  const MalformedFrameException(this.message, {this.length, this.offset});

  /// Human-readable description of what made the frame malformed.
  final String message;

  /// The offending length value, when the failure relates to a length field
  /// (e.g. a length prefix exceeding the max-frame guard). May be `null`.
  final int? length;

  /// The byte offset at which parsing failed, when applicable. May be `null`.
  final int? offset;

  @override
  String toString() {
    final details = <String>[
      if (length != null) 'length: $length',
      if (offset != null) 'offset: $offset',
    ];
    final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
    return 'MalformedFrameException: $message$suffix';
  }
}
