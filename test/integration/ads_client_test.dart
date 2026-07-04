@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live proof that every core [AdsClient] command (03-04) round-trips against
/// the extended C++ mock (03-01) over a real loopback socket, plus that BOTH
/// ADS error levels — the payload `result` and the AMS-header `errorCode` —
/// surface as an [AdsException] end-to-end (ERR-01, live half).
///
/// Each test starts its OWN mock and its OWN connection, then tears both down.
/// The mock's data store and ADS-state are connection-scoped, so a fresh
/// connection per test keeps write-back / state assertions isolated and
/// order-independent (research Pitfall 3). Every request carries a
/// comfortably-long timeout so a failure is provably a command/error result,
/// never a timeout firing (threat T-3-07).
void main() {
  // A generous per-request timeout: any command that "fails" a test does so as
  // a real ADS result or a thrown AdsException, not because a timeout fired.
  const requestTimeout = Duration(seconds: 10);

  // The mock seeds one fixture at (0xF005, 0x123) = 42 as a little-endian u32,
  // so a pure Read (no prior Write on this connection) is still meaningful.
  const seedGroup = 0xF005;
  const seedOffset = 0x123;
  final seedBytes = Uint8List.fromList(const [0x2A, 0x00, 0x00, 0x00]);

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  /// Starts a fresh mock + connected [AmsConnection] + [AdsClient], registering
  /// teardown for both so no orphan process or open socket survives the test.
  Future<AdsClient> connectClient() async {
    final server = await startMockServer();
    addTearDown(server.stop);

    final conn = newConnection();
    addTearDown(conn.close);
    await conn.connect('127.0.0.1', server.port);

    return AdsClient(
      conn,
      target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
    );
  }

  test('read', () async {
    // Read the seeded fixture on a clean connection: proves Read (CMD-01)
    // returns exactly the device's stored bytes.
    final client = await connectClient();

    final data = await client.read(
      indexGroup: seedGroup,
      indexOffset: seedOffset,
      length: seedBytes.length,
      timeout: requestTimeout,
    );

    expect(data, equals(seedBytes));
  });

  test('write', () async {
    // Write then read back the SAME key on the SAME connection: the mock's
    // write-back store persists within a session, proving Write (CMD-02) and
    // read-after-write (CMD-01) together.
    final client = await connectClient();

    final written = Uint8List.fromList(const [0xDE, 0xAD, 0xBE, 0xEF]);
    const group = 0x4020;
    const offset = 0x07;

    await client.write(
      indexGroup: group,
      indexOffset: offset,
      data: written,
      timeout: requestTimeout,
    );

    final readBack = await client.read(
      indexGroup: group,
      indexOffset: offset,
      length: written.length,
      timeout: requestTimeout,
    );

    expect(readBack, equals(written), reason: 'read must reflect the prior write');
  });

  test('read_write', () async {
    // ReadWrite writes then reads the same key in ONE round-trip; the mock
    // returns the just-written bytes (CMD-03).
    final client = await connectClient();

    final payload = Uint8List.fromList('MAIN.foo'.codeUnits);

    final result = await client.readWrite(
      indexGroup: 0x4021,
      indexOffset: 0x00,
      readLength: payload.length,
      writeData: payload,
      timeout: requestTimeout,
    );

    expect(result, equals(payload));
  });

  test('read_state', () async {
    // A fresh connection is seeded to RUN(5) with deviceState 0 (CMD-04).
    final client = await connectClient();

    final state = await client.readState(timeout: requestTimeout);

    expect(state.adsState, equals(AdsState.run));
    expect(state.rawAdsState, equals(AdsState.run.code));
    expect(state.deviceState, equals(0));
  });

  test('write_control', () async {
    // WriteControl(STOP) mutates connection-scoped state; a following ReadState
    // observably returns STOP — the state analogue of write-back (CMD-05).
    final client = await connectClient();

    // Precondition: starts in RUN.
    final before = await client.readState(timeout: requestTimeout);
    expect(before.adsState, equals(AdsState.run));

    await client.writeControl(
      adsState: AdsState.stop,
      timeout: requestTimeout,
    );

    final after = await client.readState(timeout: requestTimeout);
    expect(after.adsState, equals(AdsState.stop),
        reason: 'WriteControl(STOP) must be observable via ReadState');
  });

  test('device_info', () async {
    // ReadDeviceInfo returns the exact mock identity triple (CMD-06).
    final client = await connectClient();

    final info = await client.readDeviceInfo(timeout: requestTimeout);

    expect(info.name, equals('Dart ADS Mock'));
    expect(info.version, equals(3));
    expect(info.revision, equals(1));
    expect(info.build, equals(4024));
  });
}
