/// The [AmsNetId] (6-byte AMS network address) and [AmsAddr] value types.
///
/// Pure: imports only `dart:typed_data` (plus the local, pure
/// [MalformedFrameException]). No `dart:async` / `dart:io`.
library;

import 'dart:typed_data';

import 'exceptions.dart';
import 'range_check.dart';

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
///
/// [AmsNetId] is [Comparable]: values order lexicographically over their six
/// bytes with `bytes[0]` most significant, mirroring the reference C++
/// `operator<` (`third_party/ADS/AdsLib/AdsDef.cpp`).
class AmsNetId implements Comparable<AmsNetId> {
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

  /// Derives the source AMS Net ID for an IPv4 address, as `<ip>.1.1`.
  ///
  /// Mirrors the reference C++ `AmsNetId(uint32_t ipv4Addr)`
  /// (`third_party/ADS/AdsLib/AdsDef.cpp`): the four IPv4 octets are written in
  /// dotted (**big-endian**) order — `bytes[0]` is the most-significant octet —
  /// followed by `1, 1`. So `192.168.0.100` yields `192.168.0.100.1.1`.
  ///
  /// Requires exactly four dot-separated decimal octets, each in `0..255`.
  /// Throws a [MalformedFrameException] on any malformed or out-of-range input
  /// (reusing the 6-byte constructor's validation), because a mis-derived
  /// source NetId silently mis-addresses every direct-mode frame.
  factory AmsNetId.fromIpv4(String dottedIpv4) {
    const ipv4OctetCount = 4;
    final parts = dottedIpv4.split('.');
    if (parts.length != ipv4OctetCount) {
      throw MalformedFrameException(
        'AmsNetId.fromIpv4 requires $ipv4OctetCount dot-separated octets, '
        'got ${parts.length} in "$dottedIpv4"',
      );
    }
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        throw MalformedFrameException(
          'AmsNetId.fromIpv4 octet "$part" in "$dottedIpv4" '
          'is not in range 0..255',
        );
      }
      octets.add(value);
    }
    // Octets in dotted (big-endian) order, then the conventional trailing 1, 1.
    return AmsNetId([...octets, 1, 1]);
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

  /// Lexicographic comparison over the six bytes, `bytes[0]` most significant.
  ///
  /// Returns a negative value, zero, or a positive value if `this` sorts
  /// before, equal to, or after [other]. Mirrors the reference C++ `operator<`
  /// on `AmsNetId` (`third_party/ADS/AdsLib/AdsDef.cpp`).
  @override
  int compareTo(AmsNetId other) {
    for (var i = 0; i < byteLength; i++) {
      final diff = _bytes[i] - other._bytes[i];
      if (diff != 0) return diff < 0 ? -1 : 1;
    }
    return 0;
  }

  /// True if `this` sorts strictly before [other] (see [compareTo]).
  bool operator <(AmsNetId other) => compareTo(other) < 0;

  /// True if `this` sorts before or equal to [other] (see [compareTo]).
  bool operator <=(AmsNetId other) => compareTo(other) <= 0;

  /// True if `this` sorts strictly after [other] (see [compareTo]).
  bool operator >(AmsNetId other) => compareTo(other) > 0;

  /// True if `this` sorts after or equal to [other] (see [compareTo]).
  bool operator >=(AmsNetId other) => compareTo(other) >= 0;

  @override
  String toString() => 'AmsNetId($dotted)';
}

/// An immutable AMS address: an [AmsNetId] paired with a u16 [port].
///
/// [AmsAddr] is [Comparable]: values order by [netId] first, then by [port],
/// mirroring the reference C++ `operator<` on `AmsAddr`
/// (`third_party/ADS/AdsLib/AdsDef.cpp`).
class AmsAddr implements Comparable<AmsAddr> {
  /// Creates an AMS address from a [netId] and a [port] (0..65535).
  ///
  /// Throws [ArgumentError] if [port] does not fit a u16 — a silently
  /// truncated port (e.g. 70000 -> 4464 on the wire) would address the wrong
  /// ADS service.
  AmsAddr(this.netId, this.port) {
    checkUint(port, 16, 'port');
  }

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

  /// Compares by [netId] first, then by [port].
  ///
  /// Returns a negative value, zero, or a positive value if `this` sorts
  /// before, equal to, or after [other]. Mirrors the reference C++ `operator<`
  /// on `AmsAddr` (`third_party/ADS/AdsLib/AdsDef.cpp`).
  @override
  int compareTo(AmsAddr other) {
    final byNetId = netId.compareTo(other.netId);
    return byNetId != 0 ? byNetId : port.compareTo(other.port);
  }

  /// True if `this` sorts strictly before [other] (see [compareTo]).
  bool operator <(AmsAddr other) => compareTo(other) < 0;

  @override
  String toString() => 'AmsAddr(${netId.dotted}:$port)';
}
