@Tags(['unit'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// FakeTransport-driven behavioural coverage for [AmsConnection] — the L4
/// correctness core (correlation, reorder, timeout, disconnect fan-out, and the
/// cmd-0x08 notification demux). No sockets, no C++ mock: everything is scripted
/// through [FakeTransport.feed]/[FakeTransport.simulateDisconnect]. Reaching into
/// `src/` is acceptable — these are same-package unit tests of intentionally
/// package-internal surface the curated barrel does not export.
void main() {
  // Arbitrary but valid AMS addressing for the connection under test.
  final netId = AmsNetId.parse('192.168.0.1.1.1');
  final source = AmsAddr(netId, 852);
  final target = AmsAddr(netId, 851);

  /// Builds a complete on-wire AMS/TCP frame (6-byte wrapper + 32-byte AMS
  /// header + payload) using the REAL Phase-1 codecs, stamped with [invokeId]
  /// and [commandId]. Used to script server→client responses / notifications.
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

  /// Decodes the invoke-ID the connection stamped into an outbound frame.
  int outboundInvokeId(Uint8List frame) =>
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength)
          .invokeId;

  AmsConnection newConnection(FakeTransport fake) =>
      AmsConnection(fake, source: source, target: target);

  /// Yields to the event loop so a fed inbound frame is processed.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('correlation', () {
    test('two pipelined requests each resolve to their own correct response',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final respA = Uint8List.fromList([1, 2, 3]);
      final respB = Uint8List.fromList([4, 5, 6]);

      // Pipeline: no await between the two request() calls.
      final f1 = conn.request(0x02, Uint8List.fromList([0xAA]));
      final f2 = conn.request(0x02, Uint8List.fromList([0xBB]));

      expect(fake.written, hasLength(2));
      final id1 = outboundInvokeId(fake.written[0]);
      final id2 = outboundInvokeId(fake.written[1]);
      expect(id1, 1, reason: 'invoke-IDs are monotonic from 1');
      expect(id2, 2);

      fake.feed(buildFrame(invokeId: id1, commandId: 0x02, payload: respA));
      fake.feed(buildFrame(invokeId: id2, commandId: 0x02, payload: respB));

      // request() now resolves to a record: the surfaced AMS-header errorCode
      // (0 on a normal response, via buildFrame's default) plus the payload.
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.payload, equals(respA));
      expect(r2.payload, equals(respB));
      expect(r1.errorCode, 0,
          reason: 'success response carries AMS errorCode 0');
      expect(r2.errorCode, 0);
      expect(conn.droppedResponses, 0);
    });
  });

  group('reorder', () {
    test('responses arriving out of order still resolve the correct request',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final respA = Uint8List.fromList([10]);
      final respB = Uint8List.fromList([20]);

      final f1 = conn.request(0x02, Uint8List(0));
      final f2 = conn.request(0x02, Uint8List(0));
      final id1 = outboundInvokeId(fake.written[0]);
      final id2 = outboundInvokeId(fake.written[1]);

      // Feed response #2 BEFORE response #1 — correlation keys on invoke-ID.
      fake.feed(buildFrame(invokeId: id2, commandId: 0x02, payload: respB));
      fake.feed(buildFrame(invokeId: id1, commandId: 0x02, payload: respA));

      expect((await f1).payload, equals(respA));
      expect((await f2).payload, equals(respB));
      expect(conn.droppedResponses, 0);
    });
  });

  group('timeout', () {
    test('a request with no reply fails with AdsTimeoutException, no leak',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final f = conn.request(
        0x02,
        Uint8List(0),
        timeout: const Duration(milliseconds: 20),
      );
      final id = outboundInvokeId(fake.written.single);

      await expectLater(f, throwsA(isA<AdsTimeoutException>()));

      // No leak: the pending entry was removed by the timeout, so a LATE
      // response is counted as dropped (not delivered) and never throws.
      fake.feed(buildFrame(invokeId: id, commandId: 0x02));
      await pump();
      expect(conn.droppedResponses, 1);
    });
  });

  group('disconnect', () {
    test('errors every pending with AdsConnectionException, single-shot',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final f1 = conn.request(0x02, Uint8List(0));
      final f2 = conn.request(0x02, Uint8List(0));

      final settled = Future.wait<void>([
        expectLater(f1, throwsA(isA<AdsConnectionException>())),
        expectLater(f2, throwsA(isA<AdsConnectionException>())),
      ]);

      fake.simulateDisconnect(StateError('peer reset'));
      await settled;

      await conn.done; // completes on fan-out
      expect(conn.isConnected, isFalse);

      // Single-shot: a following close()/teardown is a no-op — no
      // "Bad state: Future already completed".
      await conn.close();
      await conn.done;
    });

    test('clean FIN (onDone) also fans out and completes done', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final f = conn.request(0x02, Uint8List(0));
      final expectation =
          expectLater(f, throwsA(isA<AdsConnectionException>()));

      fake.simulateDisconnect(); // no arg → clean close → onDone
      await expectation;
      await conn.done;
      expect(conn.isConnected, isFalse);
    });
  });

  group('lifecycle guards', () {
    test('double connect() throws StateError and leaves the connection usable',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      // Regression (WR-02): a second connect() used to open a fresh socket
      // and THEN die on the late-final assembler, leaking the socket.
      await expectLater(conn.connect('fake', 0), throwsStateError);
      expect(conn.isConnected, isTrue);

      // The original connection still works end-to-end.
      final resp = Uint8List.fromList([3]);
      final f = conn.request(0x02, Uint8List(0));
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(invokeId: id, commandId: 0x02, payload: resp));
      expect((await f).payload, equals(resp));
    });

    test('connect() after close() throws StateError', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);
      await conn.close();

      await expectLater(conn.connect('fake', 0), throwsStateError);
      expect(conn.isConnected, isFalse);
    });
  });

  group('invoke-id wrap', () {
    test('allocation skips an ID still in flight after wrap — no overwrite',
        () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      // Drive the counter to the wrap point: request A takes 0xFFFFFFFF and
      // stays in flight (no response yet); the counter wraps to 1 (never 0).
      conn.debugNextInvokeId = 0xFFFFFFFF;
      final fA = conn.request(0x02, Uint8List(0));
      expect(outboundInvokeId(fake.written[0]), 0xFFFFFFFF);

      // Simulate a full wrap landing back on the in-flight ID. Regression
      // (WR-01): allocation used to hand out 0xFFFFFFFF again, overwriting
      // the live pending entry and permanently hanging request B's Future.
      // It must skip to the next free ID instead.
      conn.debugNextInvokeId = 0xFFFFFFFF;
      final fB = conn.request(0x02, Uint8List(0));
      expect(outboundInvokeId(fake.written[1]), 1,
          reason:
              '0xFFFFFFFF is still pending, 0 is reserved — next free is 1');

      // Both requests still resolve to their own responses.
      final respA = Uint8List.fromList([1]);
      final respB = Uint8List.fromList([2]);
      fake.feed(
          buildFrame(invokeId: 0xFFFFFFFF, commandId: 0x02, payload: respA));
      fake.feed(buildFrame(invokeId: 1, commandId: 0x02, payload: respB));
      expect((await fA).payload, equals(respA));
      expect((await fB).payload, equals(respB));
      expect(conn.droppedResponses, 0);
    });
  });

  group('encode throw', () {
    test(
        'a sync ArgumentError from encode leaves no pending state behind '
        '(no armed timer, no unhandled async error)', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      // 0x10000 is outside u16, so AmsHeader.encode's range check throws a
      // SYNCHRONOUS ArgumentError. Regression (CR-01): the pending entry used
      // to be registered before the frame was built, leaving an orphaned
      // completer whose timer later fired an unhandled async error.
      expect(
        () => conn.request(
          0x10000,
          Uint8List(0),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsArgumentError,
      );
      expect(fake.written, isEmpty, reason: 'nothing was sent');

      // Outlive the would-be timeout window: with the leak, the orphaned
      // timer fires here and the unhandled async error fails this test.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // The connection is still fully usable and correlation is unharmed.
      final resp = Uint8List.fromList([7]);
      final f = conn.request(0x02, Uint8List(0));
      final id = outboundInvokeId(fake.written.single);
      fake.feed(buildFrame(invokeId: id, commandId: 0x02, payload: resp));
      expect((await f).payload, equals(resp));
      expect(conn.droppedResponses, 0);
    });
  });

  group('notification', () {
    test('cmd 0x08 frame routes to demux, not the pending map', () async {
      final fake = FakeTransport();
      final conn = newConnection(fake);
      await conn.connect('fake', 0);

      final resp = Uint8List.fromList([9]);
      final f = conn.request(0x02, Uint8List(0));
      final id = outboundInvokeId(fake.written.single);

      // A device-notification frame carries cmd 0x08 and invoke-ID 0. The 0x08
      // branch now PARSES its payload, so it must be a well-formed (here empty:
      // length=4, stamps=0) notification stream rather than a bare placeholder.
      final emptyStream = Uint8List(8);
      ByteData.sublistView(emptyStream).setUint32(0, 4, Endian.little);
      fake.feed(buildFrame(
        invokeId: 0,
        commandId: AdsCommandId.deviceNotification,
        stateFlags: AmsStateFlags.request,
        payload: emptyStream,
      ));
      await pump();

      expect(conn.notificationFrames, 1);
      expect(conn.droppedResponses, 0,
          reason: 'notifications bypass the correlation map');

      // The pending request is untouched — its real response still resolves.
      fake.feed(buildFrame(invokeId: id, commandId: 0x02, payload: resp));
      expect((await f).payload, equals(resp));
      expect(conn.droppedResponses, 0);
    });
  });
}
