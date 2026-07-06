@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live handle-lifecycle proof (SYM-01) against the C++ mock (07-03): resolve a
/// symbol by name, read/write by handle, release, and — the load-bearing
/// evidence — prove no handle leaks across N cycles and that a stale handle is
/// rejected.
///
/// PARITY NOTE: No C++ AdsLibTest symbol scenario exists — flagged for the
/// Phase 9 parity audit; this is NOT TEST-05 coverage. Our own coverage exceeds
/// the C++ suite for symbol access (07-RESEARCH, C++ Test Parity).
///
/// Each test starts its OWN mock and OWN connection, then tears both down. The
/// mock's value store AND its sym-handle table are connection-scoped, so a fresh
/// connection per test keeps the leak-proof baseline at 0 and every assertion
/// order-independent (mirrors ads_client_test.dart). Every request carries a
/// comfortably-long timeout so a failure is provably a command result, never a
/// timeout firing (threat T-3-07).
void main() {
  const requestTimeout = Duration(seconds: 10);

  // The mock's magic sym-handle-count group (07-03): a Read of 4 bytes returns
  // the number of LIVE (resolved-but-not-released) handles on this connection as
  // a little-endian u32. This is the observable behind the leak proof (T-7-01).
  const kSymHandleCountGroup = 0xE7700005;

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

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

  /// Reads the mock's live sym-handle count via the magic group.
  Future<int> liveHandleCount(AdsClient client) async {
    final raw = await client.read(
      indexGroup: kSymHandleCountGroup,
      indexOffset: 0,
      length: 4,
      timeout: requestTimeout,
    );
    return ByteData.sublistView(raw).getUint32(0, Endian.little);
  }

  test('resolve read-write read-back release', () async {
    // Full lifecycle by RAW handle: resolve MAIN.counter -> write a DINT ->
    // read it back -> release. Proves 0xF003/0xF005(r/w)/0xF006 round-trip.
    final client = await connectClient();

    final handle =
        await client.getHandleByName('MAIN.counter', timeout: requestTimeout);

    final written = Uint8List(4);
    ByteData.sublistView(written).setInt32(0, 0x0BADF00D, Endian.little);
    await client.writeByHandle(handle, written, timeout: requestTimeout);

    final readBack =
        await client.readByHandle(handle, 4, timeout: requestTimeout);
    expect(readBack, equals(written),
        reason: 'read-by-handle must reflect the prior write-by-handle');

    await client.releaseHandle(handle, timeout: requestTimeout);
  });

  test('leak proof N cycles return to baseline', () async {
    // T-7-01: the DoS-mitigation core. Read the baseline count, run N
    // resolve/release cycles, and assert the live-handle count returns exactly
    // to baseline — a leak would leave it elevated. A fresh connection starts at
    // 0, so baseline is 0, but we read it rather than assume it.
    final client = await connectClient();

    final baseline = await liveHandleCount(client);
    expect(baseline, equals(0), reason: 'a fresh connection holds no handles');

    const n = 25;
    for (var i = 0; i < n; i++) {
      final h =
          await client.getHandleByName('MAIN.counter', timeout: requestTimeout);
      // Mid-cycle the count is strictly above baseline — proves the group is
      // observing real allocation, not returning a constant.
      expect(await liveHandleCount(client), equals(baseline + 1),
          reason: 'cycle $i must hold exactly one live handle');
      await client.releaseHandle(h, timeout: requestTimeout);
    }

    expect(await liveHandleCount(client), equals(baseline),
        reason: '$n resolve/release cycles must not leak a single handle');
  });

  test('AdsHandle close auto-releases', () async {
    // The RAII path: AdsHandle.create resolves, read/write delegate to the
    // client, and close() releases exactly once — the count returns to baseline.
    final client = await connectClient();

    final baseline = await liveHandleCount(client);

    final handle =
        await AdsHandle.create(client, 'MAIN.counter', timeout: requestTimeout);
    expect(handle.isValid, isTrue);
    expect(await liveHandleCount(client), equals(baseline + 1),
        reason: 'a live AdsHandle holds one device handle');

    final written = Uint8List(4);
    ByteData.sublistView(written).setInt32(0, 4242, Endian.little);
    await handle.write(written, timeout: requestTimeout);
    final readBack = await handle.read(4, timeout: requestTimeout);
    expect(ByteData.sublistView(readBack).getInt32(0, Endian.little),
        equals(4242));

    await handle.close(timeout: requestTimeout);
    expect(await liveHandleCount(client), equals(baseline),
        reason: 'AdsHandle.close() must release the device handle');

    // close() is idempotent — a second call is a no-op and does not underflow.
    await handle.close(timeout: requestTimeout);
    expect(await liveHandleCount(client), equals(baseline));
  });

  test('unknown name throws 0x710', () async {
    // An unresolvable symbol name maps to ADSERR_DEVICE_SYMBOLNOTFOUND (0x710).
    final client = await connectClient();

    await expectLater(
      client.getHandleByName('MAIN.does_not_exist', timeout: requestTimeout),
      throwsA(isA<AdsException>().having((e) => e.code, 'code', equals(0x710))),
    );
  });

  test('released handle reuse throws 0x710 and invalidates AdsHandle',
      () async {
    // T-7-05 staleness. Two proofs on one released handle:
    //   (a) a RAW readByHandle on a released handle throws 0x710;
    //   (b) reusing it THROUGH an AdsHandle throws 0x710 once, marks the handle
    //       invalid, and every SUBSEQUENT op throws StateError (no silent reuse).
    final client = await connectClient();

    // (a) Raw path: resolve, release, then reuse the stale raw handle.
    final raw =
        await client.getHandleByName('MAIN.counter', timeout: requestTimeout);
    await client.releaseHandle(raw, timeout: requestTimeout);
    await expectLater(
      client.readByHandle(raw, 4, timeout: requestTimeout),
      throwsA(isA<AdsException>().having((e) => e.code, 'code', equals(0x710))),
      reason: 'a released handle must no longer resolve on the device',
    );

    // (b) AdsHandle path: resolve a fresh AdsHandle, release its underlying raw
    // handle out from under it, then use it — the device error invalidates it.
    final handle =
        await AdsHandle.create(client, 'MAIN.counter', timeout: requestTimeout);
    await client.releaseHandle(handle.handle, timeout: requestTimeout);

    await expectLater(
      handle.read(4, timeout: requestTimeout),
      throwsA(isA<AdsException>().having((e) => e.code, 'code', equals(0x710))),
      reason: 'the stale-handle device error surfaces before invalidation',
    );
    expect(handle.isValid, isFalse,
        reason: '0x710 must mark the AdsHandle invalid');

    // Every subsequent op is a local StateError — the invalid handle is never
    // reused on the wire.
    await expectLater(
      handle.read(4, timeout: requestTimeout),
      throwsA(isA<StateError>()),
      reason:
          'a reused invalid handle throws StateError, not another device op',
    );
    await expectLater(
      handle.write(Uint8List(4), timeout: requestTimeout),
      throwsA(isA<StateError>()),
    );
  });
}
