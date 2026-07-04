@Tags(['unit'])
library;

import 'package:dart_ads/src/protocol/ads_error.dart';
import 'package:dart_ads/src/protocol/constants.dart';
import 'package:test/test.dart';

void main() {
  group('adsErrorName / adsErrorText lookup', () {
    test('representative device code resolves to its AdsDef.h name + text', () {
      expect(adsErrorName(0x0703), equals('ADSERR_DEVICE_INVALIDOFFSET'));
      expect(adsErrorText(0x0703), equals('invalid indexOffset'));
    });

    test('representative client code resolves to its AdsDef.h name + text', () {
      expect(adsErrorName(0x0748), equals('ADSERR_CLIENT_PORTNOTOPEN'));
      expect(adsErrorText(0x0748), equals('ads port not opened'));
    });

    test('global and router range codes resolve', () {
      expect(adsErrorName(0x0007), equals('GLOBALERR_MISSING_ROUTE'));
      expect(adsErrorName(0x0506), equals('ROUTERERR_PORTALREADYINUSE'));
    });

    test('0x0745 == decimal 1861 resolves to ADSERR_CLIENT_SYNCTIMEOUT', () {
      expect(0x0745, equals(1861));
      expect(adsErrorName(1861), equals('ADSERR_CLIENT_SYNCTIMEOUT'));
      expect(adsErrorName(0x0745), equals('ADSERR_CLIENT_SYNCTIMEOUT'));
      expect(adsErrorText(0x0745), contains('timeout elapsed'));
    });
  });

  group('AdsException.fromCode', () {
    test('device code: isDeviceError true, isClientError false, code round-trips',
        () {
      final ex = AdsException.fromCode(0x0703);
      expect(ex.code, equals(0x0703));
      expect(ex.name, equals('ADSERR_DEVICE_INVALIDOFFSET'));
      expect(ex.message, equals('invalid indexOffset'));
      expect(ex.isDeviceError, isTrue);
      expect(ex.isClientError, isFalse);
    });

    test('client code: isClientError true, isDeviceError false', () {
      final ex = AdsException.fromCode(0x0745);
      expect(ex.isClientError, isTrue);
      expect(ex.isDeviceError, isFalse);
    });

    test('toString includes hex code, name, and message', () {
      expect(
        AdsException.fromCode(0x0703).toString(),
        equals('AdsException: ADS error 0x0703 '
            '(ADSERR_DEVICE_INVALIDOFFSET): invalid indexOffset'),
      );
    });

    test('is distinct from other exception families', () {
      // AdsException must be its own type, not a subtype of the transport /
      // wire exceptions — a plain Exception implementer.
      expect(AdsException.fromCode(0x0703), isA<Exception>());
    });
  });

  group('isDeviceError / isClientError range boundaries', () {
    test('device range is [0x0700, 0x0740)', () {
      expect(AdsException.fromCode(0x0700).isDeviceError, isTrue);
      expect(AdsException.fromCode(0x073F).isDeviceError, isTrue);
      expect(AdsException.fromCode(0x0740).isDeviceError, isFalse);
      expect(AdsException.fromCode(0x06FF).isDeviceError, isFalse);
    });

    test('client range is [0x0740, 0x07FF]', () {
      expect(AdsException.fromCode(0x0740).isClientError, isTrue);
      expect(AdsException.fromCode(0x07FF).isClientError, isTrue);
      expect(AdsException.fromCode(0x073F).isClientError, isFalse);
      expect(AdsException.fromCode(0x0800).isClientError, isFalse);
    });
  });

  group('unknown-code fallback (never throws)', () {
    test('0x074A sits in the intentional 0x0749->0x0750 gap and is synthetic',
        () {
      // 0x074A is NOT a real AdsDef.h entry (the header jumps 0x0749 -> 0x0750).
      final name = adsErrorName(0x074A);
      expect(name, startsWith('ADS error 0x'));
      expect(name, equals('ADS error 0x074a'));
      // But it is still numerically inside the client range.
      expect(AdsException.fromCode(0x074A).isClientError, isTrue);
    });

    test('a completely unknown code yields a synthetic name without throwing',
        () {
      final ex = AdsException.fromCode(0xABCD);
      expect(ex.name, startsWith('ADS error 0x'));
      expect(ex.code, equals(0xABCD));
      expect(ex.message, equals('unknown ADS error code'));
      // toString must not throw for unknown codes.
      expect(ex.toString(), contains('0xabcd'));
    });
  });

  group('AdsState.fromCode', () {
    test('maps known wire values to their enum members', () {
      expect(AdsState.fromCode(0), equals(AdsState.invalid));
      expect(AdsState.fromCode(5), equals(AdsState.run));
      expect(AdsState.fromCode(19), equals(AdsState.exception));
    });

    test('members carry their wire code', () {
      expect(AdsState.run.code, equals(5));
      expect(AdsState.invalid.code, equals(0));
      expect(AdsState.exception.code, equals(19));
    });

    test('out-of-range value falls back to unknown (tolerant, no throw)', () {
      expect(AdsState.fromCode(9999), equals(AdsState.unknown));
      expect(AdsState.fromCode(20), equals(AdsState.unknown)); // MAXSTATES
      expect(AdsState.fromCode(-7), equals(AdsState.unknown));
    });

    test('the unknown sentinel code never collides with a real state', () {
      expect(AdsState.unknown.code, equals(-1));
      expect(AdsState.fromCode(-1), equals(AdsState.unknown));
    });
  });
}
