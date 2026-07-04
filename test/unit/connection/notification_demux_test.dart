@Tags(['unit'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/protocol/notifications.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven coverage for the [AmsConnection] notification demux — the
/// correctness core of Phase 5. It exercises the two hazards research flagged for
/// the L4 layer: the first-listen race (synchronous handle registration) and
/// hostile-frame containment (one bad 0x08 frame cannot kill the connection).
/// Everything is scripted through [FakeTransport] — no sockets, no C++ mock.
/// Reaching into `src/` mirrors the sibling `ams_connection_test.dart`: these are
/// same-package unit tests of intentionally package-internal surface.
void main() {
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  /// Builds a complete on-wire AMS/TCP frame using the REAL Phase-1 codecs.
  Uint8List buildFrame({
    required int invokeId,
    required int commandId,
    int stateFlags = AmsStateFlags.response,
    Uint8List? payload,
  }) {
    final body = payload ?? Uint8List(0);
    final ams = AmsHeader(
      targetNetId: source.netId,
      targetPort: source.port,
      sourceNetId: target.netId,
      sourcePort: target.port,
      commandId: commandId,
      stateFlags: stateFlags,
      dataLength: body.length,
      errorCode: 0,
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

  /// The AddDeviceNotification (0x06) response payload: `result u32, handle u32`.
  Uint8List addResp({required int result, required int handle}) {
    final p = Uint8List(8);
    ByteData.sublistView(p)
      ..setUint32(0, result, Endian.little)
      ..setUint32(4, handle, Endian.little);
    return p;
  }

  /// The DeleteDeviceNotification (0x07) response payload: `result u32`.
  Uint8List deleteResp({int result = 0}) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, result, Endian.little);
    return p;
  }

  /// Builds a well-formed 0x08 notification-stream payload from [stamps], each a
  /// `(timestamp, samples)` pair. Mirrors the wire layout parsed by
  /// [parseNotificationStream]: `length u32, stamps u32, per stamp (timestamp
  /// u64, sampleCount u32, per sample (handle u32, size u32, data[size]))`.
  Uint8List notifStream(
    List<({DateTime timestamp, List<({int handle, Uint8List data})> samples})>
        stamps,
  ) {
    final after = BytesBuilder();
    final sc = ByteData(4)..setUint32(0, stamps.length, Endian.little);
    after.add(sc.buffer.asUint8List());
    for (final stamp in stamps) {
      final ft = dateTimeToFiletime(stamp.timestamp);
      final hdr = ByteData(12)
        ..setUint64(0, ft, Endian.little)
        ..setUint32(8, stamp.samples.length, Endian.little);
      after.add(hdr.buffer.asUint8List());
      for (final s in stamp.samples) {
        final sh = ByteData(8)
          ..setUint32(0, s.handle, Endian.little)
          ..setUint32(4, s.data.length, Endian.little);
        after.add(sh.buffer.asUint8List());
        after.add(s.data);
      }
    }
    final afterBytes = after.toBytes();
    final payload = Uint8List(4 + afterBytes.length);
    ByteData.sublistView(payload)
        .setUint32(0, afterBytes.length, Endian.little);
    payload.setRange(4, payload.length, afterBytes);
    return payload;
  }

  /// A 0x08 device-notification frame carrying [payload] (invoke-ID 0).
  Uint8List notifFrame(Uint8List payload) => buildFrame(
        invokeId: 0,
        commandId: AdsCommandId.deviceNotification,
        stateFlags: AmsStateFlags.request,
        payload: payload,
      );

  int outboundInvokeId(Uint8List frame) =>
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength)
          .invokeId;

  AmsConnection newConnection(FakeTransport fake) =>
      AmsConnection(fake, source: source, target: target);

  Uint8List anyAddPayload() => buildAddNotificationPayload(
        indexGroup: 0x4020,
        indexOffset: 0,
        length: 4,
        transMode: AdsTransmissionMode.serverOnChange.code,
        maxDelay100ns: 0,
        cycleTime100ns: 0,
      );

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  final ts = DateTime.utc(2024, 1, 1, 12);

  group('addNotification / synchronous registration', () {
    test('registers the handle and returns it on a success response', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final ctrl = StreamController<AdsNotification>();
      final fut = conn.addNotification(anyAddPayload(), ctrl);
      final id = outboundInvokeId(fake.written.single);

      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResp(result: 0, handle: 0x0777),
      ));

      expect(await fut, 0x0777);
    });

    test(
        'race: a 0x08 for the just-added handle in the SAME chunk as the '
        'Add-response is delivered, not dropped', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final ctrl = StreamController<AdsNotification>();
      final received = <AdsNotification>[];
      ctrl.stream.listen(received.add);

      const handle = 0x1234;
      final fut = conn.addNotification(anyAddPayload(), ctrl);
      final id = outboundInvokeId(fake.written.single);

      // Coalesce the Add-response AND its first notification into ONE inbound
      // chunk. The assembler splits them into two frames dispatched in the same
      // synchronous drain: the 0x08 is processed the microtask BEFORE any
      // await-continuation could run. Only truly synchronous registration (the
      // onResponseSync hook firing inside _onFrame before completer.complete)
      // makes the handle present when the notification is parsed.
      final add = buildFrame(
        invokeId: id,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResp(result: 0, handle: handle),
      );
      final notif = notifFrame(notifStream([
        (
          timestamp: ts,
          samples: [(handle: handle, data: Uint8List.fromList([0xDE, 0xAD]))],
        ),
      ]));
      final chunk = Uint8List(add.length + notif.length)
        ..setRange(0, add.length, add)
        ..setRange(add.length, add.length + notif.length, notif);
      fake.feed(chunk);

      expect(await fut, handle);
      await pump();
      expect(received, hasLength(1),
          reason: 'synchronous registration beats the same-chunk race');
      expect(received.single.handle, handle);
      expect(received.single.data, equals(Uint8List.fromList([0xDE, 0xAD])));
      expect(conn.droppedNotifications, 0);
    });

    test('a non-zero AMS errorCode throws AdsException and registers nothing',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final ctrl = StreamController<AdsNotification>();
      final fut = conn.addNotification(anyAddPayload(), ctrl);
      final id = outboundInvokeId(fake.written.single);

      // AMS-header errorCode non-zero: buildFrame hardcodes errorCode 0, so
      // craft the header directly with a non-zero code.
      final ams = AmsHeader(
        targetNetId: source.netId,
        targetPort: source.port,
        sourceNetId: target.netId,
        sourcePort: target.port,
        commandId: AdsCommandId.addDeviceNotification,
        stateFlags: AmsStateFlags.response,
        dataLength: 0,
        errorCode: 0x0007,
        invokeId: id,
      ).encode();
      final tcp = AmsTcpHeader(length: AmsHeader.byteLength).encode();
      final frame = Uint8List(AmsTcpHeader.byteLength + AmsHeader.byteLength)
        ..setRange(0, AmsTcpHeader.byteLength, tcp)
        ..setRange(AmsTcpHeader.byteLength,
            AmsTcpHeader.byteLength + AmsHeader.byteLength, ams);
      fake.feed(frame);

      await expectLater(fut, throwsA(isA<AdsException>()));
    });

    test('a non-zero decoded result throws AdsException and registers nothing',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final ctrl = StreamController<AdsNotification>();
      final fut = conn.addNotification(anyAddPayload(), ctrl);
      final id = outboundInvokeId(fake.written.single);

      fake.feed(buildFrame(
        invokeId: id,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResp(result: 0x0716, handle: 0),
      ));

      await expectLater(
        fut,
        throwsA(isA<AdsException>().having((e) => e.code, 'code', 0x0716)),
      );
    });
  });

  group('deleteNotification', () {
    test('removes the handle from the demux map and closes the controller',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      const handle = 0x0055;
      final ctrl = StreamController<AdsNotification>();
      final addFut = conn.addNotification(anyAddPayload(), ctrl);
      final addId = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResp(result: 0, handle: handle),
      ));
      await addFut;

      final delFut = conn.deleteNotification(
        handle,
        buildDeleteNotificationPayload(handle: handle),
      );
      final delId = outboundInvokeId(fake.written.last);
      fake.feed(buildFrame(
        invokeId: delId,
        commandId: AdsCommandId.deleteDeviceNotification,
        payload: deleteResp(),
      ));
      await delFut;

      // The controller is closed by deleteNotification.
      expect(ctrl.isClosed, isTrue);

      // A later 0x08 for the deleted handle is dropped (map entry gone) — the
      // stream received nothing and stays closed.
      fake.feed(notifFrame(notifStream([
        (
          timestamp: ts,
          samples: [(handle: handle, data: Uint8List(1))],
        ),
      ])));
      await pump();
      expect(conn.isConnected, isTrue);
    });

    test('does not throw spuriously against a live connection', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      const handle = 0x0099;
      final ctrl = StreamController<AdsNotification>();
      final addFut = conn.addNotification(anyAddPayload(), ctrl);
      final addId = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(
        invokeId: addId,
        commandId: AdsCommandId.addDeviceNotification,
        payload: addResp(result: 0, handle: handle),
      ));
      await addFut;

      final delFut = conn.deleteNotification(
        handle,
        buildDeleteNotificationPayload(handle: handle),
      );
      final delId = outboundInvokeId(fake.written.last);
      fake.feed(buildFrame(
        invokeId: delId,
        commandId: AdsCommandId.deleteDeviceNotification,
        payload: deleteResp(),
      ));

      await expectLater(delFut, completes);
    });
  });
}
