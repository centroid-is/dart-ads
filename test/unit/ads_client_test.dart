@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven coverage for [AdsClient] — the six core commands plus
/// the BOTH-levels [AdsException] mapping (AMS-header `errorCode` pre-decode and
/// payload `result` post-decode). No sockets, no C++ mock: server→client frames
/// are scripted through [FakeTransport.feed]. Reaching into `src/` for
/// `FakeTransport` is acceptable — these are same-package unit tests.
void main() {
  // Arbitrary but valid AMS addressing for the client under test.
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  /// Builds a complete on-wire AMS/TCP response frame (6-byte wrapper + 32-byte
  /// AMS header + [payload]) using the REAL Phase-1 codecs, stamped with
  /// [invokeId], [commandId], and the AMS-header [errorCode]. The [errorCode]
  /// override is what makes the AMS-level throw testable.
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

  /// Decodes the invoke-ID the connection stamped onto the single outbound
  /// frame the client sent.
  int outboundInvokeId(Uint8List frame) =>
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength)
          .invokeId;

  // ---- response-payload builders (bytes AFTER the 32-byte AMS header) --------

  /// `result u32 + readLength u32 + data` — the Read / ReadWrite payload shape.
  Uint8List resultAndData(int result, Uint8List data) {
    final p = Uint8List(8 + data.length);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    bd.setUint32(4, data.length, Endian.little);
    p.setRange(8, 8 + data.length, data);
    return p;
  }

  /// `result u32` — the Write / WriteControl payload shape.
  Uint8List resultOnly(int result) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, result, Endian.little);
    return p;
  }

  /// `result u32 + adsState u16 + deviceState u16` — the ReadState shape.
  Uint8List statePayload(int result, int adsState, int deviceState) {
    final p = Uint8List(8);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    bd.setUint16(4, adsState, Endian.little);
    bd.setUint16(6, deviceState, Endian.little);
    return p;
  }

  /// `result u32 + version u8 + revision u8 + build u16 + name[16]` — the
  /// ReadDeviceInfo shape.
  Uint8List deviceInfoPayload(
    int result,
    int version,
    int revision,
    int build,
    String name,
  ) {
    final p = Uint8List(24);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    p[4] = version;
    p[5] = revision;
    bd.setUint16(6, build, Endian.little);
    final nameBytes = name.codeUnits;
    p.setRange(8, 8 + nameBytes.length, nameBytes);
    return p;
  }

  /// Connects a fresh FakeTransport + AmsConnection and returns a client over
  /// it, along with the fake so the test can capture outbound frames and feed
  /// scripted responses.
  Future<(AdsClient, FakeTransport)> newClient() async {
    final fake = FakeTransport();
    final conn = AmsConnection(fake, source: source, target: target);
    await conn.connect('fake', 0);
    return (AdsClient(conn, target: target, source: source), fake);
  }

  group('per-command mapping', () {
    test('read returns the device bytes', () async {
      final (client, fake) = await newClient();
      final data = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

      final future = client.read(indexGroup: 0x4020, indexOffset: 0, length: 4);
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.read,
        payload: resultAndData(0, data),
      ));

      expect(await future, equals(data));
    });

    test('write completes on a zero result', () async {
      final (client, fake) = await newClient();

      final future = client.write(
        indexGroup: 0x4020,
        indexOffset: 0,
        data: Uint8List.fromList([1, 2, 3]),
      );
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.write,
        payload: resultOnly(0),
      ));

      await expectLater(future, completes);
    });

    test('read_write returns the read bytes', () async {
      final (client, fake) = await newClient();
      final readBack = Uint8List.fromList([0x11, 0x22]);

      final future = client.readWrite(
        indexGroup: 0xF003,
        indexOffset: 0,
        readLength: 2,
        writeData: Uint8List.fromList([0x41, 0x42]),
      );
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.readWrite,
        payload: resultAndData(0, readBack),
      ));

      expect(await future, equals(readBack));
    });

    test('read_state maps adsState to the enum and keeps the raw ints',
        () async {
      final (client, fake) = await newClient();

      final future = client.readState();
      final id = outboundInvokeId(fake.written.single);
      // adsState 5 == RUN; deviceState 7 is device-specific.
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.readState,
        payload: statePayload(0, 5, 7),
      ));

      final info = await future;
      expect(info.adsState, AdsState.run);
      expect(info.rawAdsState, 5);
      expect(info.deviceState, 7);
    });

    test('read_state surfaces an unknown wire value as AdsState.unknown',
        () async {
      final (client, fake) = await newClient();

      final future = client.readState();
      final id = outboundInvokeId(fake.written.single);
      // 999 is outside the known 0..19 range — must NOT crash decode.
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.readState,
        payload: statePayload(0, 999, 0),
      ));

      final info = await future;
      expect(info.adsState, AdsState.unknown);
      expect(info.rawAdsState, 999);
    });

    test('write_control completes on a zero result', () async {
      final (client, fake) = await newClient();

      final future = client.writeControl(adsState: AdsState.run);
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.writeControl,
        payload: resultOnly(0),
      ));

      await expectLater(future, completes);
    });

    test('device_info returns the name and version triple', () async {
      final (client, fake) = await newClient();

      final future = client.readDeviceInfo();
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.readDeviceInfo,
        payload: deviceInfoPayload(0, 3, 1, 4024, 'Plc30 App'),
      ));

      final info = await future;
      expect(info.name, 'Plc30 App');
      expect(info.version, 3);
      expect(info.revision, 1);
      expect(info.build, 4024);
    });
  });

  group('both error levels', () {
    test('result_error: a non-zero payload result throws AdsException(0x0703)',
        () async {
      final (client, fake) = await newClient();

      final future = client.read(indexGroup: 0x4020, indexOffset: 0, length: 4);
      final id = outboundInvokeId(fake.written.single);
      // errorCode 0 (AMS OK) but the ADS payload result is 0x0703.
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.read,
        payload: resultAndData(0x0703, Uint8List(0)),
      ));

      await expectLater(
        future,
        throwsA(
          isA<AdsException>().having((e) => e.code, 'code', 0x0703),
        ),
      );
    });

    test(
        'ams_error: a non-zero AMS errorCode throws AdsException(0x0007) '
        'BEFORE decode', () async {
      final (client, fake) = await newClient();

      final future = client.read(indexGroup: 0x4020, indexOffset: 0, length: 4);
      final id = outboundInvokeId(fake.written.single);
      // AMS errorCode 0x0007 with an EMPTY payload: if the client decoded first
      // it would throw MalformedFrameException (Read needs >= 8 bytes). Getting
      // AdsException(0x0007) instead proves the errorCode is checked pre-decode.
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.read,
        errorCode: 0x0007,
        payload: Uint8List(0),
      ));

      await expectLater(
        future,
        throwsA(
          isA<AdsException>().having((e) => e.code, 'code', 0x0007),
        ),
      );
    });

    test('an AdsException is distinct from the transport/wire families',
        () async {
      final (client, fake) = await newClient();

      final future = client.read(indexGroup: 0x4020, indexOffset: 0, length: 4);
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.read,
        payload: resultAndData(0x0703, Uint8List(0)),
      ));

      await expectLater(
        future,
        throwsA(
          allOf(
            isA<AdsException>(),
            isNot(isA<AdsTimeoutException>()),
            isNot(isA<AdsConnectionException>()),
            isNot(isA<MalformedFrameException>()),
          ),
        ),
      );
    });
  });
}
