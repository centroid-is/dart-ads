@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live end-to-end proof of the transport + connection stack against the C++
/// mock over a real loopback socket (TRANS-01, TEST-03).
///
/// These are the on-wire counterparts of Plan 02-03's `FakeTransport` unit
/// tests: a real `dart:io` [SocketTransport], real TCP segmentation, and a real
/// mock child process launched through the shared [startMockServer] helper on an
/// ephemeral port with a `LISTENING` handshake (never a sleep).
void main() {
  late MockServer server;

  setUpAll(() async {
    // No extra args => the mock runs in its normal request/response mode.
    server = await startMockServer();
  });

  tearDownAll(() async {
    // Guard against orphan mock processes: SIGTERM + await exit.
    await server.stop();
  });

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  test('connects and round-trips ReadDeviceInfo', () async {
    final conn = newConnection();
    await conn.connect('127.0.0.1', server.port);
    expect(conn.isConnected, isTrue);

    // ReadDeviceInfo carries an empty ADS payload. request() now resolves to a
    // record; the decoder takes the payload slice.
    final resp = await conn.request(
      AdsCommandId.readDeviceInfo,
      Uint8List(0),
    );

    // A real frame traversed SocketTransport -> FrameAssembler -> correlation.
    final info = decodeReadDeviceInfoResponse(resp.payload);
    expect(info.name, equals('Dart ADS Mock'));

    await conn.close();
  });

  test('close completes done and flips isConnected', () async {
    final conn = newConnection();
    await conn.connect('127.0.0.1', server.port);

    // Do a real round-trip first so close() tears down a live, used connection.
    final resp = await conn.request(
      AdsCommandId.readDeviceInfo,
      Uint8List(0),
    );
    expect(decodeReadDeviceInfoResponse(resp.payload).name, isNotEmpty);
    expect(conn.isConnected, isTrue);

    await conn.close();

    // Clean teardown: done resolves and the connection reports disconnected.
    await conn.done;
    expect(conn.isConnected, isFalse);
  });
}
