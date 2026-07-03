@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live proof of invoke-ID correlation under on-wire response REORDERING
/// (`--delay-ms`, PROTO-03) and disconnect failure fan-out under a mid-request
/// drop (`--close-after`, TRANS-03), both over a real loopback socket.
///
/// Each test starts its OWN mock with the relevant flag and tears it down, so
/// the two lifecycle behaviours never share a server.
void main() {
  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  test('reorder: correlates reordered responses by invoke-ID', () async {
    // --delay-ms defers response #1 and flushes it LAST, so response #2 arrives
    // FIRST on the wire — deterministically inverting the pipelined pair.
    final server = await startMockServer(args: ['--delay-ms', '80']);
    addTearDown(server.stop);

    final conn = newConnection();
    await conn.connect('127.0.0.1', server.port);

    // Issue TWO requests WITHOUT awaiting between them so they pipeline; if we
    // awaited f1 first there would be nothing to reorder (Pitfall 5). A
    // comfortably-long timeout keeps this a correlation proof, not a timeout.
    final f1 = conn.request(
      AdsCommandId.readDeviceInfo,
      Uint8List(0),
      timeout: const Duration(seconds: 10),
    );
    final f2 = conn.request(
      AdsCommandId.readDeviceInfo,
      Uint8List(0),
      timeout: const Duration(seconds: 10),
    );

    // Each Future resolves its OWN response despite the inverted wire order.
    final r1 = await f1;
    final r2 = await f2;
    expect(decodeReadDeviceInfoResponse(r1).name, equals('Dart ADS Mock'));
    expect(decodeReadDeviceInfoResponse(r2).name, equals('Dart ADS Mock'));

    // The on-wire proof of correlation under reordering: nothing was dropped.
    expect(conn.droppedResponses, equals(0));

    await conn.close();
  });

  test('disconnect: mid-request drop fans out with no hung Future', () async {
    // --close-after 1 closes the socket on the 1st complete inbound request
    // WITHOUT answering it, leaving a pending request that must fan out.
    final server = await startMockServer(args: ['--close-after', '1']);
    addTearDown(server.stop);

    final conn = newConnection();
    await conn.connect('127.0.0.1', server.port);

    // A comfortably-long per-request timeout so the disconnect is provably a
    // CONNECTION error, not a timeout firing.
    final f = conn.request(
      AdsCommandId.readDeviceInfo,
      Uint8List(0),
      timeout: const Duration(seconds: 10),
    );

    // The pending request errors with the typed connection exception (not a
    // timeout), and `done` completes — proving no Future hangs.
    await expectLater(f, throwsA(isA<AdsConnectionException>()));
    await conn.done;
    expect(conn.isConnected, isFalse);
  });
}
