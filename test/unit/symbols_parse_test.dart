@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:dart_ads/src/protocol/symbols.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// In-Dart byte fixtures for SYM_UPLOAD (0xF00B) blobs.
//
// No dedicated C++ AdsLibTest symbol scenario exists (RESEARCH: our coverage
// exceeds the C++ suite here), so these fixtures are hand-built byte-exact to
// the AdsSymbolEntry layout pinned in AdsDef.h — a 30-byte little-endian header
// (six u32 + three u16) followed by name+NUL, type+NUL, comment+NUL, then any
// padding absorbed by entryLength.
// ---------------------------------------------------------------------------

/// Builds one byte-exact `AdsSymbolEntry`.
///
/// [padding] appends that many trailing zero bytes and is folded into
/// `entryLength`, exercising the "advance by entryLength, skip padding" path.
/// The `*LengthOverride` params deliberately corrupt a declared string length
/// (without changing the emitted bytes) to build hostile fixtures.
/// [entryLengthOverride] forces a specific `entryLength` field for the
/// too-short / past-remaining hostile cases.
Uint8List _entry({
  required String name,
  required String typeName,
  required String comment,
  required int indexGroup,
  required int indexOffset,
  required int size,
  required int dataTypeId,
  required int flags,
  int padding = 0,
  int? nameLengthOverride,
  int? entryLengthOverride,
}) {
  final nameBytes = latin1.encode(name);
  final typeBytes = latin1.encode(typeName);
  final commentBytes = latin1.encode(comment);

  final stringsLen =
      nameBytes.length + 1 + typeBytes.length + 1 + commentBytes.length + 1;
  final totalLen = 30 + stringsLen + padding;
  final entryLength = entryLengthOverride ?? totalLen;

  final out = Uint8List(totalLen);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, entryLength, Endian.little);
  bd.setUint32(4, indexGroup, Endian.little);
  bd.setUint32(8, indexOffset, Endian.little);
  bd.setUint32(12, size, Endian.little);
  bd.setUint32(16, dataTypeId, Endian.little);
  bd.setUint32(20, flags, Endian.little);
  bd.setUint16(24, nameLengthOverride ?? nameBytes.length, Endian.little);
  bd.setUint16(26, typeBytes.length, Endian.little);
  bd.setUint16(28, commentBytes.length, Endian.little);

  var p = 30;
  out.setRange(p, p + nameBytes.length, nameBytes);
  p += nameBytes.length + 1; // leave the NUL separator (already zero).
  out.setRange(p, p + typeBytes.length, typeBytes);
  p += typeBytes.length + 1;
  out.setRange(p, p + commentBytes.length, commentBytes);
  // Trailing NUL + padding are already zero-filled.
  return out;
}

/// Concatenates entry byte chunks into a single blob.
Uint8List _concat(List<Uint8List> chunks) {
  final total = chunks.fold<int>(0, (a, c) => a + c.length);
  final out = Uint8List(total);
  var o = 0;
  for (final c in chunks) {
    out.setRange(o, o + c.length, c);
    o += c.length;
  }
  return out;
}

// Two canonical fixture symbols (a DINT counter + a STRING(80) text).
final Uint8List _counterEntry = _entry(
  name: 'MAIN.counter',
  typeName: 'DINT',
  comment: 'cycle counter',
  indexGroup: 0x4020,
  indexOffset: 0x0,
  size: 4,
  dataTypeId: 3, // ADST_INT32
  flags: 0,
);
final Uint8List _textEntry = _entry(
  name: 'MAIN.text',
  typeName: 'STRING(80)',
  comment: '',
  indexGroup: 0x4020,
  indexOffset: 0x100,
  size: 81,
  dataTypeId: 30, // ADST_STRING
  flags: 0,
);

void main() {
  group('parseSymbolBlob (SYM-02) — clean multi-symbol blob', () {
    test('parses a 2-symbol blob into exact ordered fields', () {
      final blob = _concat([_counterEntry, _textEntry]);
      final symbols = parseSymbolBlob(blob, 2);

      expect(symbols, hasLength(2));

      final counter = symbols[0];
      expect(counter.name, equals('MAIN.counter'));
      expect(counter.typeName, equals('DINT'));
      expect(counter.comment, equals('cycle counter'));
      expect(counter.indexGroup, equals(0x4020));
      expect(counter.indexOffset, equals(0x0));
      expect(counter.size, equals(4));
      expect(counter.dataTypeId, equals(3));
      expect(counter.flags, equals(0));

      final text = symbols[1];
      expect(text.name, equals('MAIN.text'));
      expect(text.typeName, equals('STRING(80)'));
      expect(text.comment, isEmpty);
      expect(text.indexGroup, equals(0x4020));
      expect(text.indexOffset, equals(0x100));
      expect(text.size, equals(81));
      expect(text.dataTypeId, equals(30));
      expect(text.flags, equals(0));
    });

    test('stops after nSymbols even when trailing bytes remain', () {
      // Blob physically holds two entries; ask for one → parse exactly one and
      // ignore the trailing entry bytes.
      final blob = _concat([_counterEntry, _textEntry]);
      final symbols = parseSymbolBlob(blob, 1);
      expect(symbols, hasLength(1));
      expect(symbols.single.name, equals('MAIN.counter'));
    });

    test('breaks early when the cursor reaches blob end before nSymbols', () {
      // Only one entry present but caller over-counts → return what exists,
      // no over-read, no throw (cursor reached the blob end cleanly).
      final blob = _concat([_counterEntry]);
      final symbols = parseSymbolBlob(blob, 5);
      expect(symbols, hasLength(1));
      expect(symbols.single.name, equals('MAIN.counter'));
    });
  });

  group('parseSymbolBlob (SYM-02) — padded entry advances by entryLength', () {
    test('a padded first entry still parses the second entry correctly', () {
      // Inflate the first entry with trailing padding folded into entryLength.
      // If the parser advanced by summed field sizes instead of entryLength,
      // the second entry would be read from the wrong offset and corrupt.
      final paddedCounter = _entry(
        name: 'MAIN.counter',
        typeName: 'DINT',
        comment: 'cycle counter',
        indexGroup: 0x4020,
        indexOffset: 0x0,
        size: 4,
        dataTypeId: 3,
        flags: 0,
        padding: 7, // deliberate, non-4-aligned padding.
      );
      final blob = _concat([paddedCounter, _textEntry]);
      final symbols = parseSymbolBlob(blob, 2);

      expect(symbols, hasLength(2));
      expect(symbols[0].name, equals('MAIN.counter'));
      expect(symbols[0].comment, equals('cycle counter'));
      // The proof: the SECOND entry parses byte-exactly despite the padding.
      expect(symbols[1].name, equals('MAIN.text'));
      expect(symbols[1].typeName, equals('STRING(80)'));
      expect(symbols[1].indexOffset, equals(0x100));
      expect(symbols[1].size, equals(81));
    });
  });

  group('parseSymbolBlob (SYM-02) — hostile blobs throw MalformedFrame', () {
    test('entryLength = 0 throws (below the 30-byte header)', () {
      final blob = _entry(
        name: 'X',
        typeName: 'BOOL',
        comment: '',
        indexGroup: 1,
        indexOffset: 2,
        size: 1,
        dataTypeId: 33,
        flags: 0,
        entryLengthOverride: 0,
      );
      expect(
        () => parseSymbolBlob(blob, 1),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('entryLength = 29 throws (one byte short of the header)', () {
      final blob = _entry(
        name: 'X',
        typeName: 'BOOL',
        comment: '',
        indexGroup: 1,
        indexOffset: 2,
        size: 1,
        dataTypeId: 33,
        flags: 0,
        entryLengthOverride: 29,
      );
      expect(
        () => parseSymbolBlob(blob, 1),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('entryLength one byte past remaining throws', () {
      final base = _entry(
        name: 'MAIN.counter',
        typeName: 'DINT',
        comment: 'cycle counter',
        indexGroup: 0x4020,
        indexOffset: 0x0,
        size: 4,
        dataTypeId: 3,
        flags: 0,
      );
      // Override entryLength to one byte beyond the blob's actual length.
      final hostile = _entry(
        name: 'MAIN.counter',
        typeName: 'DINT',
        comment: 'cycle counter',
        indexGroup: 0x4020,
        indexOffset: 0x0,
        size: 4,
        dataTypeId: 3,
        flags: 0,
        entryLengthOverride: base.length + 1,
      );
      expect(
        () => parseSymbolBlob(hostile, 1),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('nameLength overrunning the entry throws (never RangeError)', () {
      final blob = _entry(
        name: 'AB',
        typeName: 'DINT',
        comment: '',
        indexGroup: 1,
        indexOffset: 2,
        size: 4,
        dataTypeId: 3,
        flags: 0,
        nameLengthOverride: 200, // lies: claims 200 bytes inside a tiny entry.
      );
      expect(
        () => parseSymbolBlob(blob, 1),
        throwsA(isA<MalformedFrameException>()),
      );
      // Explicitly assert it is NOT a RangeError leaking from an over-read.
      expect(
        () => parseSymbolBlob(blob, 1),
        isNot(throwsA(isA<RangeError>())),
      );
    });

    test('a truncated header (< 30 bytes) throws', () {
      final blob = Uint8List(20); // fewer than the 30-byte header.
      expect(
        () => parseSymbolBlob(blob, 1),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });
}
