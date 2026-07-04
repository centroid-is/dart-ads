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

    expect(readBack, equals(written),
        reason: 'read must reflect the prior write');
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

  // ---------------------------------------------------------------------------
  // Both ADS error levels, live via the mock's magic index-groups (ERR-01).
  //
  // kErrResultGroup (0xE7700000) -> the mock sets the ADS payload `result` word
  //   to the request indexOffset (payload-result level).
  // kErrAmsGroup    (0xE7700001) -> the mock sets the AMS-header errorCode to
  //   the request indexOffset, checked BEFORE payload decode (AMS-error level).
  //
  // Exercising BOTH proves an error-injection test cannot pass via the payload
  // path alone (threat T-3-02 / research Pitfall 1 warning sign).
  // ---------------------------------------------------------------------------
  const kErrResultGroup = 0xE7700000;
  const kErrAmsGroup = 0xE7700001;

  test('result_error', () async {
    // Payload-`result` level: the mock echoes offset 0x703 into the ADS result
    // word, which the client maps to ADSERR_DEVICE_INVALIDOFFSET.
    final client = await connectClient();

    await expectLater(
      client.read(
        indexGroup: kErrResultGroup,
        indexOffset: 0x703,
        length: 4,
        timeout: requestTimeout,
      ),
      throwsA(
        isA<AdsException>().having((e) => e.code, 'code', equals(0x703)).having(
            (e) => e.name, 'name', equals('ADSERR_DEVICE_INVALIDOFFSET')),
      ),
    );
  });

  test('ams_error', () async {
    // AMS-header `errorCode` level: the mock sets the AMS errorCode to 0x0007,
    // surfaced from the header BEFORE any payload decode. The client maps it to
    // GLOBALERR_MISSING_ROUTE. Asserting it is an AdsException (NOT a transport
    // AdsTimeout/AdsConnection exception) proves the distinct family, live.
    final client = await connectClient();

    await expectLater(
      client.read(
        indexGroup: kErrAmsGroup,
        indexOffset: 0x007,
        length: 4,
        timeout: requestTimeout,
      ),
      throwsA(
        isA<AdsException>()
            .having((e) => e.code, 'code', equals(0x0007))
            .having(
                (e) => e,
                'not a transport error',
                isNot(anyOf(isA<AdsTimeoutException>(),
                    isA<AdsConnectionException>()))),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Sum (batched) commands, live via the rebuilt mock's SUMUP sub-handler
  // (06-02). Each test starts its own mock + connection, so the per-connection
  // store keeps write-back assertions isolated. Every SumResult carries a
  // per-item errorCode; a per-item failure is a VALUE, never a batch throw
  // (SUM-04). Group name 'sum' makes `-n 'sum'` select exactly these tests.
  // ---------------------------------------------------------------------------
  group('sum', () {
    test('read-after-write write-back', () async {
      // SUM-02 + SUM-01: sumWrite N distinct keys, then sumRead the SAME keys
      // and prove each item's data equals what was written — per-item
      // write-back landed in the mock store and survives the round-trip.
      final client = await connectClient();

      const group = 0x4030;
      final writes = <SumWriteRequest>[
        for (var i = 0; i < 4; i++)
          SumWriteRequest(
            indexGroup: group,
            indexOffset: i * 0x10,
            data: Uint8List.fromList(
                [0x10 + i, 0x20 + i, 0x30 + i, 0x40 + i]),
          ),
      ];

      final writeResults =
          await client.sumWrite(writes, timeout: requestTimeout);
      expect(writeResults, hasLength(writes.length));
      expect(writeResults.every((r) => r.isSuccess), isTrue,
          reason: 'every write item must succeed');

      final reads = <SumReadRequest>[
        for (final w in writes)
          SumReadRequest(
            indexGroup: w.indexGroup,
            indexOffset: w.indexOffset,
            length: w.data.length,
          ),
      ];

      final readResults = await client.sumRead(reads, timeout: requestTimeout);
      expect(readResults, hasLength(writes.length));
      for (var i = 0; i < writes.length; i++) {
        expect(readResults[i].isSuccess, isTrue);
        expect(readResults[i].valueOrThrow, equals(writes[i].data),
            reason: 'read-after-sumWrite must reflect item $i write-back');
      }
    });

    test('read batch', () async {
      // SUM-01: sumRead-only of >=3 keys returns per-item success + correct
      // bytes. Seed with single writes (the proven CMD-02 path) so the sumRead
      // is a pure read of pre-existing store contents.
      final client = await connectClient();

      final keys = <(int, int, Uint8List)>[
        (0x4031, 0x00, Uint8List.fromList(const [1, 2, 3, 4])),
        (0x4031, 0x08, Uint8List.fromList(const [9, 8, 7, 6, 5])),
        (0x4032, 0x00, Uint8List.fromList(const [0xAA, 0xBB])),
      ];
      for (final (g, o, d) in keys) {
        await client.write(
            indexGroup: g, indexOffset: o, data: d, timeout: requestTimeout);
      }

      final results = await client.sumRead(<SumReadRequest>[
        for (final (g, o, d) in keys)
          SumReadRequest(indexGroup: g, indexOffset: o, length: d.length),
      ], timeout: requestTimeout);

      expect(results, hasLength(keys.length));
      for (var i = 0; i < keys.length; i++) {
        expect(results[i].isSuccess, isTrue);
        expect(results[i].valueOrThrow, equals(keys[i].$3));
      }
    });

    test('read_write batch', () async {
      // SUM-03: sumReadWrite writes-then-reads each item in one frame; the mock
      // returns each item's data at its RETURNED length. One item requests
      // fewer bytes back than it writes, proving the decoder slices by the
      // returned length, not the requested one.
      final client = await connectClient();

      final full =
          Uint8List.fromList(const [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]);
      final items = <SumReadWriteRequest>[
        SumReadWriteRequest(
            indexGroup: 0x4040,
            indexOffset: 0x00,
            readLength: full.length,
            writeData: full),
        SumReadWriteRequest(
            indexGroup: 0x4040,
            indexOffset: 0x10,
            readLength: 2, // fewer bytes back than written -> returned len 2
            writeData: full),
        SumReadWriteRequest(
            indexGroup: 0x4041,
            indexOffset: 0x00,
            readLength: 3,
            writeData: Uint8List.fromList(const [0xDE, 0xAD, 0xBE])),
      ];

      final results = await client.sumReadWrite(items, timeout: requestTimeout);
      expect(results, hasLength(items.length));
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(results[0].valueOrThrow, equals(full));
      expect(results[1].valueOrThrow, equals(full.sublist(0, 2)),
          reason: 'returned length (2) < requested slice must be honored');
      expect(results[2].valueOrThrow,
          equals(Uint8List.fromList(const [0xDE, 0xAD, 0xBE])));
    });
  });
}
