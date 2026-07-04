/// Pure, socket-free parser for the ADS SYM_UPLOAD (0xF00B) symbol blob.
///
/// A SYM_UPLOAD read returns a tightly packed sequence of variable-length
/// `AdsSymbolEntry` records. [parseSymbolBlob] turns that untrusted byte blob
/// into an ordered `List<AdsSymbolInfo>`, ported 1:1 from the vendored Beckhoff
/// reference (`SymbolEntry::Parse` + `FetchSymbolEntries` in
/// `third_party/ADS/AdsLib/SymbolAccess.cpp`).
///
/// ## Byte-exact record layout (little-endian, `#pragma pack(1)`)
///
/// Each entry starts with a fixed **30-byte** header — six u32 then three u16:
///
/// | Offset | Field         | Type | Notes                                  |
/// |--------|---------------|------|----------------------------------------|
/// | 0      | entryLength   | u32  | length of the COMPLETE entry (advance) |
/// | 4      | indexGroup    | u32  |                                        |
/// | 8      | indexOffset   | u32  |                                        |
/// | 12     | size          | u32  | byte size (0 == bit)                   |
/// | 16     | dataTypeId    | u32  | ADST_* id (stored for v2, not used)    |
/// | 20     | flags         | u32  | ADSSYMBOLFLAG_* — u32, NOT u16         |
/// | 24     | nameLength    | u16  | NUL terminator NOT counted             |
/// | 26     | typeLength    | u16  | NUL terminator NOT counted             |
/// | 28     | commentLength | u16  | NUL terminator NOT counted             |
///
/// Then, immediately after the header: `name` (nameLength bytes) + 1 NUL,
/// `typeName` (typeLength bytes) + 1 NUL, `comment` (commentLength bytes). Any
/// trailing NUL/padding is absorbed by `entryLength`. Strings decode Latin-1;
/// the length fields are authoritative (do NOT scan for NUL).
///
/// The cursor ALWAYS advances by `entryLength`, never by summed field sizes —
/// this keeps padded/extended entries forward-compatible (matches the C++
/// reference exactly).
///
/// ## Hostile-input hardening (T-7-02)
///
/// The blob comes from an untrusted PLC/mock: `entryLength` and the three length
/// fields are attacker-controllable. Every read is bounds-checked BEFORE any
/// slice with subtraction-safe guards (mirroring `sum_commands._requireBlock`),
/// so a malformed blob throws [MalformedFrameException] — never a `RangeError`,
/// never an over-read.
///
/// Pure: imports only `dart:typed_data`, `dart:convert` (`latin1`), and the
/// local pure [MalformedFrameException]. No `dart:async` / `dart:io`.
/// Intentionally NOT re-exported by the package barrel.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';

/// The fixed byte length of an `AdsSymbolEntry` header (six u32 + three u16).
const int _kSymbolHeaderLength = 30;

/// One parsed symbol from a SYM_UPLOAD blob.
///
/// A pure value type — carries only the public symbol metadata. `entryLength`
/// is a parse-advancement detail and is deliberately NOT stored here.
final class AdsSymbolInfo {
  /// Creates a symbol info record.
  const AdsSymbolInfo({
    required this.name,
    required this.typeName,
    required this.comment,
    required this.indexGroup,
    required this.indexOffset,
    required this.size,
    required this.dataTypeId,
    required this.flags,
  });

  /// The symbol's fully-qualified name (e.g. `MAIN.counter`).
  final String name;

  /// The symbol's IEC type name (e.g. `DINT`, `STRING(80)`).
  final String typeName;

  /// The symbol's comment (empty when none).
  final String comment;

  /// The symbol's ADS index group (u32).
  final int indexGroup;

  /// The symbol's ADS index offset (u32).
  final int indexOffset;

  /// The symbol's byte size (u32; `0` denotes a bit).
  final int size;

  /// The ADST_* data-type id (u32). Stored for v2 typed-decode; this phase's
  /// codec is driven by the caller's requested type, not by this value.
  final int dataTypeId;

  /// The ADSSYMBOLFLAG_* bitfield (u32).
  final int flags;

  @override
  String toString() =>
      'AdsSymbolInfo(name: $name, typeName: $typeName, '
      'indexGroup: 0x${indexGroup.toRadixString(16)}, '
      'indexOffset: 0x${indexOffset.toRadixString(16)}, size: $size, '
      'dataTypeId: $dataTypeId, flags: 0x${flags.toRadixString(16)})';
}

/// Parses a SYM_UPLOAD (0xF00B) [blob] of [nSymbols] entries into an ordered
/// `List<AdsSymbolInfo>`.
///
/// Advances the cursor by each entry's `entryLength` (never by summed field
/// sizes), so padded/extended entries parse the next entry correctly. Stops
/// after [nSymbols] records even if trailing bytes remain, and breaks early if
/// the cursor reaches the blob end before [nSymbols].
///
/// Throws [MalformedFrameException] (never `RangeError`, never over-reads) when
/// the blob is hostile: a truncated header, `entryLength < 30`,
/// `entryLength > remaining`, or a name/type/comment length that would read past
/// the entry.
List<AdsSymbolInfo> parseSymbolBlob(Uint8List blob, int nSymbols) {
  final symbols = <AdsSymbolInfo>[];
  var cursor = 0;
  for (var i = 0; i < nSymbols; i++) {
    // Early stop: nothing left to parse before we reached nSymbols.
    if (cursor >= blob.length) break;

    final remaining = blob.length - cursor;
    if (remaining < _kSymbolHeaderLength) {
      throw MalformedFrameException(
        'symbol entry $i header needs $_kSymbolHeaderLength bytes but only '
        '$remaining remain',
        length: _kSymbolHeaderLength,
        offset: cursor,
      );
    }

    final bd = ByteData.sublistView(blob, cursor);
    final entryLength = bd.getUint32(0, Endian.little);
    final indexGroup = bd.getUint32(4, Endian.little);
    final indexOffset = bd.getUint32(8, Endian.little);
    final size = bd.getUint32(12, Endian.little);
    final dataTypeId = bd.getUint32(16, Endian.little);
    final flags = bd.getUint32(20, Endian.little);
    final nameLength = bd.getUint16(24, Endian.little);
    final typeLength = bd.getUint16(26, Endian.little);
    final commentLength = bd.getUint16(28, Endian.little);

    // entryLength must at least cover the header and stay inside the blob.
    if (entryLength < _kSymbolHeaderLength || entryLength > remaining) {
      throw MalformedFrameException(
        'symbol entry $i declares entryLength $entryLength, outside the valid '
        'range [$_kSymbolHeaderLength, $remaining]',
        length: entryLength,
        offset: cursor,
      );
    }

    // Every string must lie within [cursor+30, cursor+entryLength). Guard each
    // read (subtraction-safe) BEFORE slicing so a hostile length throws instead
    // of over-reading.
    final entryEnd = cursor + entryLength;
    var p = cursor + _kSymbolHeaderLength;

    _requireField(entryEnd, p, nameLength, 'name', i);
    final name = latin1.decode(blob.sublist(p, p + nameLength));
    p += nameLength + 1; // +1 skips the NUL separator.

    _requireField(entryEnd, p, typeLength, 'typeName', i);
    final typeName = latin1.decode(blob.sublist(p, p + typeLength));
    p += typeLength + 1;

    _requireField(entryEnd, p, commentLength, 'comment', i);
    final comment = latin1.decode(blob.sublist(p, p + commentLength));

    symbols.add(AdsSymbolInfo(
      name: name,
      typeName: typeName,
      comment: comment,
      indexGroup: indexGroup,
      indexOffset: indexOffset,
      size: size,
      dataTypeId: dataTypeId,
      flags: flags,
    ));

    // Advance by entryLength — NEVER by summed field sizes.
    cursor = entryEnd;
  }
  return symbols;
}

/// Throws [MalformedFrameException] if the [len]-byte string starting at
/// absolute offset [p] would read past [entryEnd] — checked subtraction-safe
/// BEFORE any slice (mirrors `sum_commands._requireBlock`; threat T-7-02).
void _requireField(int entryEnd, int p, int len, String what, int item) {
  if (len < 0 || len > entryEnd - p) {
    throw MalformedFrameException(
      'symbol entry $item $what declares $len bytes but only '
      '${entryEnd - p} remain inside the entry',
      length: len,
      offset: p,
    );
  }
}
