@Tags(['unit'])
library;

import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// Unit coverage for the `localAddress` seam on [FakeTransport], the test double
/// that lets source-NetId auto-derivation (`<ip>.1.1`) be exercised with no live
/// socket (ROUTE-03). Reaching into `src/` is acceptable here: this is a
/// same-package unit test of an intentionally test-only double the public barrel
/// does not export.
void main() {
  group('FakeTransport.localAddress', () {
    test('defaults to null (as if not yet connected)', () {
      final transport = FakeTransport();

      expect(transport.localAddress, isNull);
    });

    test('returns the stubbed value once set', () {
      final transport = FakeTransport()..localAddress = '192.168.0.100';

      expect(transport.localAddress, equals('192.168.0.100'));
    });

    test('can be reset back to null', () {
      final transport = FakeTransport()..localAddress = '10.0.0.5';
      expect(transport.localAddress, equals('10.0.0.5'));

      transport.localAddress = null;

      expect(transport.localAddress, isNull);
    });
  });
}
