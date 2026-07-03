/// Per-command request encoders and response decoders for the six core ADS
/// commands: ReadDeviceInfo, Read, Write, ReadState, WriteControl, ReadWrite.
///
/// Each request encoder composes the ADS payload for its command, wraps it in a
/// 32-byte [AmsHeader], and prepends the 6-byte [AmsTcpHeader] wrapper whose
/// `length` field is `32 + payload.length` (the off-by-6/32 pitfall — RESEARCH
/// Pattern 2). Every multi-byte field is little-endian on the wire.
///
/// Response decoders take the ADS response payload — the bytes that follow the
/// 32-byte AMS header — and return a typed [AdsResponse]. Variable-length
/// responses ([ReadResponse], [ReadWriteResponse]) validate the declared
/// `readLength` against the bytes actually present before slicing, throwing
/// [MalformedFrameException] on an overrun rather than reading past the buffer
/// (threat T-1-03).
///
/// Pure: imports only `dart:typed_data` plus the local, pure protocol types.
/// No `dart:async` / `dart:io`.
library;

import 'dart:typed_data';

import 'ams_header.dart';
import 'ams_net_id.dart';
import 'ams_tcp_header.dart';
import 'constants.dart';
import 'exceptions.dart';

// ---------------------------------------------------------------------------
// Response value types
// ---------------------------------------------------------------------------

/// Base type for every decoded ADS response.
///
/// The [result] u32 is the ADS-level status word carried at the front of every
/// response payload (`0` == success). It is distinct from the AMS header's own
/// `errorCode` field. Subtypes add the per-command typed fields.
sealed class AdsResponse {
  /// Creates a response carrying its ADS [result] status word.
  const AdsResponse(this.result);

  /// The ADS result / status word (u32, `0` == success).
  final int result;
}

/// A decoded ReadDeviceInfo (0x01) response: version, revision, build, name.
final class ReadDeviceInfoResponse extends AdsResponse {
  /// Creates a ReadDeviceInfo response from its typed fields.
  const ReadDeviceInfoResponse({
    required int result,
    required this.version,
    required this.revision,
    required this.build,
    required this.name,
  }) : super(result);

  /// Major version (u8).
  final int version;

  /// Revision (u8).
  final int revision;

  /// Build number (u16).
  final int build;

  /// Device name (the NUL-terminated ASCII contents of the 16-byte name field).
  final String name;

  @override
  String toString() => 'ReadDeviceInfoResponse(result: $result, '
      'v$version.$revision build $build, name: "$name")';
}

/// A decoded Read (0x02) response: the [data] bytes returned by the device.
final class ReadResponse extends AdsResponse {
  /// Creates a Read response from its [result] and returned [data].
  ReadResponse({required int result, required this.data}) : super(result);

  /// The bytes returned by the device (`readLength` bytes long).
  final Uint8List data;

  /// The declared `readLength` — equal to `data.length`.
  int get readLength => data.length;

  @override
  String toString() => 'ReadResponse(result: $result, readLength: $readLength)';
}

/// A decoded Write (0x03) response: just the [result] status word.
final class WriteResponse extends AdsResponse {
  /// Creates a Write response from its [result].
  const WriteResponse({required int result}) : super(result);

  @override
  String toString() => 'WriteResponse(result: $result)';
}

/// A decoded ReadState (0x04) response: the ADS and device run states.
final class ReadStateResponse extends AdsResponse {
  /// Creates a ReadState response from its typed fields.
  const ReadStateResponse({
    required int result,
    required this.adsState,
    required this.deviceState,
  }) : super(result);

  /// The ADS run state (u16, e.g. `5` == RUN — see [AdsState]).
  final int adsState;

  /// The device-specific state (u16).
  final int deviceState;

  @override
  String toString() => 'ReadStateResponse(result: $result, '
      'adsState: $adsState, deviceState: $deviceState)';
}

/// A decoded WriteControl (0x05) response: just the [result] status word.
final class WriteControlResponse extends AdsResponse {
  /// Creates a WriteControl response from its [result].
  const WriteControlResponse({required int result}) : super(result);

  @override
  String toString() => 'WriteControlResponse(result: $result)';
}

/// A decoded ReadWrite (0x09) response: the [data] bytes returned by the device.
final class ReadWriteResponse extends AdsResponse {
  /// Creates a ReadWrite response from its [result] and returned [data].
  ReadWriteResponse({required int result, required this.data}) : super(result);

  /// The bytes returned by the device (`readLength` bytes long).
  final Uint8List data;

  /// The declared `readLength` — equal to `data.length`.
  int get readLength => data.length;

  @override
  String toString() =>
      'ReadWriteResponse(result: $result, readLength: $readLength)';
}

// ---------------------------------------------------------------------------
// Request encoders
// ---------------------------------------------------------------------------

/// Encodes a ReadDeviceInfo (0x01) request as a full on-wire frame.
///
/// The command carries no ADS payload, so the frame is the 38-byte anchor:
/// 6-byte AMS/TCP wrapper (`length` == 32) + 32-byte AMS header.
Uint8List encodeReadDeviceInfoRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
}) =>
    _frame(
      target: target,
      source: source,
      invokeId: invokeId,
      commandId: AdsCommandId.readDeviceInfo,
      payload: _empty,
    );

/// Encodes a Read (0x02) request: read [length] bytes at
/// [indexGroup]/[indexOffset].
Uint8List encodeReadRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
  required int indexGroup,
  required int indexOffset,
  required int length,
}) {
  final payload = Uint8List(12);
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, indexGroup, Endian.little);
  bd.setUint32(4, indexOffset, Endian.little);
  bd.setUint32(8, length, Endian.little);
  return _frame(
    target: target,
    source: source,
    invokeId: invokeId,
    commandId: AdsCommandId.read,
    payload: payload,
  );
}

/// Encodes a Write (0x03) request: write [data] at [indexGroup]/[indexOffset].
Uint8List encodeWriteRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
  required int indexGroup,
  required int indexOffset,
  required Uint8List data,
}) {
  final payload = Uint8List(12 + data.length);
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, indexGroup, Endian.little);
  bd.setUint32(4, indexOffset, Endian.little);
  bd.setUint32(8, data.length, Endian.little);
  payload.setRange(12, 12 + data.length, data);
  return _frame(
    target: target,
    source: source,
    invokeId: invokeId,
    commandId: AdsCommandId.write,
    payload: payload,
  );
}

/// Encodes a ReadState (0x04) request. The command carries no ADS payload.
Uint8List encodeReadStateRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
}) =>
    _frame(
      target: target,
      source: source,
      invokeId: invokeId,
      commandId: AdsCommandId.readState,
      payload: _empty,
    );

/// Encodes a WriteControl (0x05) request: set [adsState]/[deviceState], with an
/// optional trailing [data] blob (empty by default).
Uint8List encodeWriteControlRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
  required int adsState,
  required int deviceState,
  Uint8List? data,
}) {
  final body = data ?? _empty;
  final payload = Uint8List(8 + body.length);
  final bd = ByteData.sublistView(payload);
  bd.setUint16(0, adsState, Endian.little);
  bd.setUint16(2, deviceState, Endian.little);
  bd.setUint32(4, body.length, Endian.little);
  payload.setRange(8, 8 + body.length, body);
  return _frame(
    target: target,
    source: source,
    invokeId: invokeId,
    commandId: AdsCommandId.writeControl,
    payload: payload,
  );
}

/// Encodes a ReadWrite (0x09) request: write [writeData] and read back
/// [readLength] bytes at [indexGroup]/[indexOffset].
Uint8List encodeReadWriteRequest({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
  required int indexGroup,
  required int indexOffset,
  required int readLength,
  required Uint8List writeData,
}) {
  final payload = Uint8List(16 + writeData.length);
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, indexGroup, Endian.little);
  bd.setUint32(4, indexOffset, Endian.little);
  bd.setUint32(8, readLength, Endian.little);
  bd.setUint32(12, writeData.length, Endian.little);
  payload.setRange(16, 16 + writeData.length, writeData);
  return _frame(
    target: target,
    source: source,
    invokeId: invokeId,
    commandId: AdsCommandId.readWrite,
    payload: payload,
  );
}

// ---------------------------------------------------------------------------
// Response decoders
// ---------------------------------------------------------------------------

/// Decodes a ReadDeviceInfo (0x01) response payload (24 bytes).
ReadDeviceInfoResponse decodeReadDeviceInfoResponse(Uint8List payload) {
  _require(payload, 24, 'ReadDeviceInfo response');
  final bd = ByteData.sublistView(payload);
  return ReadDeviceInfoResponse(
    result: bd.getUint32(0, Endian.little),
    version: payload[4],
    revision: payload[5],
    build: bd.getUint16(6, Endian.little),
    name: _cString(payload, 8, 16),
  );
}

/// Decodes a Read (0x02) response payload: `result u32 + readLength u32 + data`.
///
/// Validates `readLength` against the bytes present before slicing (T-1-03).
ReadResponse decodeReadResponse(Uint8List payload) {
  final (result, data) = _decodeResultAndData(payload, 'Read response');
  return ReadResponse(result: result, data: data);
}

/// Decodes a Write (0x03) response payload (4 bytes): `result u32`.
WriteResponse decodeWriteResponse(Uint8List payload) {
  _require(payload, 4, 'Write response');
  final bd = ByteData.sublistView(payload);
  return WriteResponse(result: bd.getUint32(0, Endian.little));
}

/// Decodes a ReadState (0x04) response payload (8 bytes).
ReadStateResponse decodeReadStateResponse(Uint8List payload) {
  _require(payload, 8, 'ReadState response');
  final bd = ByteData.sublistView(payload);
  return ReadStateResponse(
    result: bd.getUint32(0, Endian.little),
    adsState: bd.getUint16(4, Endian.little),
    deviceState: bd.getUint16(6, Endian.little),
  );
}

/// Decodes a WriteControl (0x05) response payload (4 bytes): `result u32`.
WriteControlResponse decodeWriteControlResponse(Uint8List payload) {
  _require(payload, 4, 'WriteControl response');
  final bd = ByteData.sublistView(payload);
  return WriteControlResponse(result: bd.getUint32(0, Endian.little));
}

/// Decodes a ReadWrite (0x09) response payload: `result u32 + readLength u32 +
/// data`.
///
/// Validates `readLength` against the bytes present before slicing (T-1-03).
ReadWriteResponse decodeReadWriteResponse(Uint8List payload) {
  final (result, data) = _decodeResultAndData(payload, 'ReadWrite response');
  return ReadWriteResponse(result: result, data: data);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// A shared empty payload (zero-length ADS body).
final Uint8List _empty = Uint8List(0);

/// Composes a full on-wire frame: `AmsTcpHeader(32 + payload) ++ AmsHeader ++
/// payload`, with `AmsHeader.dataLength == payload.length` and request state
/// flags.
Uint8List _frame({
  required AmsAddr target,
  required AmsAddr source,
  required int invokeId,
  required int commandId,
  required Uint8List payload,
}) {
  final ams = AmsHeader(
    targetNetId: target.netId,
    targetPort: target.port,
    sourceNetId: source.netId,
    sourcePort: source.port,
    commandId: commandId,
    stateFlags: AmsStateFlags.request,
    dataLength: payload.length,
    errorCode: 0,
    invokeId: invokeId,
  );
  final tcp = AmsTcpHeader(length: AmsHeader.byteLength + payload.length);

  final out = Uint8List(
    AmsTcpHeader.byteLength + AmsHeader.byteLength + payload.length,
  );
  out.setRange(0, AmsTcpHeader.byteLength, tcp.encode());
  out.setRange(
    AmsTcpHeader.byteLength,
    AmsTcpHeader.byteLength + AmsHeader.byteLength,
    ams.encode(),
  );
  out.setRange(
    AmsTcpHeader.byteLength + AmsHeader.byteLength,
    out.length,
    payload,
  );
  return out;
}

/// Decodes the `result u32 + readLength u32 + data[readLength]` shape shared by
/// the Read and ReadWrite responses, validating `readLength` before slicing.
(int, Uint8List) _decodeResultAndData(Uint8List payload, String what) {
  _require(payload, 8, what);
  final bd = ByteData.sublistView(payload);
  final result = bd.getUint32(0, Endian.little);
  final readLength = bd.getUint32(4, Endian.little);
  final available = payload.length - 8;
  if (readLength > available) {
    throw MalformedFrameException(
      '$what declares readLength $readLength but only $available data bytes '
      'are present',
      length: readLength,
      offset: 8,
    );
  }
  // Defensive copy so the returned data does not alias the source buffer.
  final data = Uint8List.fromList(payload.sublist(8, 8 + readLength));
  return (result, data);
}

/// Throws [MalformedFrameException] if [payload] is shorter than [min] bytes.
void _require(Uint8List payload, int min, String what) {
  if (payload.length < min) {
    throw MalformedFrameException(
      '$what requires at least $min bytes, got ${payload.length}',
      length: payload.length,
    );
  }
}

/// Reads a NUL-terminated ASCII string from [bytes] spanning `[start, start +
/// maxLength)`. Stops at the first NUL; trailing padding is dropped.
String _cString(Uint8List bytes, int start, int maxLength) {
  var end = start;
  final limit = start + maxLength;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  return String.fromCharCodes(bytes, start, end);
}
