@Tags(['unit'])
library;

import 'package:dart_ads/src/protocol/ams_net_id.dart';
import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:test/test.dart';

// =============================================================================
// C++ AdsLibTest parity port — Phase 4 slice of TEST-05 (ordering).
//
// The `group('testAmsAddrCompare', ...)` below is named EXACTLY after its
// Beckhoff C++ counterpart in `third_party/ADS/AdsLibTest/main.cpp` (L75-96) so
// the Phase 9 parity audit can confirm coverage MECHANICALLY (grep the group
// name against the C++ method name), same convention as `ads_parity_test.dart`.
//
// -- Adaptation rule (C++ operator< -> Dart compareTo/operator<) --
//
//   * The C++ test asserts `AmsAddr::operator<` directly (`a < b`). Dart models
//     ordering as `Comparable` (`compareTo`) with a derived `operator<`. Each
//     C++ `x < testee` becomes the Dart `x < testee`; each C++ `!(testee < x)`
//     asymmetry check becomes `!(testee < x)`. The lexicographic-over-6-bytes
//     (bytes[0] most significant) NetId ordering and the netId-then-port AmsAddr
//     ordering mirror `third_party/ADS/AdsLib/AdsDef.cpp operator<`.
//
// The second group covers `AmsNetId.fromIpv4` (Phase-4 addition mirroring the
// C++ `AmsNetId(uint32_t)` `<ip>.1.1` convention, AdsDef.cpp L10-18): it is a
// Dart-native unit assertion, not a 1:1 C++ method port, so it is NOT named
// after a C++ method.
// =============================================================================

void main() {
  group('testAmsAddrCompare', () {
    // Fixture mirrors the C++ testee: {192.168.0.231.1.1, 1000}.
    final testee = AmsAddr(AmsNetId([192, 168, 0, 231, 1, 1]), 1000);

    // Differs in the LAST NetId byte (231.1.0 < 231.1.1), same port.
    final lowerLast = AmsAddr(AmsNetId([192, 168, 0, 231, 1, 0]), 1000);

    // Differs in a MIDDLE NetId byte (0.1 < 0.231), same port.
    final lowerMiddle = AmsAddr(AmsNetId([192, 168, 0, 1, 1, 1]), 1000);

    // Same NetId, LOWER port (999 < 1000).
    final lowerPort = AmsAddr(AmsNetId([192, 168, 0, 231, 1, 1]), 999);

    test('lower last NetId byte sorts before testee', () {
      expect(lowerLast < testee, isTrue);
    });

    test('lower middle NetId byte sorts before testee', () {
      expect(lowerMiddle < testee, isTrue);
    });

    test('same NetId with lower port sorts before testee', () {
      expect(lowerPort < testee, isTrue);
    });

    test('ordering is asymmetric (testee is not < any lower value)', () {
      expect(testee < lowerLast, isFalse);
      expect(testee < lowerMiddle, isFalse);
      expect(testee < lowerPort, isFalse);
    });

    test('ordering is irreflexive (testee is not < itself)', () {
      expect(testee < testee, isFalse);
    });
  });

  group('AmsNetId.fromIpv4', () {
    test('derives <ip>.1.1 with big-endian octet order', () {
      expect(
        AmsNetId.fromIpv4('192.168.0.100'),
        equals(AmsNetId([192, 168, 0, 100, 1, 1])),
      );
    });

    test('throws MalformedFrameException on a non-4-octet input', () {
      expect(
        () => AmsNetId.fromIpv4('192.168.0'),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('throws MalformedFrameException on an out-of-range octet', () {
      expect(
        () => AmsNetId.fromIpv4('192.168.0.256'),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });
}
