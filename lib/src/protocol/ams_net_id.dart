/// The [AmsNetId] (6-byte AMS network address) and [AmsAddr] value types.
///
/// Pure: imports only `dart:typed_data` (plus the local, pure
/// [MalformedFrameException]). No `dart:async` / `dart:io`.
library;

import 'dart:typed_data';

import 'exceptions.dart';

/// An immutable 6-byte AMS Net ID (e.g. `192.168.0.1.1.1`).
///
/// An AMS Net ID is six bytes, conventionally written as six dot-separated
/// decimal octets. It is *not* an IPv4 address (it has six octets, not four),
/// though the first four commonly mirror the host's IP.
///
/// The instance owns an unmodifiable defensive copy of its bytes, so callers
/// cannot mutate an [AmsNetId] after construction, and mutating the source list
/// afterwards does not affect the stored value. Two [AmsNetId]s with identical
/// bytes compare equal and hash equal.
class AmsNetId {
  /// The fixed on-wire width of an AMS Net ID.
  static const int byteLength = 6;

  final Uint8List _bytes;

  AmsNetId._(this._bytes);

  /// Creates an [AmsNetId] from exactly [byteLength] bytes.
  ///
  /// Takes a defensive, unmodifiable copy of [source]. Throws a
  /// [MalformedFrameException] if [source] is not exactly 6 bytes long.
  factory AmsNetId(List<int> source) {
    if (source.length != byteLength) {
      throw MalformedFrameException(
        'AmsNetId requires exactly $byteLength bytes, got ${source.length}',
        length: source.length,
      );
    }
    final copy = Uint8List.fromList(source);
    return AmsNetId._(copy.asUnmodifiableView());
  }

  /// Parses a dotted AMS Net ID string such as `"192.168.0.1.1.1"`.
  ///
  /// Requires exactly six dot-separated decimal octets, each in `0..255`.
  /// Throws a [MalformedFrameException] on any malformed input.
  factory AmsNetId.parse(String dotted) {
    final parts = dotted.split('.');
    if (parts.length != byteLength) {
      throw MalformedFrameException(
        'AmsNetId string requires $byteLength dot-separated octets, '
        'got ${parts.length} in "$dotted"',
      );
    }
    final out = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      final value = int.tryParse(parts[i]);
      if (value == null || value < 0 || value > 255) {
        throw MalformedFrameException(
          'AmsNetId octet "${parts[i]}" in "$dotted" is not in range 0..255',
        );
      }
      out[i] = value;
    }
    return AmsNetId._(out.asUnmodifiableView());
  }

  /// The six bytes of this Net ID, as an unmodifiable view.
  Uint8List get bytes => _bytes;

  /// The conventional dotted-decimal rendering, e.g. `"192.168.0.1.1.1"`.
  String get dotted => _bytes.join('.');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AmsNetId) return false;
    for (var i = 0; i < byteLength; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_bytes);

  @override
  String toString() => 'AmsNetId($dotted)';
}

/// An immutable AMS address: an [AmsNetId] paired with a u16 [port].
class AmsAddr {
  /// Creates an AMS address from a [netId] and a [port] (0..65535).
  const AmsAddr(this.netId, this.port);

  /// The AMS Net ID of this address.
  final AmsNetId netId;

  /// The AMS port (u16), e.g. `851` for a TwinCAT 3 PLC runtime.
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AmsAddr && netId == other.netId && port == other.port;

  @override
  int get hashCode => Object.hash(netId, port);

  @override
  String toString() => 'AmsAddr(${netId.dotted}:$port)';
}
