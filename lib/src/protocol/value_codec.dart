/// Pure, stateless little-endian codec for the Phase-7 IEC 61131 scalar types
/// plus TwinCAT STRING/WSTRING conventions (SYM-03).
///
/// Every function here is a plain byte↔value map with no I/O and no state — the
/// client's typed convenience methods delegate to it. Isolating it keeps float
/// bit-exactness and STRING/WSTRING edge cases unit-testable without a socket.
///
/// All scalars are encoded/decoded **little-endian** (ADS/AMS wire order), using
/// `ByteData` with an explicit `Endian.little` on every accessor — never the
/// host default. This mirrors the established pattern in `commands.dart`.
///
/// ## Selection is caller-driven, not `dataTypeId`-driven
/// The codec is chosen by the caller's requested type / the symbol's declared
/// `size`, **not** by trusting the symbol's `dataTypeId`. `dataTypeId` is stored
/// on `AdsSymbolInfo` for a future (v2) typed-dispatch feature but MUST NOT gate
/// any function here.
///
/// ## Raw `Uint8List` escape hatch (SYM-04)
/// There is intentionally no "raw" codec. The escape hatch is simply **not
/// calling a codec at all**: the existing Read/Write paths already return and
/// accept raw `Uint8List` bytes, so a caller who wants untyped access just skips
/// this library. No forced typing is ever applied to raw buffers.
///
/// Pure: imports only `dart:typed_data` and `dart:convert` (Latin-1 for STRING).
/// This library is intentionally NOT re-exported by the package barrel — barrel
/// wiring belongs to Plan 05.
library;

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Signed-range guard (mirrors range_check.checkUint for signed wire fields).
// ---------------------------------------------------------------------------
//
// `ByteData.setInt8/16/32` silently truncate on out-of-range input — for a
// byte-exact codec that is the worst failure mode, so we fail fast instead.
int _checkInt(int value, int bits, String name) {
  final max = (1 << (bits - 1)) - 1;
  final min = -(1 << (bits - 1));
  if (value < min || value > max) {
    throw ArgumentError.value(value, name, 'must fit in i$bits ($min..$max)');
  }
  return value;
}

int _checkUint(int value, int bits, String name) {
  // Build the max from two sub-31-bit shifts (dart2js-safe; see range_check).
  final max = ((1 << (bits - 1)) - 1) * 2 + 1;
  if (value < 0 || value > max) {
    throw ArgumentError.value(value, name, 'must fit in u$bits (0..$max)');
  }
  return value;
}

// ---------------------------------------------------------------------------
// BOOL (1 byte)
// ---------------------------------------------------------------------------

/// Encodes a BOOL as a single byte (`1` for true, `0` for false).
Uint8List encodeBool(bool value) => Uint8List.fromList([value ? 1 : 0]);

/// Decodes a BOOL: any non-zero byte is `true`.
bool decodeBool(Uint8List buf) => buf[0] != 0;

// ---------------------------------------------------------------------------
// 1-byte integers: BYTE/USINT (u8), SINT (i8)
// ---------------------------------------------------------------------------

/// Encodes a BYTE/USINT (unsigned 8-bit).
Uint8List encodeByte(int value) =>
    Uint8List.fromList([_checkUint(value, 8, 'BYTE')]);

/// Decodes a BYTE/USINT (unsigned 8-bit).
int decodeByte(Uint8List buf) => buf[0];

/// Encodes a SINT (signed 8-bit).
Uint8List encodeSint(int value) {
  final buf = Uint8List(1);
  ByteData.sublistView(buf).setInt8(0, _checkInt(value, 8, 'SINT'));
  return buf;
}

/// Decodes a SINT (signed 8-bit).
int decodeSint(Uint8List buf) => ByteData.sublistView(buf).getInt8(0);

// ---------------------------------------------------------------------------
// 2-byte integers: WORD/UINT (u16), INT (i16)
// ---------------------------------------------------------------------------

/// Encodes a WORD/UINT (unsigned 16-bit, LE).
Uint8List encodeWord(int value) {
  final buf = Uint8List(2);
  ByteData.sublistView(buf)
      .setUint16(0, _checkUint(value, 16, 'WORD'), Endian.little);
  return buf;
}

/// Decodes a WORD/UINT (unsigned 16-bit, LE).
int decodeWord(Uint8List buf) =>
    ByteData.sublistView(buf).getUint16(0, Endian.little);

/// Encodes an INT (signed 16-bit, LE).
Uint8List encodeInt(int value) {
  final buf = Uint8List(2);
  ByteData.sublistView(buf)
      .setInt16(0, _checkInt(value, 16, 'INT'), Endian.little);
  return buf;
}

/// Decodes an INT (signed 16-bit, LE).
int decodeInt(Uint8List buf) =>
    ByteData.sublistView(buf).getInt16(0, Endian.little);

// ---------------------------------------------------------------------------
// 4-byte integers: DWORD/UDINT (u32), DINT (i32)
// ---------------------------------------------------------------------------

/// Encodes a DWORD/UDINT (unsigned 32-bit, LE).
Uint8List encodeDword(int value) {
  final buf = Uint8List(4);
  ByteData.sublistView(buf)
      .setUint32(0, _checkUint(value, 32, 'DWORD'), Endian.little);
  return buf;
}

/// Decodes a DWORD/UDINT (unsigned 32-bit, LE).
int decodeDword(Uint8List buf) =>
    ByteData.sublistView(buf).getUint32(0, Endian.little);

/// Encodes a DINT (signed 32-bit, LE).
Uint8List encodeDint(int value) {
  final buf = Uint8List(4);
  ByteData.sublistView(buf)
      .setInt32(0, _checkInt(value, 32, 'DINT'), Endian.little);
  return buf;
}

/// Decodes a DINT (signed 32-bit, LE).
int decodeDint(Uint8List buf) =>
    ByteData.sublistView(buf).getInt32(0, Endian.little);

// ---------------------------------------------------------------------------
// Floating point: REAL (f32), LREAL (f64)
// ---------------------------------------------------------------------------

/// Encodes a REAL (IEEE-754 binary32, LE). Note that a Dart `double` narrows to
/// f32 here, so decode reproduces the narrowed value bit-exactly, not the input.
Uint8List encodeReal(double value) {
  final buf = Uint8List(4);
  ByteData.sublistView(buf).setFloat32(0, value, Endian.little);
  return buf;
}

/// Decodes a REAL (IEEE-754 binary32, LE) into a Dart `double`.
double decodeReal(Uint8List buf) =>
    ByteData.sublistView(buf).getFloat32(0, Endian.little);

/// Encodes an LREAL (IEEE-754 binary64, LE).
Uint8List encodeLreal(double value) {
  final buf = Uint8List(8);
  ByteData.sublistView(buf).setFloat64(0, value, Endian.little);
  return buf;
}

/// Decodes an LREAL (IEEE-754 binary64, LE).
double decodeLreal(Uint8List buf) =>
    ByteData.sublistView(buf).getFloat64(0, Endian.little);

// ---------------------------------------------------------------------------
// STRING — fixed-length Latin-1, NUL-terminated/padded
// ---------------------------------------------------------------------------

/// Encodes [value] as a TwinCAT STRING into a fixed [size]-byte buffer.
///
/// The Latin-1 content bytes are written, then the remainder is NUL-padded. At
/// least one NUL terminator slot is required, so the content must be strictly
/// shorter than [size]; content that meets-or-exceeds [size] throws
/// [ArgumentError] rather than truncate into a fixed PLC buffer (T-7-03).
///
/// Use the symbol's declared `size` verbatim — TwinCAT `STRING(80)` reports a
/// `size` of 81 (80 chars + the NUL slot).
Uint8List encodeString(String value, int size) {
  final bytes = latin1.encode(value);
  if (bytes.length >= size) {
    throw ArgumentError.value(
      value,
      'value',
      'Latin-1 length ${bytes.length} leaves no room for the NUL terminator '
          'in a STRING buffer of size $size',
    );
  }
  final buf = Uint8List(size); // zero-filled → remainder is NUL-padded
  buf.setRange(0, bytes.length, bytes);
  return buf;
}

/// Decodes a TwinCAT STRING: Latin-1 bytes up to (but excluding) the first NUL.
String decodeString(Uint8List buf) {
  var end = buf.indexOf(0);
  if (end < 0) end = buf.length;
  return latin1.decode(buf.sublist(0, end));
}

// ---------------------------------------------------------------------------
// WSTRING — UTF-16LE, 0x0000-terminated/padded
// ---------------------------------------------------------------------------

/// Encodes [value] as a TwinCAT WSTRING into a fixed [sizeBytes]-byte buffer.
///
/// UTF-16 code units are written little-endian, followed by a `0x0000`
/// terminator, then NUL-padded to [sizeBytes]. The units plus the terminator
/// must fit; content that overflows throws [ArgumentError] (T-7-03).
Uint8List encodeWString(String value, int sizeBytes) {
  final units = value.codeUnits; // UTF-16 code units (BMP-safe)
  final requiredBytes = (units.length + 1) * 2; // +1 for 0x0000 terminator
  if (requiredBytes > sizeBytes) {
    throw ArgumentError.value(
      value,
      'value',
      'UTF-16LE length ${units.length * 2} bytes + terminator exceeds a '
          'WSTRING buffer of size $sizeBytes',
    );
  }
  final buf = Uint8List(sizeBytes); // zero-filled → terminator + padding
  final bd = ByteData.sublistView(buf);
  for (var i = 0; i < units.length; i++) {
    bd.setUint16(i * 2, units[i], Endian.little);
  }
  return buf;
}

/// Decodes a TwinCAT WSTRING: UTF-16LE code units up to the first `0x0000`.
String decodeWString(Uint8List buf) {
  // View the (even-length) byte buffer as u16 units. If the byte length is odd,
  // ignore the trailing partial byte — a valid WSTRING buffer is always even.
  final unitCount = buf.length ~/ 2;
  final bd = ByteData.sublistView(buf);
  final units = <int>[];
  for (var i = 0; i < unitCount; i++) {
    final unit = bd.getUint16(i * 2, Endian.little);
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}
