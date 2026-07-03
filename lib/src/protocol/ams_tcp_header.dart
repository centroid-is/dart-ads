/// The [AmsTcpHeader] — the 6-byte AMS/TCP frame wrapper.
///
/// Pure: imports only `dart:typed_data`. No `dart:async` / `dart:io`.
library;

import 'dart:typed_data';

/// The 6-byte AMS/TCP wrapper that prefixes every AMS frame on the wire.
///
/// Layout (little-endian):
///
/// | Offset | Size | Field       | Notes                                     |
/// |-------:|-----:|-------------|-------------------------------------------|
/// |    0   |  u16 | reserved    | always 0                                  |
/// |    2   |  u32 | [length]    | bytes following the wrapper               |
///
/// The [length] field counts everything *after* this 6-byte wrapper — i.e.
/// the 32-byte AMS header plus the ADS payload (`length = 32 + payload`). It
/// does **not** include the wrapper's own 6 bytes. Getting this off by 6 or 32
/// corrupts every downstream decode (RESEARCH Pitfall 1).
class AmsTcpHeader {
  /// The fixed on-wire width of the AMS/TCP wrapper.
  static const int byteLength = 6;

  /// Number of bytes that follow this wrapper (`32 + ADS payload length`).
  final int length;

  /// Creates an AMS/TCP wrapper carrying [length] trailing bytes.
  const AmsTcpHeader({required this.length});

  /// Encodes this wrapper to its 6 little-endian bytes.
  Uint8List encode() {
    final out = Uint8List(byteLength);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, 0, Endian.little); // reserved, always 0
    bd.setUint32(2, length, Endian.little);
    return out;
  }

  /// Decodes an [AmsTcpHeader] from [bd] starting at [offset].
  ///
  /// Reads the `length` u32 at `offset + 2`; the reserved u16 at `offset` is
  /// ignored on decode.
  factory AmsTcpHeader.decode(ByteData bd, [int offset = 0]) =>
      AmsTcpHeader(length: bd.getUint32(offset + 2, Endian.little));

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AmsTcpHeader && length == other.length;

  @override
  int get hashCode => length.hashCode;

  @override
  String toString() => 'AmsTcpHeader(length: $length)';
}
