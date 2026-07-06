@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven coverage for [AdsClient.subscribe] — the notification
/// lifecycle state machine. No sockets, no C++ mock: the Add / Delete responses
/// are scripted through [FakeTransport.feed], and the outbound Add / Delete
/// frames are captured in [FakeTransport.written]. Reaching into `src/` for
/// `FakeTransport` is acceptable — these are same-package unit tests.
///
/// The invariants proven here (05-05 must_haves):
///   * NO AddDeviceNotification is sent until the stream is first listened.
///   * First listen writes exactly one Add (cmd 0x06) with the 40-byte payload
///     (mode.code @12, maxDelay @16, cycleTime @20, all in 100ns units).
///   * onCancel always attempts a Delete (cmd 0x07) and completes without throw.
///   * An Add failure surfaces via the stream's error, and no Delete leaks.
///   * Cancel while the Add is still pending Deletes the handle once it arrives.
///   * onCancel on a dead connection is swallowed — cancel still completes.
void main() {
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  /// Builds a complete on-wire AMS/TCP response frame (6-byte wrapper + 32-byte
  /// AMS header + [payload]) using the REAL Phase-1 codecs, stamped with
  /// [invokeId], [commandId], and the AMS-header [errorCode].
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

  /// The AddDeviceNotification (0x06) response payload: `result u32` alone on an
  /// error, `result u32 + handle u32` on success — mirroring the decoder's
  /// short-error-payload rule.
  Uint8List addResponse({required int result, int handle = 0}) {
    if (result != 0) {
      final p = Uint8List(4);
      ByteData.sublistView(p).setUint32(0, result, Endian.little);
      return p;
    }
    final p = Uint8List(8);
    final bd = ByteData.sublistView(p);
    bd.setUint32(0, result, Endian.little);
    bd.setUint32(4, handle, Endian.little);
    return p;
  }

  /// The DeleteDeviceNotification (0x07) response payload: `result u32`.
  Uint8List deleteResponse(int result) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, result, Endian.little);
    return p;
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

  Future<(AdsClient, FakeTransport, AmsConnection)> newClient() async {
    final fake = FakeTransport();
    final conn = AmsConnection(fake, source: source, target: target);
    await conn.connect('fake', 0);
    return (AdsClient(conn, target: target, source: source), fake, conn);
  }

  group('subscribe lifecycle', () {
    test('sends no add before listen (lazy stream)', () async {
      final (client, fake, _) = await newClient();

      final stream = client.subscribe(
        indexGroup: 0x4020,
        indexOffset: 0x10,
        length: 4,
      );

      // Merely creating the stream must send nothing.
      await pumpEventQueue();
      expect(fake.written, isEmpty);

      // Only once a listener attaches is the Add issued.
      stream.listen((_) {});
      await pumpEventQueue();
      expect(fake.written, hasLength(1));
    });

    test('first listen writes one Add with the 40-byte payload', () async {
      final (client, fake, _) = await newClient();

      final stream = client.subscribe(
        indexGroup: 0x4020,
        indexOffset: 0x10,
        length: 4,
        mode: AdsTransmissionMode.serverOnChange,
        cycleTime: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 50),
      );
      stream.listen((_) {});
      await pumpEventQueue();

      expect(fake.written, hasLength(1));
      final frame = fake.written.single;
      expect(
          outboundHeader(frame).commandId, AdsCommandId.addDeviceNotification);

      final payload = outboundPayload(frame);
      expect(payload, hasLength(40)); // 24 fields + 16 reserved
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), 0x4020); // indexGroup
      expect(bd.getUint32(4, Endian.little), 0x10); // indexOffset
      expect(bd.getUint32(8, Endian.little), 4); // length
      expect(bd.getUint32(12, Endian.little),
          AdsTransmissionMode.serverOnChange.code); // mode @12
      // 50ms -> 50000us -> 500000 100ns; 100ms -> 100000us -> 1000000 100ns.
      expect(bd.getUint32(16, Endian.little), 500000); // maxDelay @16
      expect(bd.getUint32(20, Endian.little), 1000000); // cycleTime @20
    });

    test('defaults: serverOnChange mode, zero cycle/maxDelay on the wire',
        () async {
      final (client, fake, _) = await newClient();

      client
          .subscribe(indexGroup: 0x4020, indexOffset: 0, length: 2)
          .listen((_) {});
      await pumpEventQueue();

      final bd = ByteData.sublistView(outboundPayload(fake.written.single));
      expect(bd.getUint32(12, Endian.little),
          AdsTransmissionMode.serverOnChange.code);
      expect(bd.getUint32(16, Endian.little), 0); // maxDelay
      expect(bd.getUint32(20, Endian.little), 0); // cycleTime
    });

    test('onCancel writes one Delete for the handle and completes', () async {
      final (client, fake, _) = await newClient();

      final sub = client
          .subscribe(indexGroup: 0x4020, indexOffset: 0, length: 4)
          .listen((_) {});
      await pumpEventQueue();

      // Resolve the Add with handle 0x2A.
      final addId = outboundHeader(fake.written.single).invokeId;
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResponse(result: 0, handle: 0x2A),
      ));
      await pumpEventQueue();

      // Cancelling issues exactly one Delete (cmd 0x07) for handle 0x2A.
      final cancelFuture = sub.cancel();
      await pumpEventQueue();
      expect(fake.written, hasLength(2));
      final deleteFrame = fake.written[1];
      expect(outboundHeader(deleteFrame).commandId,
          AdsCommandId.deleteDeviceNotification);
      expect(
        ByteData.sublistView(outboundPayload(deleteFrame))
            .getUint32(0, Endian.little),
        0x2A,
      );

      // Feed the Delete response so the round-trip resolves; cancel completes
      // without throwing.
      final delId = outboundHeader(deleteFrame).invokeId;
      fake.feed(buildFrame(
        invokeId: delId,
        commandId: AdsCommandId.deleteDeviceNotification,
        payload: deleteResponse(0),
      ));
      await expectLater(cancelFuture, completes);
    });

    test('an Add failure surfaces via the stream error and leaks no Delete',
        () async {
      final (client, fake, _) = await newClient();

      final errors = <Object>[];
      final sub = client
          .subscribe(indexGroup: 0x4020, indexOffset: 0, length: 4)
          .listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      // Resolve the Add with a device error result (0x0703).
      final addId = outboundHeader(fake.written.single).invokeId;
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResponse(result: 0x0703),
      ));
      await pumpEventQueue();

      expect(
        errors.single,
        isA<AdsException>().having((e) => e.code, 'code', 0x0703),
      );
      // No handle was acquired, so no Delete may leak.
      expect(fake.written, hasLength(1));

      // Cancelling a failed stream still Deletes nothing and never throws.
      await expectLater(sub.cancel(), completes);
      expect(fake.written, hasLength(1));
    });

    test('cancel while the Add is pending deletes the handle once it arrives',
        () async {
      final (client, fake, _) = await newClient();

      final sub = client
          .subscribe(indexGroup: 0x4020, indexOffset: 0, length: 4)
          .listen((_) {});
      await pumpEventQueue();
      expect(fake.written, hasLength(1)); // Add sent, response pending.

      // Cancel BEFORE the Add resolves — handle is still null.
      final cancelFuture = sub.cancel();
      await pumpEventQueue();
      await expectLater(cancelFuture, completes);
      expect(fake.written, hasLength(1)); // no Delete yet — nothing to delete.

      // The Add finally resolves with handle 0x2A; the just-created handle must
      // be released rather than leaked.
      final addId = outboundHeader(fake.written.single).invokeId;
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResponse(result: 0, handle: 0x2A),
      ));
      await pumpEventQueue();

      expect(fake.written, hasLength(2));
      final deleteFrame = fake.written[1];
      expect(outboundHeader(deleteFrame).commandId,
          AdsCommandId.deleteDeviceNotification);
      expect(
        ByteData.sublistView(outboundPayload(deleteFrame))
            .getUint32(0, Endian.little),
        0x2A,
      );

      // Drain the Delete round-trip.
      fake.feed(buildFrame(
        invokeId: outboundHeader(deleteFrame).invokeId,
        commandId: AdsCommandId.deleteDeviceNotification,
        payload: deleteResponse(0),
      ));
      await pumpEventQueue();
    });

    test('onCancel on a dead connection is swallowed (cancel completes)',
        () async {
      final (client, fake, conn) = await newClient();

      final sub = client
          .subscribe(indexGroup: 0x4020, indexOffset: 0, length: 4)
          .listen((_) {}, onError: (_) {});
      await pumpEventQueue();

      // Acquire a real handle first.
      final addId = outboundHeader(fake.written.single).invokeId;
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResponse(result: 0, handle: 0x2A),
      ));
      await pumpEventQueue();

      // Kill the connection: the demux controller is error-closed and the
      // handle invalidated locally. A subsequent Delete would throw
      // 'not connected' — which _deleteQuietly must swallow.
      await conn.close();

      await expectLater(sub.cancel(), completes);
    });
  });
}
