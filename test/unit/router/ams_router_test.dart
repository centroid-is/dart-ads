@Tags(['unit'])
library;

import 'package:dart_ads/dart_ads.dart';
import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

// =============================================================================
// C++ AdsLibTest parity port — Phase 4 slice of TEST-05 (router registry).
//
// Each `group(...)` below is named EXACTLY after its Beckhoff C++ counterpart in
// `third_party/ADS/AdsLibTest/main.cpp` so the Phase 9 parity audit can confirm
// coverage MECHANICALLY (grep the group names against the C++ method names):
//
//   testAdsPortOpenEx            (main.cpp L309)  128-slot port alloc + close
//   testAmsRouterAddRoute        (main.cpp L107)  route add decision tree
//   testAmsRouterDelRoute        (main.cpp L135)  route removal isolation
//   testAmsRouterSetLocalAddress (main.cpp L158)  mutable source NetId
//
// Two Dart-only groups extend the parity surface for the Phase-4 route algebra:
//   missing_route  — resolve() of an unrouted NetId throws 0x0007 before I/O
//   auto_derive    — first connection derives source NetId as <ip>.1.1
//
// -- Adaptation rules (C++ port-handle / global router -> Dart instance) -------
//
//   * PROCESS-GLOBAL AdsPortOpenEx/AdsPortCloseEx -> INSTANCE openPort/closePort.
//     The C++ testAdsPortOpenEx drives the process-global free functions over the
//     singleton router; Dart has no global router — these map onto instance
//     methods on a fresh `AmsRouter`. The port LIFECYCLE (allocate 30000+ ->
//     release; out-of-range/closed -> ADSERR_CLIENT_PORTNOTOPEN 0x0748) is
//     reproduced 1:1 against the instance (same convention as ads_parity_test).
//
//   * ONE-CONNECTION-PER-NETID divergence. The C++ router shares one refcounted
//     AmsConnection across NetIds pointing at the same host; this Dart port keeps
//     one connection per target NetId. Every parity assertion here checks only
//     the return code + route presence (never connection identity), so the
//     divergence is invisible to the parity suite (see AmsRouter class doc).
//
//   * LAZY DIAL AT connect() (one-dial-point adaptation). The C++ AddRoute opens
//     its AmsConnection eagerly (synchronous C++ socket code); this async Dart
//     port stores only endpoint metadata in addRoute and dials in
//     router.connect(). The C++ parity assertion
//     `GetConnection(netId) != nullptr` after AddRoute therefore maps onto
//     `hasRoute(netId) == true` (route presence), and getConnection()/resolve()
//     serve only LIVE connect()-dialed connections — never a dead, un-dialed
//     object. AddRoute return codes and DelRoute effects are reproduced 1:1.
//
//   * NO LIVE SOCKETS. A FakeTransport-returning factory is injected, so the
//     entire route/port/localAddr algebra runs as a pure unit test. The C++
//     tests open real sockets; the socket-touching dual-mode parity lands in the
//     Plan 04 integration suite.
// =============================================================================

void main() {
  // Arbitrary but valid AMS Net IDs used across the route-table groups.
  final netIdA = AmsNetId.parse('192.168.0.1.1.1');
  final netIdB = AmsNetId.parse('192.168.0.2.1.1');
  final netIdC = AmsNetId.parse('10.0.0.9.1.1');
  const hostA = '192.168.0.1';
  const hostB = '192.168.0.2';

  /// A router whose routes connect over fresh in-memory [FakeTransport]s (no
  /// sockets). [localIp] optionally stubs each transport's `localAddress` so the
  /// `<ip>.1.1` auto-derive can be exercised.
  AmsRouter fakeRouter({String? localIp}) => AmsRouter(
        transportFactory: (host, port) {
          final transport = FakeTransport();
          if (localIp != null) transport.localAddress = localIp;
          return transport;
        },
      );

  group('testAdsPortOpenEx', () {
    test('opens 128 distinct ports in [30000, 30128), then exhausts to 0', () {
      final router = fakeRouter();
      final ports = <int>{};
      for (var i = 0; i < AmsRouter.numPortsMax; i++) {
        final port = router.openPort();
        expect(port, isNot(0),
            reason: 'slot $i should allocate a non-zero port');
        expect(port, greaterThanOrEqualTo(AmsRouter.portBase));
        expect(port, lessThan(AmsRouter.portBase + AmsRouter.numPortsMax));
        ports.add(port);
      }
      expect(ports, hasLength(AmsRouter.numPortsMax),
          reason: 'every allocated port is distinct');

      // The 129th allocation exhausts the pool and returns the 0 sentinel.
      expect(router.openPort(), 0);
    });

    test('closes all 128 ports (each 0); closing again -> 0x0748', () {
      final router = fakeRouter();
      final ports = <int>[
        for (var i = 0; i < AmsRouter.numPortsMax; i++) router.openPort(),
      ];

      for (final port in ports) {
        expect(router.closePort(port), 0);
      }
      // Closing an already-closed port yields ADSERR_CLIENT_PORTNOTOPEN.
      expect(router.closePort(ports.first), 0x0748);
    });

    test('closePort of an out-of-range port -> 0x0748', () {
      final router = fakeRouter();
      expect(router.closePort(AmsRouter.portBase - 1), 0x0748);
      expect(
          router.closePort(AmsRouter.portBase + AmsRouter.numPortsMax), 0x0748);
      // A never-opened but in-range port is likewise "not open".
      expect(router.closePort(AmsRouter.portBase), 0x0748);
    });
  });

  group('testAmsRouterAddRoute', () {
    test('add / different-host / re-add / used-host / idempotent', () {
      final router = fakeRouter();

      // 1. New NetId + new host -> 0, route present (C++ GetConnection != null
      //    maps to hasRoute — see the lazy-dial adaptation note above).
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.hasRoute(netIdA), isTrue);

      // 2. Same NetId + DIFFERENT host -> PORTALREADYINUSE (0x0506); old intact.
      expect(router.addRoute(netIdA, hostB), 0x0506);
      expect(router.hasRoute(netIdA), isTrue);

      // 3. removeRoute, then re-add same NetId to that different host -> 0.
      router.removeRoute(netIdA);
      expect(router.hasRoute(netIdA), isFalse);
      expect(router.addRoute(netIdA, hostB), 0);
      expect(router.hasRoute(netIdA), isTrue);

      // 4. New NetId + an already-used host -> 0 (own route entry per NetId).
      expect(router.addRoute(netIdB, hostB), 0);
      expect(router.hasRoute(netIdB), isTrue);

      // 5. Same NetId + same host again -> idempotent 0.
      expect(router.addRoute(netIdB, hostB), 0);
      expect(router.hasRoute(netIdB), isTrue);

      // No connection has been dialed at any point: addRoute is metadata-only.
      expect(router.getConnection(netIdA), isNull);
      expect(router.getConnection(netIdB), isNull);
    });
  });

  group('testAmsRouterDelRoute', () {
    test('add then removeRoute -> route gone', () {
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      router.removeRoute(netIdA);
      expect(router.hasRoute(netIdA), isFalse);
      expect(router.getConnection(netIdA), isNull);
    });

    test('removing one of two routes leaves the other intact', () {
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.addRoute(netIdB, hostB), 0);

      router.removeRoute(netIdA);
      expect(router.hasRoute(netIdA), isFalse);
      expect(router.hasRoute(netIdB), isTrue);
    });

    test('removeRoute closes the live connect()-dialed connection', () async {
      final router = fakeRouter()
        ..setLocalAddress(AmsNetId(const [1, 2, 3, 4, 5, 6]));
      expect(router.addRoute(netIdA, hostA), 0);
      final client = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const DirectTarget(hostA),
      );
      expect(router.getConnection(netIdA), same(client.connection));

      router.removeRoute(netIdA);
      expect(router.getConnection(netIdA), isNull);
      // C++ DelRoute parity: the route's connection does not survive it.
      await client.connection.done;
      expect(client.connection.isConnected, isFalse);
    });
  });

  group('testAmsRouterSetLocalAddress', () {
    test('default empty; setLocalAddress overwrites; getLocalAddress reflects',
        () {
      final router = fakeRouter();

      // A freshly opened port and the empty default source address.
      final port = router.openPort();
      expect(port, isNot(0));
      expect(router.getLocalAddress(), AmsRouter.emptyLocalAddress);
      expect(router.getLocalAddress(), AmsNetId(const [0, 0, 0, 0, 0, 0]));

      // SetLocalAddress({1,2,3,4,5,6}) is reflected verbatim.
      final local = AmsNetId(const [1, 2, 3, 4, 5, 6]);
      router.setLocalAddress(local);
      expect(router.getLocalAddress(), local);
    });
  });

  group('missing_route', () {
    test('resolve of an unrouted NetId throws 0x0007 naming the NetId', () {
      final router = fakeRouter();
      expect(
        () => router.resolve(netIdC),
        throwsA(
          isA<AdsRoutingException>()
              .having((e) => e.code, 'code', 0x0007)
              .having((e) => e.netId, 'netId', netIdC)
              .having((e) => e.toString(), 'toString', contains(netIdC.dotted)),
        ),
      );
    });

    test('resolve of a routed-but-unconnected NetId throws (not 0x0007)', () {
      // Lazy-dial adaptation: the route exists, but connect() has not dialed a
      // connection yet — resolve refuses rather than returning a dead object.
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      expect(
        () => router.resolve(netIdA),
        throwsA(isA<AdsConnectionException>()),
      );
    });

    test('after connect(), resolve returns the live connection', () async {
      final router = fakeRouter()
        ..setLocalAddress(AmsNetId(const [1, 2, 3, 4, 5, 6]));
      expect(router.addRoute(netIdA, hostA), 0);
      final client = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const DirectTarget(hostA),
      );
      expect(router.resolve(netIdA), same(router.getConnection(netIdA)));
      expect(router.resolve(netIdA), same(client.connection));
      await router.close();
    });
  });

  group('auto_derive', () {
    test('first successful connect() derives source NetId as <ip>.1.1',
        () async {
      final router = fakeRouter(localIp: '192.168.0.100');

      // No explicit setLocalAddress -> derived post-dial from the transport's
      // local IPv4 (a real SocketTransport has no local address before the
      // dial, so addRoute cannot derive — connect() is the derive point).
      expect(router.getLocalAddress(), AmsRouter.emptyLocalAddress);
      final client = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      expect(router.getLocalAddress(), AmsNetId.parse('192.168.0.100.1.1'));
      await client.connection.close();
    });

    test('an explicit setLocalAddress suppresses the auto-derive', () async {
      final router = fakeRouter(localIp: '192.168.0.100');
      final explicit = AmsNetId(const [7, 7, 7, 7, 7, 7]);

      router.setLocalAddress(explicit);
      final client = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      expect(router.getLocalAddress(), explicit);
      await client.connection.close();
    });
  });

  // Dart-only lifecycle guarantees for connect()-created connections: the
  // allocated 30000+ SOURCE-port slot lives exactly as long as its connection
  // (released on close/disconnect and by AmsRouter.close()), so a router can
  // serve unlimited connect() calls over its lifetime, not just 128.
  group('connect_lifecycle', () {
    test('source-port slot is released when the connection closes', () async {
      final router = fakeRouter()
        ..setLocalAddress(AmsNetId(const [1, 2, 3, 4, 5, 6]));

      final first = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      expect(first.source.port, AmsRouter.portBase);

      await first.connection.close();

      // The freed slot is the FIRST free slot again: a fresh connect reuses
      // 30000 instead of walking the range (i.e. no lifetime leak).
      final second = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      expect(second.source.port, AmsRouter.portBase);
      await router.close();
    });

    test('router.close() closes owned connections and frees every slot',
        () async {
      final router = fakeRouter()
        ..setLocalAddress(AmsNetId(const [1, 2, 3, 4, 5, 6]));

      final clientA = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      final clientB = await router.connect(
        netIdB,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostB),
      );
      expect(clientA.source.port, isNot(equals(clientB.source.port)));

      await router.close();

      // Both connect()-created connections are torn down...
      expect(clientA.connection.isConnected, isFalse);
      expect(clientB.connection.isConnected, isFalse);
      // ...and both slots are back in the pool (30000 is first-free again).
      expect(router.openPort(), AmsRouter.portBase);
      expect(router.openPort(), AmsRouter.portBase + 1);
    });

    test('a newer connect() to the same NetId survives the older teardown',
        () async {
      final router = fakeRouter()
        ..setLocalAddress(AmsNetId(const [1, 2, 3, 4, 5, 6]));

      final older = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      final newer = await router.connect(
        netIdA,
        AmsPort.plcTc3,
        mode: const LocalRouterTarget(host: hostA),
      );
      expect(router.getConnection(netIdA), same(newer.connection));

      // Closing the OLDER connection must not evict the newer live entry.
      await older.connection.close();
      expect(router.getConnection(netIdA), same(newer.connection));
      await router.close();
    });
  });
}
