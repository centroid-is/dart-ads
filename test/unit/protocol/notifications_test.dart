@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:dart_ads/src/protocol/notifications.dart';
import 'package:test/test.dart';

/// The FILETIME epoch offset (100ns ticks between 1601-01-01 and 1970-01-01).
const int _epochOffset = 116444736000000000;

/// Reads a little-endian u32 from [bytes] at [offset].
int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

void main() {
  group('AdsTransmissionMode', () {
    test('exposes every ADSTRANSMODE wire code', () {
      expect(AdsTransmissionMode.noTrans.code, 0);
      expect(AdsTransmissionMode.clientCycle.code, 1);
      expect(AdsTransmissionMode.clientOnChange.code, 2);
      expect(AdsTransmissionMode.serverCycle.code, 3);
      expect(AdsTransmissionMode.serverOnChange.code, 4);
      expect(AdsTransmissionMode.serverCycle2.code, 5);
      expect(AdsTransmissionMode.serverOnChange2.code, 6);
      expect(AdsTransmissionMode.client1Req.code, 10);
    });
  });

  group('FILETIME <-> DateTime', () {
    test('filetime epoch offset maps to the Unix epoch (UTC)', () {
      expect(
        filetimeToDateTime(_epochOffset),
        DateTime.utc(1970, 1, 1),
      );
    });

    test('a whole-microsecond filetime round-trips exactly', () {
      final instant = DateTime.utc(2026, 7, 4, 13, 37, 42, 123, 456);
      final filetime = dateTimeToFiletime(instant);
      // multiple-of-10 by construction (micros * 10)
      expect(filetime % 10, 0);
      expect(filetimeToDateTime(filetime), instant);
    });

    test('a non-zero 100ns digit truncates predictably (~/10)', () {
      // 7 extra 100ns ticks above a whole microsecond: truncates down.
      final base = dateTimeToFiletime(DateTime.utc(2020, 1, 1));
      final withTicks = base + 7;
      expect(filetimeToDateTime(withTicks), filetimeToDateTime(base));
    });
  });

  group('buildAddNotificationPayload', () {
    test('produces exactly 40 bytes in the AmsHeader.h field order', () {
      final payload = buildAddNotificationPayload(
        indexGroup: 0x4020,
        indexOffset: 4,
        length: 1,
        transMode: AdsTransmissionMode.serverCycle.code,
        maxDelay100ns: 0,
        cycleTime100ns: 1000000,
      );

      expect(payload.length, 40);
      expect(_u32(payload, 0), 0x4020, reason: 'indexGroup');
      expect(_u32(payload, 4), 4, reason: 'indexOffset');
      expect(_u32(payload, 8), 1, reason: 'cbLength');
      expect(_u32(payload, 12), 3, reason: 'nTransMode');
      expect(_u32(payload, 16), 0, reason: 'nMaxDelay');
      expect(_u32(payload, 20), 1000000, reason: 'nCycleTime');
    });

    test('leaves bytes 24..39 (the 16 reserved bytes) zero', () {
      final payload = buildAddNotificationPayload(
        indexGroup: 1,
        indexOffset: 2,
        length: 3,
        transMode: 4,
        maxDelay100ns: 5,
        cycleTime100ns: 6,
      );
      expect(payload.sublist(24, 40), List.filled(16, 0));
    });

    test('rejects an out-of-u32 maxDelay via checkUint', () {
      expect(
        () => buildAddNotificationPayload(
          indexGroup: 1,
          indexOffset: 2,
          length: 3,
          transMode: 4,
          maxDelay100ns: 0x1_0000_0000,
          cycleTime100ns: 6,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an out-of-u32 cycleTime via checkUint', () {
      expect(
        () => buildAddNotificationPayload(
          indexGroup: 1,
          indexOffset: 2,
          length: 3,
          transMode: 4,
          maxDelay100ns: 5,
          cycleTime100ns: 0x1_0000_0000,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('buildDeleteNotificationPayload', () {
    test('produces 4 bytes = handle LE', () {
      final payload = buildDeleteNotificationPayload(handle: 0x11223344);
      expect(payload.length, 4);
      expect(_u32(payload, 0), 0x11223344);
    });
  });

  group('decodeAddNotificationResponse', () {
    test('reads result + handle on a success (result==0) payload', () {
      final payload = Uint8List(8);
      ByteData.sublistView(payload)
        ..setUint32(0, 0, Endian.little)
        ..setUint32(4, 0x2A, Endian.little);
      final decoded = decodeAddNotificationResponse(payload);
      expect(decoded.result, 0);
      expect(decoded.handle, 0x2A);
    });

    test('tolerates a 4-byte payload when result is non-zero (handle absent)',
        () {
      final payload = Uint8List(4);
      ByteData.sublistView(payload).setUint32(0, 0x701, Endian.little);
      final decoded = decodeAddNotificationResponse(payload);
      expect(decoded.result, 0x701);
      expect(decoded.handle, 0);
    });

    test('throws when a success payload is truncated below 8 bytes', () {
      final payload = Uint8List(4); // result==0 but no handle
      expect(
        () => decodeAddNotificationResponse(payload),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });

  group('decodeDeleteNotificationResponse', () {
    test('reads the result u32', () {
      final payload = Uint8List(4);
      ByteData.sublistView(payload).setUint32(0, 0x752, Endian.little);
      expect(decodeDeleteNotificationResponse(payload), 0x752);
    });

    test('throws on a payload shorter than 4 bytes', () {
      expect(
        () => decodeDeleteNotificationResponse(Uint8List(2)),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });
}
