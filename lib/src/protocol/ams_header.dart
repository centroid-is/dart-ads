/// The [AmsHeader] — the 32-byte AMS header codec.
///
/// Pure: imports only `dart:typed_data` (plus the local, pure [AmsNetId]).
/// No `dart:async` / `dart:io`.
library;

import 'dart:typed_data';

import 'ams_net_id.dart';

/// The 32-byte AMS header that follows the [AmsTcpHeader] wrapper on the wire.
///
/// Byte layout (all scalars little-endian; offsets verified from
/// `Beckhoff/ADS AdsLib/AmsHeader.h` `AoEHeader`):
///
/// | Offset | Size    | Field           |
/// |-------:|---------|-----------------|
/// |    0   | 6 bytes | [targetNetId]   |
/// |    6   | u16     | [targetPort]    |
/// |    8   | 6 bytes | [sourceNetId]   |
/// |   14   | u16     | [sourcePort]    |
/// |   16   | u16     | [commandId]     |
/// |   18   | u16     | [stateFlags]    |
/// |   20   | u32     | [dataLength]    |
/// |   24   | u32     | [errorCode]     |
/// |   28   | u32     | [invokeId]      |
class AmsHeader {
  /// The fixed on-wire width of the AMS header.
  static const int byteLength = 32;

  /// Destination AMS Net ID (offset 0, 6 bytes).
  final AmsNetId targetNetId;

  /// Destination AMS port (offset 6, u16).
  final int targetPort;

  /// Source AMS Net ID (offset 8, 6 bytes).
  final AmsNetId sourceNetId;

  /// Source AMS port (offset 14, u16).
  final int sourcePort;

  /// ADS service / command ID (offset 16, u16). See `AdsCommandId`.
  final int commandId;

  /// State flags (offset 18, u16): `0x0004` request, `0x0005` response.
  final int stateFlags;

  /// Length of the ADS payload that follows this header (offset 20, u32).
  final int dataLength;

  /// ADS error code (offset 24, u32).
  final int errorCode;

  /// Invoke ID correlating a response to its request (offset 28, u32).
  final int invokeId;

  /// Creates an immutable AMS header from its fully-typed fields.
  const AmsHeader({
    required this.targetNetId,
    required this.targetPort,
    required this.sourceNetId,
    required this.sourcePort,
    required this.commandId,
    required this.stateFlags,
    required this.dataLength,
    required this.errorCode,
    required this.invokeId,
  });

  /// Encodes this header to its 32 little-endian bytes.
  Uint8List encode() {
    final out = Uint8List(byteLength);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 6, targetNetId.bytes);
    bd.setUint16(6, targetPort, Endian.little);
    out.setRange(8, 14, sourceNetId.bytes);
    bd.setUint16(14, sourcePort, Endian.little);
    bd.setUint16(16, commandId, Endian.little);
    bd.setUint16(18, stateFlags, Endian.little);
    bd.setUint32(20, dataLength, Endian.little);
    bd.setUint32(24, errorCode, Endian.little);
    bd.setUint32(28, invokeId, Endian.little);
    return out;
  }

  /// Decodes an [AmsHeader] from [bd] starting at [offset].
  ///
  /// The caller must guarantee at least [byteLength] bytes are available from
  /// [offset]; decode reads fixed offsets and never indexes past its declared
  /// width (threat T-1-03).
  factory AmsHeader.decode(ByteData bd, [int offset = 0]) {
    final base = bd.offsetInBytes + offset;
    return AmsHeader(
      targetNetId: AmsNetId(bd.buffer.asUint8List(base, AmsNetId.byteLength)),
      targetPort: bd.getUint16(offset + 6, Endian.little),
      sourceNetId:
          AmsNetId(bd.buffer.asUint8List(base + 8, AmsNetId.byteLength)),
      sourcePort: bd.getUint16(offset + 14, Endian.little),
      commandId: bd.getUint16(offset + 16, Endian.little),
      stateFlags: bd.getUint16(offset + 18, Endian.little),
      dataLength: bd.getUint32(offset + 20, Endian.little),
      errorCode: bd.getUint32(offset + 24, Endian.little),
      invokeId: bd.getUint32(offset + 28, Endian.little),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AmsHeader &&
          targetNetId == other.targetNetId &&
          targetPort == other.targetPort &&
          sourceNetId == other.sourceNetId &&
          sourcePort == other.sourcePort &&
          commandId == other.commandId &&
          stateFlags == other.stateFlags &&
          dataLength == other.dataLength &&
          errorCode == other.errorCode &&
          invokeId == other.invokeId;

  @override
  int get hashCode => Object.hash(
        targetNetId,
        targetPort,
        sourceNetId,
        sourcePort,
        commandId,
        stateFlags,
        dataLength,
        errorCode,
        invokeId,
      );

  @override
  String toString() => 'AmsHeader('
      'target: ${targetNetId.dotted}:$targetPort, '
      'source: ${sourceNetId.dotted}:$sourcePort, '
      'cmd: 0x${commandId.toRadixString(16)}, '
      'flags: 0x${stateFlags.toRadixString(16)}, '
      'dataLength: $dataLength, '
      'errorCode: $errorCode, '
      'invokeId: $invokeId)';
}
