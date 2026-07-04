@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live proof of the Phase-4 goal against the C++ mock (which stands in for a
/// local TwinCAT router unchanged):
///
///   * ROUTE01 — the SAME command sequence succeeds through `DirectTarget` AND
///     `LocalRouterTarget`; only the `TransportTarget` passed to
///     `router.connect(...)` differs, never a command-level call (ROUTE-01).
///   * ERR02 — a direct-mode request that never gets a reply surfaces as an
///     `AdsException`-family error carrying code `0x0745` (1861) naming the
///     stamped source NetId, NEVER a bare `AdsTimeoutException` (ERR-02); and a
///     local-router-mode timeout stays an un-enriched `AdsTimeoutException`
///     (no false enrichment).
///
/// The mock is single-threaded (one connection served to close before the next
/// is accepted), so the two ROUTE01 modes each get their OWN mock to keep both
/// connections open concurrently without serialising the accept loop. The
/// ERR02 timeout is forced with `--delay-ms`, which holds a connection's only
/// response until the socket closes — a genuine per-request timeout, distinct
/// from the `--close-after` disconnect path.
void main() {
  // A generous per-request timeout for the success path so a failing assertion
  // is provably a command/result mismatch, never a timeout firing.
  const requestTimeout = Duration(seconds: 10);

  // The mock seeds one fixture at (0x4025, 0x123) = 42 (LE u32).
  const seedGroup = 0x4025;
  const seedOffset = 0x123;
  final seedBytes = Uint8List.fromList(const [0x2A, 0x00, 0x00, 0x00]);

  final targetNetId = AmsNetId.parse('192.168.0.1.1.1');
  final localNetId = AmsNetId.parse('192.168.0.100.1.1');

  /// The IDENTICAL command sequence exercised through both transport modes.
  /// It takes only an [AdsClient]: the command-level calls do not know or care
  /// which [TransportTarget] produced the client (ROUTE-01 is structural here).
  Future<({Uint8List seed, Uint8List readBack, AdsState state})> runSequence(
    AdsClient client,
  ) async {
    final seed = await client.read(
      indexGroup: seedGroup,
      indexOffset: seedOffset,
      length: seedBytes.length,
      timeout: requestTimeout,
    );

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

    final state = (await client.readState(timeout: requestTimeout)).adsState;
    return (seed: seed, readBack: readBack, state: state);
  }

  group('ROUTE01', () {
    test('same command sequence succeeds through Direct AND LocalRouter mode',
        () async {
      // Separate mocks so both mode connections can stay open at once against
      // the single-threaded server (see file header).
      final directServer = await startMockServer();
      addTearDown(directServer.stop);
      final localServer = await startMockServer();
      addTearDown(localServer.stop);

      final router = AmsRouter()..setLocalAddress(localNetId);
      addTearDown(router.close);
      // DirectTarget resolves via the local route table first (0x0007 gate).
      expect(router.addRoute(targetNetId, '127.0.0.1', port: directServer.port),
          0);

      final directClient = await router.connect(
        targetNetId,
        AmsPort.plcTc3,
        mode: DirectTarget('127.0.0.1', port: directServer.port),
      );
      addTearDown(directClient.connection.close);
      final directResult = await runSequence(directClient);

      final localClient = await router.connect(
        targetNetId,
        AmsPort.plcTc3,
        mode: LocalRouterTarget(host: '127.0.0.1', port: localServer.port),
      );
      addTearDown(localClient.connection.close);
      final localResult = await runSequence(localClient);

      // The two modes yield IDENTICAL results (ROUTE-01: zero command change).
      expect(directResult.seed, equals(localResult.seed));
      expect(directResult.readBack, equals(localResult.readBack));
      expect(directResult.state, equals(localResult.state));

      // ...and the concrete values are the expected device data both ways.
      expect(directResult.seed, equals(seedBytes));
      expect(directResult.readBack,
          equals(Uint8List.fromList(const [0xDE, 0xAD, 0xBE, 0xEF])));
      expect(directResult.state, equals(AdsState.run));

      // The router stamped distinct 30000+ local SOURCE ports, one per connect.
      expect(directClient.source.port, inInclusiveRange(30000, 30127));
      expect(localClient.source.port, inInclusiveRange(30000, 30127));
      expect(directClient.source.port, isNot(equals(localClient.source.port)));
    });
  });

  group('ERR02', () {
    // `--delay-ms 1` defers a connection's only response until the socket
    // closes, so a single read never gets its reply -> a real per-request
    // timeout (the missing-reverse-route symptom in direct mode).
    const shortTimeout = Duration(milliseconds: 400);

    test('direct-mode timeout is enriched to 0x0745 naming the source NetId',
        () async {
      final server = await startMockServer(args: ['--delay-ms', '1']);
      addTearDown(server.stop);

      final router = AmsRouter()..setLocalAddress(localNetId);
      addTearDown(router.close);
      expect(router.addRoute(targetNetId, '127.0.0.1', port: server.port), 0);

      final client = await router.connect(
        targetNetId,
        AmsPort.plcTc3,
        mode: DirectTarget('127.0.0.1', port: server.port),
      );
      addTearDown(client.connection.close);

      await expectLater(
        client.read(
          indexGroup: seedGroup,
          indexOffset: seedOffset,
          length: 4,
          timeout: shortTimeout,
        ),
        throwsA(
          allOf(
            // Enriched to the ADS error family, carrying 1861/0x0745.
            isA<AdsException>().having((e) => e.code, 'code', equals(0x0745)),
            // A routing exception whose message names the SOURCE NetId + fix.
            isA<AdsRoutingException>()
                .having((e) => e.netId, 'netId', equals(localNetId))
                .having((e) => e.toString(), 'message names source NetId',
                    contains(localNetId.dotted)),
            // Explicitly NOT a bare transport timeout (ERR-02 core guarantee).
            isNot(isA<AdsTimeoutException>()),
          ),
        ),
      );
    });

    test('local-router-mode timeout stays a bare AdsTimeoutException',
        () async {
      // Same unanswered-request staging, but LocalRouterTarget must NOT enrich:
      // a real router returns its own errors, so no false 0x0745 (T-4-02).
      final server = await startMockServer(args: ['--delay-ms', '1']);
      addTearDown(server.stop);

      final router = AmsRouter()..setLocalAddress(localNetId);
      addTearDown(router.close);

      final client = await router.connect(
        targetNetId,
        AmsPort.plcTc3,
        mode: LocalRouterTarget(host: '127.0.0.1', port: server.port),
      );
      addTearDown(client.connection.close);

      await expectLater(
        client.read(
          indexGroup: seedGroup,
          indexOffset: seedOffset,
          length: 4,
          timeout: shortTimeout,
        ),
        throwsA(
          allOf(
            isA<AdsTimeoutException>(),
            // NOT enriched into the ADS-error family in local-router mode.
            isNot(isA<AdsException>()),
          ),
        ),
      );
    });
  });
}
