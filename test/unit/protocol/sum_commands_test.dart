@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:dart_ads/src/protocol/sum_commands.dart';
import 'package:test/test.dart';

/// Reads a little-endian u32 from [bytes] at [offset].
int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

/// Builds a SUMUP_READ response inner-buffer from per-item (err, data) pairs,
/// applying the frozen 0-byte-on-failure convention (a failed item emits no
/// data). This mirrors what the mock/PLC produces.
Uint8List _readResponse(List<(int err, List<int> data)> items) {
  final builder = BytesBuilder();
  final errRegion = ByteData(items.length * 4);
  for (var i = 0; i < items.length; i++) {
    errRegion.setUint32(i * 4, items[i].$1, Endian.little);
  }
  builder.add(errRegion.buffer.asUint8List());
  for (final (err, data) in items) {
    if (err == 0) builder.add(data);
  }
  return builder.toBytes();
}

/// Builds a SUMUP_READWRITE response inner-buffer from per-item (err, retLen,
/// data) triples. `data` length must equal `retLen`.
Uint8List _readWriteResponse(
    List<(int err, int retLen, List<int> data)> items) {
  final builder = BytesBuilder();
  final headers = ByteData(items.length * 8);
  for (var i = 0; i < items.length; i++) {
    headers.setUint32(i * 8, items[i].$1, Endian.little);
    headers.setUint32(i * 8 + 4, items[i].$2, Endian.little);
  }
  builder.add(headers.buffer.asUint8List());
  for (final item in items) {
    builder.add(item.$3);
  }
  return builder.toBytes();
}

void main() {
  group('sum builders', () {
    test('buildSumReadPayload packs N*12B items and readLength = N*4 + Σlen',
        () {
      final (buf, readLength) = buildSumReadPayload([
        const SumReadRequest(indexGroup: 1, indexOffset: 2, length: 4),
        const SumReadRequest(indexGroup: 3, indexOffset: 4, length: 8),
      ]);
      expect(buf.length, 24);
      // Item 0.
      expect(_u32(buf, 0), 1);
      expect(_u32(buf, 4), 2);
      expect(_u32(buf, 8), 4);
      // Item 1.
      expect(_u32(buf, 12), 3);
      expect(_u32(buf, 16), 4);
      expect(_u32(buf, 20), 8);
      // readLength = 2*4 + (4 + 8) = 20.
      expect(readLength, 20);
    });

    test('buildSumWritePayload = N*12B headers THEN data; readLength = N*4',
        () {
      final (buf, readLength) = buildSumWritePayload([
        SumWriteRequest(
            indexGroup: 1, indexOffset: 2, data: Uint8List(4)..[0] = 0xAA),
        SumWriteRequest(
            indexGroup: 3, indexOffset: 4, data: Uint8List(8)..[0] = 0xBB),
      ]);
      // 2*12 headers + (4 + 8) data = 36.
      expect(buf.length, 36);
      expect(_u32(buf, 8), 4); // item 0 data.length
      expect(_u32(buf, 20), 8); // item 1 data.length
      expect(buf[24], 0xAA); // first data byte of item 0
      expect(buf[28], 0xBB); // first data byte of item 1
      expect(readLength, 8); // 2*4
    });

    test(
        'buildSumReadWritePayload = N*16B headers THEN writeData; '
        'readLength = N*8 + ΣrLen', () {
      final (buf, readLength) = buildSumReadWritePayload([
        SumReadWriteRequest(
            indexGroup: 1,
            indexOffset: 2,
            readLength: 6,
            writeData: Uint8List(4)..[0] = 0x11),
        SumReadWriteRequest(
            indexGroup: 3,
            indexOffset: 4,
            readLength: 10,
            writeData: Uint8List(8)..[0] = 0x22),
      ]);
      // 2*16 headers + (4 + 8) write = 44.
      expect(buf.length, 44);
      expect(_u32(buf, 8), 6); // item 0 readLength
      expect(_u32(buf, 12), 4); // item 0 writeData.length
      expect(_u32(buf, 24), 10); // item 1 readLength
      expect(_u32(buf, 28), 8); // item 1 writeData.length
      expect(buf[32], 0x11); // item 0 first write byte
      expect(buf[36], 0x22); // item 1 first write byte
      expect(readLength, 32); // 2*8 + (6 + 10)
    });

    test('builders apply checkUint to every u32 field', () {
      expect(
        () => buildSumReadPayload([
          const SumReadRequest(
              indexGroup: 0x100000000, indexOffset: 0, length: 0),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('sum read round-trip', () {
    test(
        'decodeSumReadResponse reconstructs per-item data at requested lengths',
        () {
      final items = [
        const SumReadRequest(indexGroup: 1, indexOffset: 0, length: 2),
        const SumReadRequest(indexGroup: 2, indexOffset: 0, length: 3),
      ];
      final resp = _readResponse([
        (0, [0xDE, 0xAD]),
        (0, [0xBE, 0xEF, 0x01]),
      ]);
      final results = decodeSumReadResponse(resp, items);
      expect(results.length, 2);
      expect(results[0].isSuccess, isTrue);
      expect(results[0].value, [0xDE, 0xAD]);
      expect(results[1].value, [0xBE, 0xEF, 0x01]);
    });

    test(
        'SUM-04: mid-batch failure leaves OTHER items at correct offsets '
        '(no throw)', () {
      final items = [
        const SumReadRequest(indexGroup: 1, indexOffset: 0, length: 2),
        const SumReadRequest(indexGroup: 2, indexOffset: 0, length: 4),
        const SumReadRequest(indexGroup: 3, indexOffset: 0, length: 3),
      ];
      // Item 1 fails (0x0703) and contributes 0 data bytes.
      final resp = _readResponse([
        (0, [0x0A, 0x0B]),
        (0x0703, [/* skipped */]),
        (0, [0x0C, 0x0D, 0x0E]),
      ]);
      final results = decodeSumReadResponse(resp, items);
      expect(results[0].value, [0x0A, 0x0B]);
      expect(results[1].isSuccess, isFalse);
      expect(results[1].errorCode, 0x0703);
      expect(results[1].value, isEmpty);
      // The load-bearing assertion: item 2 is NOT corrupted by item 1's absence.
      expect(results[2].value, [0x0C, 0x0D, 0x0E]);
    });

    test('failed READ item.valueOrThrow raises AdsException', () {
      final items = [
        const SumReadRequest(indexGroup: 1, indexOffset: 0, length: 1),
      ];
      final results = decodeSumReadResponse(
        _readResponse([(0x0703, [])]),
        items,
      );
      expect(() => results[0].valueOrThrow, throwsA(isA<Exception>()));
    });

    test('over-run throws MalformedFrameException before slicing', () {
      final items = [
        const SumReadRequest(indexGroup: 1, indexOffset: 0, length: 8),
      ];
      // Header says success but only 2 data bytes present (need 8).
      final resp = _readResponse([
        (0, [0x01, 0x02])
      ]);
      expect(
        () => decodeSumReadResponse(resp, items),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });

  group('sum write round-trip', () {
    test('decodeSumWriteResponse reads N result words only', () {
      final resp = ByteData(12)
        ..setUint32(0, 0, Endian.little)
        ..setUint32(4, 0x0703, Endian.little)
        ..setUint32(8, 0, Endian.little);
      final results = decodeSumWriteResponse(resp.buffer.asUint8List(), 3);
      expect(results.length, 3);
      expect(results[0].isSuccess, isTrue);
      expect(results[1].isSuccess, isFalse);
      expect(results[1].errorCode, 0x0703);
      expect(results[2].isSuccess, isTrue);
    });

    test('truncated write response throws MalformedFrameException', () {
      expect(
        () => decodeSumWriteResponse(Uint8List(4), 3),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });

  group('sum readWrite round-trip', () {
    test('decodeSumReadWriteResponse slices by RETURNED length, not requested',
        () {
      // Item 0 requested more but returned 2; item 1 returned 3.
      final resp = _readWriteResponse([
        (0, 2, [0xAA, 0xBB]),
        (0, 3, [0xCC, 0xDD, 0xEE]),
      ]);
      final results = decodeSumReadWriteResponse(resp, 2);
      expect(results[0].value, [0xAA, 0xBB]);
      expect(results[1].value, [0xCC, 0xDD, 0xEE]);
    });

    test('READWRITE mid-batch failure (retLen 0) keeps others aligned', () {
      final resp = _readWriteResponse([
        (0, 2, [0x01, 0x02]),
        (0x0705, 0, []),
        (0, 2, [0x03, 0x04]),
      ]);
      final results = decodeSumReadWriteResponse(resp, 3);
      expect(results[0].value, [0x01, 0x02]);
      expect(results[1].isSuccess, isFalse);
      expect(results[1].value, isEmpty);
      expect(results[2].value, [0x03, 0x04]);
    });

    test('READWRITE over-run throws MalformedFrameException', () {
      // One item whose header claims retLen 8 but only 2 data bytes follow.
      final bad = Uint8List(8 + 2)
        ..buffer.asByteData().setUint32(4, 8, Endian.little);
      bad.setRange(8, 10, [0x01, 0x02]);
      expect(
        () => decodeSumReadWriteResponse(bad, 1),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('READWRITE truncated header region throws', () {
      // n=2 needs 16 header bytes; supply only 8.
      expect(
        () => decodeSumReadWriteResponse(Uint8List(8), 2),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });
}
