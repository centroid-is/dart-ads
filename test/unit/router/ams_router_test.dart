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
//     the return code + a non-null connection (never connection identity), so the
//     divergence is invisible to the parity suite (see AmsRouter class doc).
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
        expect(port, isNot(0), reason: 'slot $i should allocate a non-zero port');
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
      expect(router.closePort(AmsRouter.portBase + AmsRouter.numPortsMax), 0x0748);
      // A never-opened but in-range port is likewise "not open".
      expect(router.closePort(AmsRouter.portBase), 0x0748);
    });
  });

  group('testAmsRouterAddRoute', () {
    test('add / different-host / re-add / used-host / idempotent', () {
      final router = fakeRouter();

      // 1. New NetId + new host -> 0, connection present.
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.getConnection(netIdA), isNotNull);

      // 2. Same NetId + DIFFERENT host -> PORTALREADYINUSE (0x0506); old intact.
      expect(router.addRoute(netIdA, hostB), 0x0506);
      expect(router.getConnection(netIdA), isNotNull);

      // 3. removeRoute, then re-add same NetId to that different host -> 0.
      router.removeRoute(netIdA);
      expect(router.getConnection(netIdA), isNull);
      expect(router.addRoute(netIdA, hostB), 0);
      expect(router.getConnection(netIdA), isNotNull);

      // 4. New NetId + an already-used host -> 0 (own connection per NetId).
      expect(router.addRoute(netIdB, hostB), 0);
      expect(router.getConnection(netIdB), isNotNull);

      // 5. Same NetId + same host again -> idempotent 0.
      expect(router.addRoute(netIdB, hostB), 0);
      expect(router.getConnection(netIdB), isNotNull);
    });
  });

  group('testAmsRouterDelRoute', () {
    test('add then removeRoute -> connection gone', () {
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      router.removeRoute(netIdA);
      expect(router.getConnection(netIdA), isNull);
    });

    test('removing one of two routes leaves the other intact', () {
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.addRoute(netIdB, hostB), 0);

      router.removeRoute(netIdA);
      expect(router.getConnection(netIdA), isNull);
      expect(router.getConnection(netIdB), isNotNull);
    });
  });

  group('testAmsRouterSetLocalAddress', () {
    test('default empty; setLocalAddress overwrites; getLocalAddress reflects', () {
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

    test('resolve of a routed NetId returns its connection (no throw)', () {
      final router = fakeRouter();
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.resolve(netIdA), same(router.getConnection(netIdA)));
    });
  });

  group('auto_derive', () {
    test('first connection derives source NetId as <ip>.1.1 when unset', () {
      final router = fakeRouter(localIp: '192.168.0.100');

      // No explicit setLocalAddress -> derived from the transport local IPv4.
      expect(router.getLocalAddress(), AmsRouter.emptyLocalAddress);
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.getLocalAddress(), AmsNetId.parse('192.168.0.100.1.1'));
    });

    test('an explicit setLocalAddress suppresses the auto-derive', () {
      final router = fakeRouter(localIp: '192.168.0.100');
      final explicit = AmsNetId(const [7, 7, 7, 7, 7, 7]);

      router.setLocalAddress(explicit);
      expect(router.addRoute(netIdA, hostA), 0);
      expect(router.getLocalAddress(), explicit);
    });
  });
}
