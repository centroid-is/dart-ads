@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

// =============================================================================
// C++ AdsLibTest performance/parity port — Phase 5 slice of TEST-05 (stress).
//
// Each `group(...)` is named EXACTLY after its Beckhoff C++ counterpart in
// `third_party/ADS/AdsLibTest/main.cpp` (struct TestAdsPerformance) so the Phase
// 9 parity audit can confirm coverage MECHANICALLY (grep the group names against
// the C++ method names):
//
//   testManyNotifications  (main.cpp L998)  8 threads x Notifications(1024):
//                                           register 1024, sleep 5s, delete 1024;
//                                           a THROUGHPUT harness (prints
//                                           notifications/ms) whose correctness
//                                           content is "every Add and every
//                                           Delete returns 0".
//   testEndurance          (main.cpp L1038) register 1024, run a reader thread,
//                                           BLOCK on std::cin until ENTER, then
//                                           delete 1024 — interactive/manual by
//                                           construction.
//
// -- Adaptation rules (05-CONTEXT) --------------------------------------------
//
//   * testManyNotifications: many -> 64+ CONCURRENT subscriptions (not 8192
//     across threads); throughput number -> a DETERMINISTIC handle-LEAK proof.
//     The mock exposes an in-band active-notification-handle count via a magic
//     read group (0xE7700002); this test asserts it reads 0 BEFORE subscribing,
//     N while N subscriptions are live, and 0 AFTER cancelling them all — a
//     mechanical "no handle leak" proof rather than "probably fine" (NOTIF-02,
//     threat T-5-01). Every subscription must also actually RECEIVE.
//
//   * testEndurance: the interactive std::cin block -> a bounded register/
//     receive/cancel LOOP tagged `slow`, EXCLUDED from the default suite (run it
//     with `dart test -t slow --run-skipped`). It re-proves the count returns to
//     0 after every iteration, so a per-iteration handle leak would surface as a
//     drift away from 0.
//
// Store/handle isolation: the mock's notification table is connection-scoped, so
// each test takes a FRESH mock + connection (via `connectClient`) and every
// request carries a comfortably-long timeout so a failing assertion is provably
// a delivery/leak result, never a timeout firing.
// =============================================================================

void main() {
  const requestTimeout = Duration(seconds: 10);

  // The watched index group; each subscription takes a DISTINCT offset so a Write
  // to (group, offset_i) emits to exactly one handle.
  const watchGroup = 0x4020;

  // Mock magic read group: a Read returns the live notification-handle count.
  const activeHandleCountGroup = 0xE7700002;

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

  /// Reads the mock's in-band active-notification-handle count (the leak proof).
  Future<int> activeHandleCount(AdsClient client) async {
    final bytes = await client.read(
      indexGroup: activeHandleCountGroup,
      indexOffset: 0,
      length: 4,
      timeout: requestTimeout,
    );
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  /// Polls [condition] on a short interval until true or [timeout] elapses — a
  /// BOUNDED wait (never an unbounded await), so a failure is provably a result.
  Future<void> waitUntil(
    FutureOr<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 15),
    String? reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(reason ?? 'condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  // ---------------------------------------------------------------------------
  group('testManyNotifications', () {
    test('64+ concurrent subscriptions all receive; handle count returns to 0',
        () async {
      const n = 64; // 05-CONTEXT: many -> 64+
      final client = await connectClient();

      // Leak proof, step 1: no handles before subscribing.
      expect(await activeHandleCount(client), equals(0),
          reason: 'a fresh connection has zero notification handles');

      // Open N concurrent subscriptions, each on a DISTINCT offset, collecting
      // into its own bucket.
      final received = List.generate(n, (_) => <AdsNotification>[]);
      final subs = <StreamSubscription<AdsNotification>>[];
      for (var i = 0; i < n; i++) {
        subs.add(
          client
              .subscribe(
                indexGroup: watchGroup,
                indexOffset: i,
                length: 1,
                timeout: requestTimeout,
              )
              .listen(received[i].add),
        );
      }

      // Leak proof, step 2: all N Adds registered.
      await waitUntil(
        () async => await activeHandleCount(client) == n,
        reason: 'not all $n AddDeviceNotification requests registered',
      );

      // Trigger one Write per subscription; every stream must receive.
      for (var i = 0; i < n; i++) {
        await client.write(
          indexGroup: watchGroup,
          indexOffset: i,
          data: Uint8List.fromList([i & 0xFF]),
          timeout: requestTimeout,
        );
      }
      await waitUntil(
        () => received.every((bucket) => bucket.isNotEmpty),
        reason: 'not every concurrent subscription received a notification',
      );
      for (var i = 0; i < n; i++) {
        expect(received[i], isNotEmpty,
            reason: 'subscription #$i (offset $i) received its notification');
        expect(received[i].first.data, equals(Uint8List.fromList([i & 0xFF])),
            reason: 'subscription #$i received ITS OWN sample (no cross-talk)');
      }

      // Count equals the number of live handles.
      expect(await activeHandleCount(client), equals(n),
          reason: 'active-handle count matches the live subscription count');

      // Cancel every subscription -> each onCancel sends DeleteDeviceNotification.
      for (final sub in subs) {
        await sub.cancel();
      }

      // Leak proof, step 3: the count DETERMINISTICALLY returns to 0.
      await waitUntil(
        () async => await activeHandleCount(client) == 0,
        reason: 'HANDLE LEAK: count did not return to 0 after cancelling all',
      );
      expect(await activeHandleCount(client), equals(0),
          reason: 'no handle leak — every Delete freed its handle');
    });
  });

  // ---------------------------------------------------------------------------
  group('testEndurance', () {
    // Tagged `slow`: EXCLUDED from the default suite (dart_test.yaml skips the
    // `slow` tag). Run explicitly with `dart test -t slow --run-skipped`.
    test(
      'sustained register/receive/cancel loop leaves no handle leak',
      () async {
        const iterations = 50;
        const offset = 4;
        final client = await connectClient();

        for (var i = 0; i < iterations; i++) {
          expect(await activeHandleCount(client), equals(0),
              reason: 'iteration $i started with a leaked handle');

          final received = <AdsNotification>[];
          final sub = client
              .subscribe(
                indexGroup: watchGroup,
                indexOffset: offset,
                length: 1,
                timeout: requestTimeout,
              )
              .listen(received.add);

          await waitUntil(
            () async => await activeHandleCount(client) == 1,
            reason: 'iteration $i: Add never registered',
          );
          await client.write(
            indexGroup: watchGroup,
            indexOffset: offset,
            data: Uint8List.fromList([i & 0xFF]),
            timeout: requestTimeout,
          );
          await waitUntil(() => received.isNotEmpty,
              reason: 'iteration $i: no notification delivered');

          await sub.cancel();
          await waitUntil(
            () async => await activeHandleCount(client) == 0,
            reason: 'iteration $i: handle leaked after cancel',
          );
        }
      },
      tags: 'slow',
    );
  });
}
