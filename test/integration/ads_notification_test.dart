@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

// =============================================================================
// C++ AdsLibTest notification parity port — Phase 5 slice of TEST-05 (lifecycle).
//
// `group('testAdsNotification', ...)` is named EXACTLY after its Beckhoff C++
// counterpart in `third_party/ADS/AdsLibTest/main.cpp` (struct TestAds,
// `testAdsNotification` at main.cpp L851) so the Phase 9 parity audit can confirm
// coverage MECHANICALLY (grep the group name against the C++ method name).
//
// -- Adaptation rules (C++ port-handle semantics -> Dart Stream lifecycle) -----
//
//   * The C++ testAdsNotification is a LIFECYCLE + ERROR-CODE test: it registers
//     1024 notifications, sleeps, deletes the first 512 and intentionally leaks
//     the rest to prove AdsPortCloseEx cleans them up. It does NOT assert a
//     received-notification count. Per 05-CONTEXT the Dart 1:1 intent is:
//     subscribe against a mock-known (group,offset), RECEIVE >=1 notification
//     (the mock emits on a Write to the watched region), cancel -> Delete, and
//     verify NO further delivery — the handle-leak/cleanup proof is split out to
//     `notification_parity_test.dart` (testManyNotifications, the deterministic
//     active-handle-count == 0 proof).
//
//   * PORT-HANDLE error cases (ADSERR_CLIENT_PORTNOTOPEN / NOAMSADDR /
//     INVALIDPARM) are covered-by-equivalent in the Phase-2 connection-lifecycle
//     tests and by Dart's non-nullable subscribe() signature (compile-time), so
//     they are intentionally NOT re-asserted here.
//
// Beyond the 1:1 port, three phase-critical behaviours are exercised end-to-end
// over the live socket (they have no direct C++ AdsLibTest analogue — they prove
// the Dart notification stack's containment/race properties, threats T-5-02 /
// T-5-11 / NOTIF-04):
//
//   * `first-listen race`      — the first sample arriving in the Add-response's
//                                TCP chunk must be delivered, not dropped
//                                (synchronous handle registration).
//   * `hostile notification frame` — one malformed 0x08 frame is dropped and
//                                CONTAINED; the connection stays alive and a
//                                later good notification still arrives.
//   * `transmission modes`     — serverOnChange and serverCycle both deliver.
//
// Store/handle isolation: the mock's data store + notification table are
// connection-scoped, so each test takes a FRESH mock + connection (via
// `connectClient`) and every request carries a comfortably-long timeout so a
// failing assertion is provably a delivery result, never a timeout firing.
// =============================================================================

void main() {
  // Generous per-request timeout: a "failed" assertion is a real delivery/parse
  // result, not a timeout firing.
  const requestTimeout = Duration(seconds: 10);

  // The watched region every notification test subscribes to — the C++
  // testAdsNotification attribs (indexGroup 0x4020, indexOffset 4, cbLength 1).
  const watchGroup = 0x4020;
  const watchOffset = 4;

  // Mock magic groups (from 05-02 / 05-06): a READ of the active-handle-count
  // group returns the live notification-handle count as a u32; a WRITE of the
  // hostile group emits ONE deliberately malformed 0x08 frame the parser drops.
  const activeHandleCountGroup = 0xE7700002;
  const hostileFrameGroup = 0xE7700004;

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  /// Starts a fresh mock + connected [AmsConnection] + [AdsClient], registering
  /// teardown for both so no orphan process or open socket survives the test.
  /// [args] are passed to the mock (e.g. `['--notify-burst', '3']`).
  Future<AdsClient> connectClient({List<String> args = const []}) async {
    final server = await startMockServer(args: args);
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

  /// Polls [condition] on a short interval until true or [timeout] elapses —
  /// a BOUNDED wait (never an unbounded await), so a failure is provably a
  /// result rather than a hang.
  Future<void> waitUntil(
    FutureOr<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 8),
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
  group('testAdsNotification', () {
    test('subscribe -> receive -> cancel(Delete) -> no further delivery',
        () async {
      final client = await connectClient();
      final received = <AdsNotification>[];

      final sub = client
          .subscribe(
            indexGroup: watchGroup,
            indexOffset: watchOffset,
            length: 1,
            mode: AdsTransmissionMode.serverOnChange,
            timeout: requestTimeout,
          )
          .listen(received.add);

      // The Add is sent on first listen; wait until the mock has registered it
      // (active-handle count -> 1) before triggering an emission.
      await waitUntil(
        () async => await activeHandleCount(client) == 1,
        reason: 'AddDeviceNotification never registered on the mock',
      );

      // serverOnChange: a Write to the watched region emits ONE notification
      // carrying the written byte (truncated/padded to cbLength 1).
      await client.write(
        indexGroup: watchGroup,
        indexOffset: watchOffset,
        data: Uint8List.fromList(const [0x7]),
        timeout: requestTimeout,
      );

      await waitUntil(() => received.isNotEmpty,
          reason: 'no notification delivered after the triggering Write');

      expect(received.first.timestamp.isUtc, isTrue,
          reason: 'FILETIME converts to a UTC DateTime');
      expect(received.first.data, equals(Uint8List.fromList(const [0x7])),
          reason: 'notification carries the written data');
      final deliveredBeforeCancel = received.length;

      // Cancel -> onCancel sends DeleteDeviceNotification; the handle frees.
      await sub.cancel();
      await waitUntil(
        () async => await activeHandleCount(client) == 0,
        reason: 'cancel did not Delete the handle (count did not return to 0)',
      );

      // A further Write to the (now unwatched) region must NOT deliver.
      await client.write(
        indexGroup: watchGroup,
        indexOffset: watchOffset,
        data: Uint8List.fromList(const [0x9]),
        timeout: requestTimeout,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300)); // settle
      expect(received.length, equals(deliveredBeforeCancel),
          reason: 'no delivery after cancel/Delete');
    });
  });

  // ---------------------------------------------------------------------------
  group('first-listen race', () {
    test('the first burst notification (Add-response chunk) is delivered',
        () async {
      // --notify-burst 3: on each Add the mock emits 3 notifications back-to-back
      // right AFTER the Add-response, so the response and the first notification
      // coalesce into one inbound TCP chunk. Only TRUE synchronous handle
      // registration (option A, 05-RESEARCH Pattern 2) delivers that first
      // same-chunk sample; a post-await registration would drop it (threat
      // T-5-11).
      final client = await connectClient(args: ['--notify-burst', '3']);
      final received = <AdsNotification>[];

      final sub = client
          .subscribe(
            indexGroup: watchGroup,
            indexOffset: watchOffset,
            length: 1,
            timeout: requestTimeout,
          )
          .listen(received.add);

      await waitUntil(() => received.isNotEmpty,
          reason:
              'first-listen race: the first burst notification was dropped');

      expect(received, isNotEmpty,
          reason:
              'synchronous registration delivers the first same-chunk sample');
      expect(client.connection.droppedNotifications, equals(0),
          reason: 'a delivered burst is never counted as dropped');

      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  group('hostile notification frame', () {
    test(
        'one malformed 0x08 is dropped; connection survives; good frame arrives',
        () async {
      final client = await connectClient();
      final received = <AdsNotification>[];

      final sub = client
          .subscribe(
            indexGroup: watchGroup,
            indexOffset: watchOffset,
            length: 1,
            timeout: requestTimeout,
          )
          .listen(received.add);

      await waitUntil(() async => await activeHandleCount(client) == 1,
          reason: 'AddDeviceNotification never registered on the mock');

      // Trigger ONE malformed 0x08 frame (a sample whose size overruns the
      // payload). Its AMS/TCP wrapper is well-formed, so it reaches the parser
      // as a complete frame and is CONTAINED (droppedNotifications++), never
      // poisoning the connection (threat T-5-02).
      await client.write(
        indexGroup: hostileFrameGroup,
        indexOffset: 0,
        data: Uint8List.fromList(const [0x0]),
        timeout: requestTimeout,
      );

      // Then a good Write to the watched region: the connection must still
      // deliver its notification.
      await client.write(
        indexGroup: watchGroup,
        indexOffset: watchOffset,
        data: Uint8List.fromList(const [0x5]),
        timeout: requestTimeout,
      );

      await waitUntil(() => received.isNotEmpty,
          reason: 'the connection died after the hostile frame');

      // The hostile frame precedes the good one on the ordered TCP stream, so by
      // the time the good notification arrives it has already been counted.
      expect(client.connection.droppedNotifications, greaterThanOrEqualTo(1),
          reason: 'the malformed 0x08 frame was contained + counted');
      expect(client.connection.isConnected, isTrue,
          reason: 'the hostile frame did not kill the connection');
      expect(received.first.data, equals(Uint8List.fromList(const [0x5])),
          reason: 'the subsequent good notification still delivered');

      await sub.cancel();
    });
  });

  // ---------------------------------------------------------------------------
  group('transmission modes', () {
    // The mock emits on a Write to a watched region regardless of transmission
    // mode, so both serverOnChange and serverCycle deliver via the live mock
    // (NOTIF-04). The mode/cycleTime are encoded into the 40-byte Add request and
    // passed through unvalidated (C++ parity); the mock accepts both.
    Future<AdsNotification> firstOnWrite(
      AdsClient client, {
      required AdsTransmissionMode mode,
      Duration cycleTime = Duration.zero,
    }) async {
      final received = <AdsNotification>[];
      final sub = client
          .subscribe(
            indexGroup: watchGroup,
            indexOffset: watchOffset,
            length: 1,
            mode: mode,
            cycleTime: cycleTime,
            timeout: requestTimeout,
          )
          .listen(received.add);
      addTearDown(sub.cancel);

      await waitUntil(() async => await activeHandleCount(client) == 1,
          reason: 'AddDeviceNotification never registered on the mock');
      await client.write(
        indexGroup: watchGroup,
        indexOffset: watchOffset,
        data: Uint8List.fromList(const [0x42]),
        timeout: requestTimeout,
      );
      await waitUntil(() => received.isNotEmpty,
          reason: 'no notification delivered under $mode');
      return received.first;
    }

    test('serverOnChange delivers', () async {
      final client = await connectClient();
      final n =
          await firstOnWrite(client, mode: AdsTransmissionMode.serverOnChange);
      expect(n.data, equals(Uint8List.fromList(const [0x42])));
    });

    test('serverCycle delivers', () async {
      final client = await connectClient();
      final n = await firstOnWrite(
        client,
        mode: AdsTransmissionMode.serverCycle,
        cycleTime: const Duration(milliseconds: 100),
      );
      expect(n.data, equals(Uint8List.fromList(const [0x42])));
    });
  });
}
