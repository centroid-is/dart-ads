@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven coverage for the three [AdsClient] sum (batched) methods
/// — `sumRead`, `sumWrite`, `sumReadWrite`. No sockets, no C++ mock: each
/// SUMUP response is scripted through [FakeTransport.feed] as a ReadWrite reply,
/// and the single outbound ReadWrite frame is captured in [FakeTransport.written].
/// Reaching into `src/` for `FakeTransport` is acceptable — these are
/// same-package unit tests.
///
/// The invariants proven here (06-04 must_haves):
///   * Each method issues exactly ONE ReadWrite (cmd 0x09) to its SUMUP index
///     group with `indexOffset == N` (the item count).
///   * A per-item error word populates that item's `SumResult.errorCode`,
///     `isSuccess == false`, and NEVER throws the batch (SUM-04); the other
///     items still land at their correct data offsets.
///   * A non-zero outer ADS `result` word throws [AdsException] (outer layer)
///     before any list is returned.
///   * An empty batch returns `[]` with NO bytes written to the transport.
void main() {
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  /// Builds a complete on-wire AMS/TCP response frame (6-byte wrapper + 32-byte
  /// AMS header + [payload]) using the REAL Phase-1 codecs, stamped with
  /// [invokeId], the ReadWrite [commandId], and the AMS-header [errorCode].
  Uint8List buildFrame({
    required int invokeId,
    int commandId = AdsCommandId.readWrite,
    int errorCode = 0,
    Uint8List? payload,
  }) {
    final body = payload ?? Uint8List(0);
    final ams = AmsHeader(
      targetNetId: source.netId,
      targetPort: source.port,
      sourceNetId: target.netId,
      sourcePort: target.port,
      commandId: commandId,
      stateFlags: AmsStateFlags.response,
      dataLength: body.length,
      errorCode: errorCode,
      invokeId: invokeId,
    ).encode();
    final tcp =
        AmsTcpHeader(length: AmsHeader.byteLength + body.length).encode();
    final total = AmsTcpHeader.byteLength + AmsHeader.byteLength + body.length;
    return Uint8List(total)
      ..setRange(0, AmsTcpHeader.byteLength, tcp)
      ..setRange(AmsTcpHeader.byteLength,
          AmsTcpHeader.byteLength + AmsHeader.byteLength, ams)
      ..setRange(AmsTcpHeader.byteLength + AmsHeader.byteLength, total, body);
  }

  /// Builds a ReadWrite ADS response payload: `result u32 + readLength u32 +
  /// inner[readLength]` — the shape [decodeReadWriteResponse] parses. [inner] is
  /// the SUMUP inner read-buffer the sum decoders consume.
  Uint8List readWritePayload({int result = 0, required Uint8List inner}) {
    final p = Uint8List(8 + inner.length);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    bd.setUint32(4, inner.length, Endian.little);
    p.setRange(8, 8 + inner.length, inner);
    return p;
  }

  /// Assembles a SUMUP_READ inner read-buffer: `errs` (one u32 per item) then
  /// the concatenated `blocks` (a failed item contributes an empty block).
  Uint8List sumReadInner(List<int> errs, List<Uint8List> blocks) {
    final headerLen = errs.length * 4;
    final dataLen = blocks.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(headerLen + dataLen);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < errs.length; i++) {
      bd.setUint32(i * 4, errs[i], Endian.little);
    }
    var cursor = headerLen;
    for (final b in blocks) {
      out.setRange(cursor, cursor + b.length, b);
      cursor += b.length;
    }
    return out;
  }

  /// Assembles a SUMUP_WRITE inner read-buffer: one u32 result word per item.
  Uint8List sumWriteInner(List<int> errs) {
    final out = Uint8List(errs.length * 4);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < errs.length; i++) {
      bd.setUint32(i * 4, errs[i], Endian.little);
    }
    return out;
  }

  /// Assembles a SUMUP_READWRITE inner read-buffer: `N × (result u32,
  /// returnedLength u32)` headers then the concatenated `blocks`.
  Uint8List sumReadWriteInner(List<int> errs, List<Uint8List> blocks) {
    final headerLen = errs.length * 8;
    final dataLen = blocks.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(headerLen + dataLen);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < errs.length; i++) {
      bd.setUint32(i * 8, errs[i], Endian.little);
      bd.setUint32(i * 8 + 4, blocks[i].length, Endian.little);
    }
    var cursor = headerLen;
    for (final b in blocks) {
      out.setRange(cursor, cursor + b.length, b);
      cursor += b.length;
    }
    return out;
  }

  /// Decodes the AMS header of an outbound frame the client wrote.
  AmsHeader outboundHeader(Uint8List frame) =>
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);

  /// The raw ADS payload (bytes AFTER the 38-byte header prefix) of an outbound
  /// frame.
  Uint8List outboundPayload(Uint8List frame) => Uint8List.sublistView(
        frame,
        AmsTcpHeader.byteLength + AmsHeader.byteLength,
      );

  Future<(AdsClient, FakeTransport)> newClient() async {
    final fake = FakeTransport();
    final conn = AmsConnection(fake, source: source, target: target);
    await conn.connect('fake', 0);
    return (AdsClient(conn, target: target, source: source), fake);
  }

  group('sumRead', () {
    test('one ReadWrite to 0xF080 with indexOffset==N; clean 3-item batch',
        () async {
      final (client, fake) = await newClient();
      final items = [
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 0, length: 4),
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 4, length: 4),
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 8, length: 4),
      ];

      final future = client.sumRead(items);
      await pumpEventQueue();

      // Exactly one ReadWrite frame, to the SUMUP_READ group, indexOffset == N.
      expect(fake.written, hasLength(1));
      final frame = fake.written.single;
      expect(outboundHeader(frame).commandId, AdsCommandId.readWrite);
      final reqBd = ByteData.sublistView(outboundPayload(frame));
      expect(reqBd.getUint32(0, Endian.little), 0xF080); // indexGroup
      expect(reqBd.getUint32(4, Endian.little), 3); // indexOffset == N

      final inner = sumReadInner(
        [0, 0, 0],
        [
          Uint8List.fromList([1, 1, 1, 1]),
          Uint8List.fromList([2, 2, 2, 2]),
          Uint8List.fromList([3, 3, 3, 3]),
        ],
      );
      fake.feed(buildFrame(
        invokeId: outboundHeader(frame).invokeId,
        payload: readWritePayload(inner: inner),
      ));

      final results = await future;
      expect(results, hasLength(3));
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(results[0].value, equals([1, 1, 1, 1]));
      expect(results[1].value, equals([2, 2, 2, 2]));
      expect(results[2].value, equals([3, 3, 3, 3]));
    });

    test(
        'mid-batch partial failure never throws; offsets stay aligned (SUM-04)',
        () async {
      final (client, fake) = await newClient();
      final items = [
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 0, length: 4),
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 4, length: 4),
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 8, length: 4),
      ];

      final future = client.sumRead(items);
      await pumpEventQueue();

      // item[1] fails (0x0703): it contributes ZERO data bytes; items 0 and 2
      // still land at the correct offsets.
      final inner = sumReadInner(
        [0, 0x0703, 0],
        [
          Uint8List.fromList([0xAA, 0xAA, 0xAA, 0xAA]),
          Uint8List(0),
          Uint8List.fromList([0xCC, 0xCC, 0xCC, 0xCC]),
        ],
      );
      fake.feed(buildFrame(
        invokeId: outboundHeader(fake.written.single).invokeId,
        payload: readWritePayload(inner: inner),
      ));

      final results = await future; // must NOT throw
      expect(results, hasLength(3));
      expect(results[0].isSuccess, isTrue);
      expect(results[0].value, equals([0xAA, 0xAA, 0xAA, 0xAA]));
      expect(results[1].isSuccess, isFalse);
      expect(results[1].errorCode, 0x0703);
      expect(results[1].value, isEmpty);
      expect(results[2].isSuccess, isTrue);
      expect(results[2].value, equals([0xCC, 0xCC, 0xCC, 0xCC]));
    });

    test('non-zero outer ADS result throws AdsException', () async {
      final (client, fake) = await newClient();
      final items = [
        const SumReadRequest(indexGroup: 0x4020, indexOffset: 0, length: 4),
      ];

      final future = client.sumRead(items);
      await pumpEventQueue();

      fake.feed(buildFrame(
        invokeId: outboundHeader(fake.written.single).invokeId,
        payload: readWritePayload(result: 0x0701, inner: Uint8List(0)),
      ));

      await expectLater(
        future,
        throwsA(isA<AdsException>().having((e) => e.code, 'code', 0x0701)),
      );
    });

    test('empty batch returns [] with no bytes written', () async {
      final (client, fake) = await newClient();

      final results = await client.sumRead(const []);
      expect(results, isEmpty);
      expect(fake.written, isEmpty);
    });
  });

  group('sumWrite', () {
    test('one ReadWrite to 0xF081; per-item results returned', () async {
      final (client, fake) = await newClient();
      final items = [
        SumWriteRequest(
            indexGroup: 0x4020, indexOffset: 0, data: Uint8List.fromList([1])),
        SumWriteRequest(
            indexGroup: 0x4020,
            indexOffset: 4,
            data: Uint8List.fromList([2, 3])),
      ];

      final future = client.sumWrite(items);
      await pumpEventQueue();

      final frame = fake.written.single;
      final reqBd = ByteData.sublistView(outboundPayload(frame));
      expect(reqBd.getUint32(0, Endian.little), 0xF081); // SUMUP_WRITE
      expect(reqBd.getUint32(4, Endian.little), 2); // indexOffset == N

      fake.feed(buildFrame(
        invokeId: outboundHeader(frame).invokeId,
        payload: readWritePayload(inner: sumWriteInner([0, 0x0705])),
      ));

      final results = await future;
      expect(results, hasLength(2));
      expect(results[0].isSuccess, isTrue);
      expect(results[1].isSuccess, isFalse);
      expect(results[1].errorCode, 0x0705);
    });

    test('empty batch returns [] with no bytes written', () async {
      final (client, fake) = await newClient();
      final results = await client.sumWrite(const []);
      expect(results, isEmpty);
      expect(fake.written, isEmpty);
    });
  });

  group('sumReadWrite', () {
    test('one ReadWrite to 0xF082; per-item data sliced by returned length',
        () async {
      final (client, fake) = await newClient();
      final items = [
        SumReadWriteRequest(
          indexGroup: 0x4020,
          indexOffset: 0,
          readLength: 4,
          writeData: Uint8List.fromList([1]),
        ),
        SumReadWriteRequest(
          indexGroup: 0x4020,
          indexOffset: 4,
          readLength: 4,
          writeData: Uint8List.fromList([2]),
        ),
      ];

      final future = client.sumReadWrite(items);
      await pumpEventQueue();

      final frame = fake.written.single;
      final reqBd = ByteData.sublistView(outboundPayload(frame));
      expect(reqBd.getUint32(0, Endian.little), 0xF082); // SUMUP_READWRITE
      expect(reqBd.getUint32(4, Endian.little), 2); // indexOffset == N

      final inner = sumReadWriteInner(
        [0, 0],
        [
          Uint8List.fromList([9, 9, 9, 9]),
          Uint8List.fromList([8, 8]), // returned length 2 < requested 4
        ],
      );
      fake.feed(buildFrame(
        invokeId: outboundHeader(frame).invokeId,
        payload: readWritePayload(inner: inner),
      ));

      final results = await future;
      expect(results, hasLength(2));
      expect(results[0].value, equals([9, 9, 9, 9]));
      expect(results[1].value, equals([8, 8]));
    });

    test('partial failure never throws the batch (SUM-04)', () async {
      final (client, fake) = await newClient();
      final items = [
        SumReadWriteRequest(
          indexGroup: 0x4020,
          indexOffset: 0,
          readLength: 4,
          writeData: Uint8List.fromList([1]),
        ),
        SumReadWriteRequest(
          indexGroup: 0x4020,
          indexOffset: 4,
          readLength: 4,
          writeData: Uint8List.fromList([2]),
        ),
      ];

      final future = client.sumReadWrite(items);
      await pumpEventQueue();

      // item[0] fails with returned length 0; item[1] succeeds with 4 bytes.
      final inner = sumReadWriteInner(
        [0x0703, 0],
        [
          Uint8List(0),
          Uint8List.fromList([7, 7, 7, 7]),
        ],
      );
      fake.feed(buildFrame(
        invokeId: outboundHeader(fake.written.single).invokeId,
        payload: readWritePayload(inner: inner),
      ));

      final results = await future; // must NOT throw
      expect(results[0].isSuccess, isFalse);
      expect(results[0].errorCode, 0x0703);
      expect(results[0].value, isEmpty);
      expect(results[1].isSuccess, isTrue);
      expect(results[1].value, equals([7, 7, 7, 7]));
    });

    test('empty batch returns [] with no bytes written', () async {
      final (client, fake) = await newClient();
      final results = await client.sumReadWrite(const []);
      expect(results, isEmpty);
      expect(fake.written, isEmpty);
    });
  });
}
