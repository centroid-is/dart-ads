@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

// =============================================================================
// C++ AdsLibTest parity port — Phase 3 slice of TEST-05.
//
// Each `group(...)` below is named EXACTLY after its Beckhoff C++ counterpart in
// `third_party/ADS/AdsLibTest/main.cpp` (struct TestAds / TestAdsPerformance) so
// the Phase 9 parity audit can confirm coverage MECHANICALLY (grep the group
// names against the C++ method names). The ten Phase-3-applicable scenarios are:
//
//   testAdsReadReqEx2            (main.cpp L333)  core Read (+ write-then-read loop)
//   testAdsReadReqEx2LargeBuffer (main.cpp L427)  8192-byte read round-trip
//   testAdsReadDeviceInfoReqEx   (main.cpp L456)  device identity triple
//   testAdsReadStateReqEx        (main.cpp L504)  ADS run state
//   testAdsReadWriteReqEx2       (main.cpp L548)  combined write+read round-trip
//   testAdsWriteReqEx            (main.cpp L698)  Write then read-back loop
//   testAdsWriteControlReqEx     (main.cpp L778)  stateful STOP/RUN control
//   testAdsTimeout               (main.cpp L943)  request that never gets a reply
//   testLargeFrames              (main.cpp L992)  large-frame round-trip
//   testParallelReadAndWrite     (main.cpp L1020) many concurrent operations
//
// -- Adaptation rules (C++ port-handle semantics -> Dart connection lifecycle) --
//
//   * PORT HANDLES -> CONNECTION LIFECYCLE. The C++ scenarios open/close AdsLib
//     PORT handles (AdsPortOpenEx / AdsPortCloseEx) and assert port-level error
//     cases (ADSERR_CLIENT_PORTNOTOPEN, ADSERR_CLIENT_NOAMSADDR, ...). Dart has
//     no port-handle concept: a connection is either connected or it is not, so
//     those port-handle error cases map onto the connection lifecycle and are
//     COVERED-BY-EQUIVALENT in the Phase-2 `ams_connection_live_test`
//     (connect / close / disconnect fan-out). They are intentionally NOT
//     re-asserted here.
//
//   * UNKNOWN AmsAddr / GLOBALERR_MISSING_ROUTE -> PHASE 4 (N/A here). The C++
//     "provide unknown AmsAddr" cases exercise the router's route table, which
//     is a Phase-4 concern. Not applicable to the Phase-3 command surface.
//
//   * INVALID group/offset (ADSERR_DEVICE_SRVNOTSUPP 0x701) -> INJECTABLE. The
//     C++ "invalid indexGroup" case is reproduced against the mock's magic
//     error group kErrResultGroup (0xE7700000) with the request indexOffset
//     selecting the code (0x701) — the offset->code trick the mock provides.
//
//   * IDENTITY VALUES differ from upstream by design. The C++ mock answers with
//     Beckhoff's own identities ('Plc30 App', build 1711+); our C++ mock server
//     (test_harness/mock_server.cpp) answers with the project fixtures
//     ('Dart ADS Mock', v3.1 build 4024, ADSSTATE_RUN). We assert OUR fixtures.
//
// Store isolation: the mock's data store + ADS-state are connection-scoped, so
// each group takes a FRESH mock + connection (via `connectClient`) and every
// request carries a comfortably-long timeout so a failing assertion is provably
// a command/error result, never a timeout firing (threat T-3-07).
// =============================================================================

void main() {
  // C++ NUM_TEST_LOOPS is 100; a smaller loop keeps the live socket suite fast
  // while still proving the write-back store / correlation across many round
  // trips on one connection.
  const numTestLoops = 10;

  // A generous per-request timeout: any command that "fails" a parity test does
  // so as a real ADS result, not because a timeout fired (threat T-3-07).
  const requestTimeout = Duration(seconds: 10);

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  /// Starts a fresh mock + connected [AmsConnection] + [AdsClient], registering
  /// teardown for both so no orphan process or open socket survives the group.
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

  /// Returns a fresh copy of [bytes] with every byte bit-flipped (the Dart
  /// analogue of the C++ `outBuffer = ~outBuffer` iteration step).
  Uint8List flip(Uint8List bytes) =>
      Uint8List.fromList([for (final b in bytes) (~b) & 0xFF]);

  // The mock's magic error group: a request to (kErrResultGroup, offset) makes
  // the ADS payload `result` word equal `offset` (the offset->code trick).
  const kErrResultGroup = 0xE7700000;

  // ---------------------------------------------------------------------------
  group('testAdsReadReqEx2', () {
    test('write-then-read loop + invalid-group SRVNOTSUPP', () async {
      // C++ (L333): write outBuffer=0 at (0x4020,0), then NUM_TEST_LOOPS reads,
      // asserting bytesRead == sizeof and value == 0 each iteration; plus the
      // "invalid indexGroup -> ADSERR_DEVICE_SRVNOTSUPP" case.
      final client = await connectClient();
      const group = 0x4020;
      const offset = 0x00;
      final zero = Uint8List.fromList(const [0, 0, 0, 0]);

      await client.write(
        indexGroup: group,
        indexOffset: offset,
        data: zero,
        timeout: requestTimeout,
      );

      for (var i = 0; i < numTestLoops; i++) {
        final buffer = await client.read(
          indexGroup: group,
          indexOffset: offset,
          length: zero.length,
          timeout: requestTimeout,
        );
        expect(buffer.length, equals(zero.length), reason: 'iteration $i');
        expect(buffer, equals(zero), reason: 'iteration $i');
      }

      // C++ "provide invalid indexGroup" -> ADSERR_DEVICE_SRVNOTSUPP (0x701),
      // reproduced via the mock's offset->code error injection.
      await expectLater(
        client.read(
          indexGroup: kErrResultGroup,
          indexOffset: 0x701,
          length: 4,
          timeout: requestTimeout,
        ),
        throwsA(isA<AdsException>()
            .having((e) => e.code, 'code', equals(0x701))
            .having((e) => e.name, 'name', equals('ADSERR_DEVICE_SRVNOTSUPP'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsReadReqEx2LargeBuffer', () {
    test('8192-byte round-trip', () async {
      // C++ (L427): read an 8192-byte buffer and assert bytesRead == 8192.
      // Adapted: write 8192 deterministic bytes, read them back, assert both the
      // length and the exact contents (a strictly stronger check than the C++,
      // which only asserts the byte count).
      final client = await connectClient();
      const group = 0xF005;
      const offset = 0x8192;
      final payload =
          Uint8List.fromList([for (var i = 0; i < 8192; i++) (i * 31) & 0xFF]);

      await client.write(
        indexGroup: group,
        indexOffset: offset,
        data: payload,
        timeout: requestTimeout,
      );

      final readBack = await client.read(
        indexGroup: group,
        indexOffset: offset,
        length: payload.length,
        timeout: requestTimeout,
      );

      expect(readBack.length, equals(8192));
      expect(readBack, equals(payload));
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsReadDeviceInfoReqEx', () {
    test('identity triple over a loop', () async {
      // C++ (L456): loop readDeviceInfo asserting the version/revision/build/name.
      // Our mock's fixtures are v3.1 build 4024, name 'Dart ADS Mock'.
      final client = await connectClient();

      for (var i = 0; i < numTestLoops; i++) {
        final info = await client.readDeviceInfo(timeout: requestTimeout);
        expect(info.version, equals(3), reason: 'iteration $i');
        expect(info.revision, equals(1), reason: 'iteration $i');
        expect(info.build, equals(4024), reason: 'iteration $i');
        expect(info.name, equals('Dart ADS Mock'), reason: 'iteration $i');
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsReadStateReqEx', () {
    test('run state, device state 0', () async {
      // C++ (L504): assert adsState == ADSSTATE_RUN and devState == 0.
      final client = await connectClient();

      final state = await client.readState(timeout: requestTimeout);
      expect(state.adsState, equals(AdsState.run));
      expect(state.rawAdsState, equals(AdsState.run.code));
      expect(state.deviceState, equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsReadWriteReqEx2', () {
    test('combined write+read loop with a flipping value', () async {
      // C++ (L548): resolve a handle then loop write+read on it, asserting the
      // read equals the just-written value and flipping (~outBuffer) each pass.
      // Adapted: ReadWrite writes then reads back the SAME key in one round-trip
      // (the mock's write-then-read semantics), asserting the returned bytes
      // equal the written bytes; the value flips each iteration.
      final client = await connectClient();
      const group = 0xF005;
      const offset = 0x4247; // 'MAIN.byByte' analogue
      var value = Uint8List.fromList(const [0xDE, 0xAD, 0xBE, 0xEF]);

      for (var i = 0; i < numTestLoops; i++) {
        final result = await client.readWrite(
          indexGroup: group,
          indexOffset: offset,
          readLength: value.length,
          writeData: value,
          timeout: requestTimeout,
        );
        expect(result.length, equals(value.length), reason: 'iteration $i');
        expect(result, equals(value), reason: 'iteration $i');
        value = flip(value);
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsWriteReqEx', () {
    test('write then read-back loop with a flipping value', () async {
      // C++ (L698): write then read the same handle in a loop, asserting the
      // read equals the written value (flipping each iteration).
      final client = await connectClient();
      const group = 0xF005;
      const offset = 0x0042;
      var value = Uint8List.fromList(const [0x01, 0x23, 0x45, 0x67]);

      for (var i = 0; i < numTestLoops; i++) {
        await client.write(
          indexGroup: group,
          indexOffset: offset,
          data: value,
          timeout: requestTimeout,
        );
        final readBack = await client.read(
          indexGroup: group,
          indexOffset: offset,
          length: value.length,
          timeout: requestTimeout,
        );
        expect(readBack, equals(value), reason: 'iteration $i');
        value = flip(value);
      }
    });
  });

  // ---------------------------------------------------------------------------
  group('testAdsWriteControlReqEx', () {
    test('STOP/RUN control observed via ReadState', () async {
      // C++ (L778): loop WriteControl(STOP)->ReadState==STOP and
      // WriteControl(RUN)->ReadState==RUN, proving the state is stateful.
      final client = await connectClient();

      for (var i = 0; i < numTestLoops; i++) {
        await client.writeControl(
          adsState: AdsState.stop,
          timeout: requestTimeout,
        );
        final stopped = await client.readState(timeout: requestTimeout);
        expect(stopped.adsState, equals(AdsState.stop), reason: 'iteration $i');

        await client.writeControl(
          adsState: AdsState.run,
          timeout: requestTimeout,
        );
        final running = await client.readState(timeout: requestTimeout);
        expect(running.adsState, equals(AdsState.run), reason: 'iteration $i');
      }
    });
  });
}
