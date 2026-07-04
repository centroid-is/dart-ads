/// The CLI's primary untrusted-input parsing seam (threat T-8-01).
///
/// Every read/write/action verb funnels operator-supplied `--type`/value and
/// `--raw` hex strings through here. The contract is: **hostile or garbage
/// input surfaces as a [FormatException] (mapped to exit code 2 upstream), never
/// an isolate crash, a `RangeError` leaking from a fixed-size codec, or a silent
/// truncation into a PLC buffer.**
///
/// All scalar byte<->value conversion is delegated to
/// `lib/src/protocol/value_codec.dart` (single source of truth). This file only
/// parses strings, guards integer ranges *before* encoding, and guards buffer
/// lengths *before* decoding. It is intentionally pure (`dart:typed_data` only,
/// no `dart:io`) so it is unit-fast.
library;

import 'dart:typed_data';

import '../protocol/value_codec.dart' as codec;

// ---------------------------------------------------------------------------
// Hex parsing / formatting
// ---------------------------------------------------------------------------

/// Parses a hex string into bytes.
///
/// Accepts an optional `0x`/`0X` prefix and tolerates internal whitespace. The
/// remaining nibble count must be even. An empty string (or a bare prefix)
/// yields an empty buffer. Malformed input (non-hex characters, odd length)
/// throws [FormatException] — never a crash.
Uint8List parseHex(String input) {
  var s = input.trim();
  if (s.length >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s = s.substring(2);
  }
  // Strip all internal whitespace.
  final compact = s.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return Uint8List(0);
  // Strict digit check: int.tryParse(radix: 16) accepts signed tokens like
  // '-1', which would silently truncate through Uint8List (CR-01).
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
    throw FormatException('Hex string contains non-hex characters', input);
  }
  if (compact.length.isOdd) {
    throw FormatException('Hex string has an odd nibble count', input);
  }
  final out = Uint8List(compact.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byteStr = compact.substring(i * 2, i * 2 + 2);
    final value = int.tryParse(byteStr, radix: 16);
    if (value == null) {
      throw FormatException('Invalid hex byte "$byteStr"', input, i * 2);
    }
    out[i] = value;
  }
  return out;
}

/// Formats bytes as a lower-case, `0x`-prefixed hex string. Round-trips with
/// [parseHex] (empty buffer -> `"0x"`).
String formatHex(Uint8List bytes) {
  final sb = StringBuffer('0x');
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// Type-name <-> codec bridge
// ---------------------------------------------------------------------------

/// Fixed wire size (bytes) required to decode each scalar type. Variable-length
/// types (STRING/WSTRING) are absent — their decoders tolerate any buffer.
const Map<String, int> _fixedSizes = {
  'bool': 1,
  'byte': 1,
  'sint': 1,
  'word': 2,
  'int': 2,
  'dword': 4,
  'dint': 4,
  'real': 4,
  'lreal': 8,
};

/// Parses a decimal integer, throwing [FormatException] (not the codec's
/// [ArgumentError]) when it is out of the signed/unsigned wire range.
int _parseIntInRange(String raw, int min, int max, String typeName) {
  final value = int.tryParse(raw.trim());
  if (value == null) {
    throw FormatException('$typeName value is not an integer', raw);
  }
  if (value < min || value > max) {
    throw FormatException(
        '$typeName value $value is out of range ($min..$max)');
  }
  return value;
}

double _parseDouble(String raw, String typeName) {
  final value = double.tryParse(raw.trim());
  if (value == null) {
    throw FormatException('$typeName value is not a number', raw);
  }
  return value;
}

bool _parseBool(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'true':
    case '1':
      return true;
    case 'false':
    case '0':
      return false;
    default:
      throw FormatException('BOOL value must be true/false/1/0', raw);
  }
}

/// Encodes an operator-supplied [raw] string as [typeName] into wire bytes.
///
/// [typeName] is matched case-insensitively. STRING/WSTRING require [size]
/// (the symbol's declared byte size); omitting it throws [FormatException].
/// Every hostile input path (non-numeric, out-of-range, unknown type, overflow)
/// throws [FormatException] rather than crash or truncate (T-8-01).
Uint8List encodeTypedValue(String typeName, String raw, {int? size}) {
  final t = typeName.trim().toLowerCase();
  try {
    switch (t) {
      case 'bool':
        return codec.encodeBool(_parseBool(raw));
      case 'byte':
        return codec.encodeByte(_parseIntInRange(raw, 0, 255, 'BYTE'));
      case 'sint':
        return codec.encodeSint(_parseIntInRange(raw, -128, 127, 'SINT'));
      case 'word':
        return codec.encodeWord(_parseIntInRange(raw, 0, 65535, 'WORD'));
      case 'int':
        return codec.encodeInt(_parseIntInRange(raw, -32768, 32767, 'INT'));
      case 'dword':
        return codec.encodeDword(_parseIntInRange(raw, 0, 4294967295, 'DWORD'));
      case 'dint':
        return codec
            .encodeDint(_parseIntInRange(raw, -2147483648, 2147483647, 'DINT'));
      case 'real':
        return codec.encodeReal(_parseDouble(raw, 'REAL'));
      case 'lreal':
        return codec.encodeLreal(_parseDouble(raw, 'LREAL'));
      case 'string':
        if (size == null) {
          throw const FormatException('STRING requires a --size');
        }
        return codec.encodeString(raw, size);
      case 'wstring':
        if (size == null) {
          throw const FormatException('WSTRING requires a --size');
        }
        return codec.encodeWString(raw, size);
      default:
        throw FormatException('Unknown type "$typeName"');
    }
  } on ArgumentError catch (e) {
    // Codec range/overflow guards throw ArgumentError; normalize to the CLI's
    // FormatException contract so nothing but FormatException escapes.
    throw FormatException('Invalid $typeName value: ${e.message}', raw);
  }
}

/// Decodes wire [bytes] as [typeName] into a human-readable display string.
///
/// The buffer length is guarded *before* the codec runs, so a buffer shorter
/// than a fixed-size type throws [FormatException] instead of letting a
/// `RangeError` escape (T-8-01). [typeName] is matched case-insensitively;
/// unknown types throw [FormatException].
String decodeTypedValue(String typeName, Uint8List bytes) {
  final t = typeName.trim().toLowerCase();
  final needed = _fixedSizes[t];
  if (needed != null && bytes.length < needed) {
    throw FormatException(
        '$typeName needs $needed bytes but got ${bytes.length}');
  }
  try {
    switch (t) {
      case 'bool':
        return codec.decodeBool(bytes) ? 'true' : 'false';
      case 'byte':
        return codec.decodeByte(bytes).toString();
      case 'sint':
        return codec.decodeSint(bytes).toString();
      case 'word':
        return codec.decodeWord(bytes).toString();
      case 'int':
        return codec.decodeInt(bytes).toString();
      case 'dword':
        return codec.decodeDword(bytes).toString();
      case 'dint':
        return codec.decodeDint(bytes).toString();
      case 'real':
        return codec.decodeReal(bytes).toString();
      case 'lreal':
        return codec.decodeLreal(bytes).toString();
      case 'string':
        return codec.decodeString(bytes);
      case 'wstring':
        return codec.decodeWString(bytes);
      default:
        throw FormatException('Unknown type "$typeName"');
    }
  } on RangeError catch (e) {
    // Defense in depth: any residual RangeError becomes a FormatException.
    throw FormatException('Malformed $typeName buffer: ${e.message}');
  }
}
