@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven coverage for the [AdsClient] symbol-access surface added
/// in Plan 07-05 — handle lifecycle (0xF003/0xF005/0xF006), symbol browse
/// (0xF00C then 0xF00B), and the RAII [AdsHandle] helper. No sockets, no C++
/// mock: each device reply is scripted through [FakeTransport.feed] and every
/// outbound frame is captured in [FakeTransport.written]. Reaching into `src/`
/// for [FakeTransport] is acceptable in same-package unit tests.
void main() {
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  Uint8List buildFrame({
    required int invokeId,
    required int commandId,
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

  /// A Read/ReadWrite response payload: `result u32 + length u32 + data`.
  Uint8List readPayload({int result = 0, required Uint8List data}) {
    final p = Uint8List(8 + data.length);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    bd.setUint32(4, data.length, Endian.little);
    p.setRange(8, 8 + data.length, data);
    return p;
  }

  /// A Write response payload: `result u32`.
  Uint8List writePayload({int result = 0}) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, result, Endian.little);
    return p;
  }

  Uint8List u32le(int v) {
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, v, Endian.little);
    return b;
  }

  AmsHeader outboundHeader(Uint8List frame) =>
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);

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

  /// Feeds a reply for the single outbound frame, echoing its invokeId.
  void reply(FakeTransport fake, int commandId, Uint8List payload,
      {int errorCode = 0}) {
    final h = outboundHeader(fake.written.last);
    fake.feed(buildFrame(
      invokeId: h.invokeId,
      commandId: commandId,
      errorCode: errorCode,
      payload: payload,
    ));
  }

  /// One 30-byte-header symbol entry, tightly packed like a real 0xF00B blob.
  Uint8List symbolEntry({
    required String name,
    required String typeName,
    required String comment,
    int indexGroup = 0x4020,
    int indexOffset = 0,
    int size = 4,
    int dataTypeId = 0,
    int flags = 0,
  }) {
    final nameB = latin1.encode(name);
    final typeB = latin1.encode(typeName);
    final commentB = latin1.encode(comment);
    final entryLen =
        30 + nameB.length + 1 + typeB.length + 1 + commentB.length + 1;
    final e = Uint8List(entryLen);
    final bd = ByteData.sublistView(e);
    bd.setUint32(0, entryLen, Endian.little);
    bd.setUint32(4, indexGroup, Endian.little);
    bd.setUint32(8, indexOffset, Endian.little);
    bd.setUint32(12, size, Endian.little);
    bd.setUint32(16, dataTypeId, Endian.little);
    bd.setUint32(20, flags, Endian.little);
    bd.setUint16(24, nameB.length, Endian.little);
    bd.setUint16(26, typeB.length, Endian.little);
    bd.setUint16(28, commentB.length, Endian.little);
    var p = 30;
    e.setRange(p, p + nameB.length, nameB);
    p += nameB.length + 1;
    e.setRange(p, p + typeB.length, typeB);
    p += typeB.length + 1;
    e.setRange(p, p + commentB.length, commentB);
    return e;
  }

  group('getHandleByName', () {
    test('resolves name+NUL via ReadWrite 0xF003 and decodes the u32 handle',
        () async {
      final (client, fake) = await newClient();
      final future = client.getHandleByName('MAIN.counter');
      await pumpEventQueue();

      final frame = fake.written.single;
      expect(outboundHeader(frame).commandId, AdsCommandId.readWrite);
      final bd = ByteData.sublistView(outboundPayload(frame));
      expect(bd.getUint32(0, Endian.little), AdsIndexGroup.symbolHandleByName);
      expect(bd.getUint32(4, Endian.little), 0); // indexOffset
      expect(bd.getUint32(8, Endian.little), 4); // readLength
      final writeLen = bd.getUint32(12, Endian.little);
      final writeData =
          Uint8List.sublistView(outboundPayload(frame), 16, 16 + writeLen);
      expect(writeData.last, 0, reason: 'name is NUL-terminated (A1)');
      expect(latin1.decode(writeData.sublist(0, writeLen - 1)), 'MAIN.counter');

      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x1234)));
      expect(await future, 0x1234);
    });
  });

  group('readByHandle / writeByHandle / releaseHandle', () {
    test('readByHandle reads 0xF005 with indexOffset==handle', () async {
      final (client, fake) = await newClient();
      final future = client.readByHandle(0x1234, 4);
      await pumpEventQueue();

      final bd = ByteData.sublistView(outboundPayload(fake.written.single));
      expect(bd.getUint32(0, Endian.little), AdsIndexGroup.symbolValueByHandle);
      expect(bd.getUint32(4, Endian.little), 0x1234); // indexOffset == handle
      expect(bd.getUint32(8, Endian.little), 4); // length

      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([9, 8, 7, 6])));
      expect(await future, equals([9, 8, 7, 6]));
    });

    test('writeByHandle writes 0xF005 with indexOffset==handle', () async {
      final (client, fake) = await newClient();
      final future =
          client.writeByHandle(0x1234, Uint8List.fromList([1, 2, 3, 4]));
      await pumpEventQueue();

      final payload = outboundPayload(fake.written.single);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), AdsIndexGroup.symbolValueByHandle);
      expect(bd.getUint32(4, Endian.little), 0x1234);
      expect(bd.getUint32(8, Endian.little), 4);
      expect(Uint8List.sublistView(payload, 12), equals([1, 2, 3, 4]));

      reply(fake, AdsCommandId.write, writePayload());
      await future;
    });

    test('releaseHandle writes 0xF006 with indexOffset==0 and handle-as-data',
        () async {
      final (client, fake) = await newClient();
      final future = client.releaseHandle(0x1234);
      await pumpEventQueue();

      final payload = outboundPayload(fake.written.single);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), AdsIndexGroup.symbolReleaseHandle);
      expect(bd.getUint32(4, Endian.little), 0); // indexOffset == 0
      expect(bd.getUint32(8, Endian.little), 4); // 4-byte handle payload
      expect(bd.getUint32(12, Endian.little), 0x1234); // handle as DATA

      reply(fake, AdsCommandId.write, writePayload());
      await future;
    });
  });

  group('readByName / writeByName', () {
    test('resolves, reads, then releases even though the op succeeded',
        () async {
      final (client, fake) = await newClient();
      final future = client.readByName('MAIN.x', 4);
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x55)));
      await pumpEventQueue();
      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([1, 2, 3, 4])));
      await pumpEventQueue();
      // Release frame is the third write.
      reply(fake, AdsCommandId.write, writePayload());

      expect(await future, equals([1, 2, 3, 4]));
      expect(fake.written, hasLength(3));
      final releaseBd = ByteData.sublistView(outboundPayload(fake.written[2]));
      expect(releaseBd.getUint32(0, Endian.little),
          AdsIndexGroup.symbolReleaseHandle);
      expect(releaseBd.getUint32(12, Endian.little), 0x55);
    });
  });

  group('browseSymbols', () {
    test('0xF00C then 0xF00B round-trips a blob into ordered AdsSymbolInfo',
        () async {
      final (client, fake) = await newClient();
      final e0 = symbolEntry(
          name: 'MAIN.a', typeName: 'DINT', comment: 'first', indexOffset: 0);
      final e1 = symbolEntry(
          name: 'MAIN.b',
          typeName: 'BOOL',
          comment: '',
          indexOffset: 4,
          size: 1);
      final blob = Uint8List(e0.length + e1.length)
        ..setRange(0, e0.length, e0)
        ..setRange(e0.length, e0.length + e1.length, e1);

      final future = client.browseSymbols();
      await pumpEventQueue();

      // First read: 0xF00C for the {nSymbols, nSymSize} header (8 bytes).
      final infoBd = ByteData.sublistView(outboundPayload(fake.written.single));
      expect(
          infoBd.getUint32(0, Endian.little), AdsIndexGroup.symbolUploadInfo);
      expect(infoBd.getUint32(8, Endian.little), 8);
      final infoPayload = Uint8List(8);
      final ib = ByteData.sublistView(infoPayload);
      ib.setUint32(0, 2, Endian.little); // nSymbols
      ib.setUint32(4, blob.length, Endian.little); // nSymSize
      reply(fake, AdsCommandId.read, readPayload(data: infoPayload));
      await pumpEventQueue();

      // Second read: 0xF00B for nSymSize bytes.
      final uploadBd = ByteData.sublistView(outboundPayload(fake.written[1]));
      expect(uploadBd.getUint32(0, Endian.little), AdsIndexGroup.symbolUpload);
      expect(uploadBd.getUint32(8, Endian.little), blob.length);
      reply(fake, AdsCommandId.read, readPayload(data: blob));

      final symbols = await future;
      expect(symbols, hasLength(2));
      expect(symbols[0].name, 'MAIN.a');
      expect(symbols[0].typeName, 'DINT');
      expect(symbols[0].comment, 'first');
      expect(symbols[1].name, 'MAIN.b');
      expect(symbols[1].size, 1);
    });

    test('an insane nSymSize is rejected before allocating (T-7-02b)',
        () async {
      final (client, fake) = await newClient();
      final future = client.browseSymbols();
      await pumpEventQueue();
      final infoPayload = Uint8List(8);
      final ib = ByteData.sublistView(infoPayload);
      ib.setUint32(0, 1, Endian.little);
      ib.setUint32(4, 0xFFFFFFFF, Endian.little); // ~4 GiB
      reply(fake, AdsCommandId.read, readPayload(data: infoPayload));

      await expectLater(future, throwsA(isA<MalformedFrameException>()));
      // No second (0xF00B) read was issued.
      expect(fake.written, hasLength(1));
    });
  });

  group('typed convenience', () {
    test('readDintByName resolves→reads→decodes→releases', () async {
      final (client, fake) = await newClient();
      final future = client.readDintByName('MAIN.count');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x77)));
      await pumpEventQueue();
      final data = Uint8List(4);
      ByteData.sublistView(data).setInt32(0, -12345, Endian.little);
      reply(fake, AdsCommandId.read, readPayload(data: data));
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload());

      expect(await future, -12345);
    });

    test('writeRealByName encodes via the codec', () async {
      final (client, fake) = await newClient();
      final future = client.writeRealByName('MAIN.f', 1.5);
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x88)));
      await pumpEventQueue();
      // Capture the write-by-handle frame (second frame).
      final payload = outboundPayload(fake.written[1]);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), AdsIndexGroup.symbolValueByHandle);
      expect(
          ByteData.sublistView(Uint8List.sublistView(payload, 12))
              .getFloat32(0, Endian.little),
          1.5);
      reply(fake, AdsCommandId.write, writePayload());
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload()); // release
      await future;
    });

    test(
        'short reply to a 4-byte typed read throws MalformedFrameException, '
        'not RangeError (CR-01)', () async {
      final (client, fake) = await newClient();
      final future = client.readDintByName('MAIN.count');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x77)));
      await pumpEventQueue();
      // Device answers 2 self-consistent bytes (readLength == 2, 2 bytes):
      // passes both error levels, but is too short for a DINT decode.
      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([0x01, 0x02])));
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload()); // release still happens
      await expectLater(future, throwsA(isA<MalformedFrameException>()));
      // The handle was still released (3 frames: resolve, read, release).
      expect(fake.written, hasLength(3));
    });

    test(
        'short reply to an 8-byte typed read throws MalformedFrameException, '
        'not RangeError (CR-01)', () async {
      final (client, fake) = await newClient();
      final future = client.readLrealByName('MAIN.temp');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x78)));
      await pumpEventQueue();
      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([0, 0, 0, 0]))); // 4 < 8
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload()); // release still happens
      await expectLater(future, throwsA(isA<MalformedFrameException>()));
    });

    test('empty reply to a BOOL read throws MalformedFrameException (CR-01)',
        () async {
      final (client, fake) = await newClient();
      final future = client.readBoolByName('MAIN.flag');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x79)));
      await pumpEventQueue();
      reply(fake, AdsCommandId.read, readPayload(data: Uint8List(0)));
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload()); // release still happens
      await expectLater(future, throwsA(isA<MalformedFrameException>()));
    });

    test('short STRING reply decodes without RangeError (CR-01)', () async {
      // STRING has no fixed decode width: decodeString stops at the first NUL
      // (or buffer end), so a short device reply must decode, not crash.
      final (client, fake) = await newClient();
      final future = client.readStringByName('MAIN.text', 81);
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x7A)));
      await pumpEventQueue();
      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([0x61, 0x62, 0x00]))); // "ab\0"
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload()); // release
      expect(await future, 'ab');
    });
  });

  group('AdsHandle', () {
    test('create resolves, read/write delegate, close releases once', () async {
      final (client, fake) = await newClient();
      final createF = AdsHandle.create(client, 'MAIN.v');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0x99)));
      final handle = await createF;
      expect(handle.isValid, isTrue);

      final readF = handle.read(4);
      await pumpEventQueue();
      final rbd = ByteData.sublistView(outboundPayload(fake.written[1]));
      expect(rbd.getUint32(4, Endian.little), 0x99); // indexOffset == handle
      reply(fake, AdsCommandId.read,
          readPayload(data: Uint8List.fromList([1, 0, 0, 0])));
      await readF;

      final closeF = handle.close();
      await pumpEventQueue();
      final relBd = ByteData.sublistView(outboundPayload(fake.written[2]));
      expect(
          relBd.getUint32(0, Endian.little), AdsIndexGroup.symbolReleaseHandle);
      expect(relBd.getUint32(12, Endian.little), 0x99);
      reply(fake, AdsCommandId.write, writePayload());
      await closeF;

      // Idempotent: a second close writes nothing more.
      await handle.close();
      expect(fake.written, hasLength(3));
    });

    test('a 0x710 during an op marks the handle invalid; reuse throws',
        () async {
      final (client, fake) = await newClient();
      final createF = AdsHandle.create(client, 'MAIN.v');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0xAB)));
      final handle = await createF;

      final readF = handle.read(4);
      await pumpEventQueue();
      // Device answers with SYMBOLNOTFOUND (0x0710) in the ADS result word.
      reply(fake, AdsCommandId.read,
          readPayload(result: 0x0710, data: Uint8List(0)));
      await expectLater(readF, throwsA(isA<AdsException>()));
      expect(handle.isValid, isFalse);

      // A subsequent op on the invalidated handle throws StateError (no reuse).
      expect(() => handle.read(4), throwsA(isA<StateError>()));
    });

    test(
        'a failed release does not latch closed — retry close() releases '
        '(WR-01)', () async {
      final (client, fake) = await newClient();
      final createF = AdsHandle.create(client, 'MAIN.v');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0xCD)));
      final handle = await createF;

      // First close: the device rejects the release with a generic error.
      final closeF = handle.close();
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload(result: 0x700));
      await expectLater(closeF, throwsA(isA<AdsException>()));
      // NOT latched closed: the handle is still releasable through the wrapper.
      expect(handle.isValid, isTrue);

      // Retry close: this time the release succeeds and the state latches.
      final retryF = handle.close();
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload());
      await retryF;
      expect(handle.isValid, isFalse);
      // resolve + failed release + successful release = 3 frames.
      expect(fake.written, hasLength(3));

      // Idempotent after success: nothing more hits the wire.
      await handle.close();
      expect(fake.written, hasLength(3));
    });

    test('a 0x710 during close() treats the handle as closed — no rethrow',
        () async {
      final (client, fake) = await newClient();
      final createF = AdsHandle.create(client, 'MAIN.v');
      await pumpEventQueue();
      reply(fake, AdsCommandId.readWrite, readPayload(data: u32le(0xCE)));
      final handle = await createF;

      // The symbol table was reloaded underneath us: release answers 0x710.
      // The device handle no longer exists, so close() completes quietly.
      final closeF = handle.close();
      await pumpEventQueue();
      reply(fake, AdsCommandId.write, writePayload(result: 0x0710));
      await closeF;
      expect(handle.isValid, isFalse);

      // Latched: a retry writes nothing more.
      await handle.close();
      expect(fake.written, hasLength(2));
    });
  });
}
