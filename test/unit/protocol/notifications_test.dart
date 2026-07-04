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

/// One sample: (handle, data).
typedef _Sample = ({int handle, List<int> data});

/// One stamp: (filetime ticks, samples).
typedef _Stamp = ({int ticks, List<_Sample> samples});

/// Builds a nested 0x08 notification-stream payload from [stamps], writing the
/// self-describing leading `length` field (= payload.length - 4) when
/// [selfDescribing] is true. Set it false to craft a length-mismatch frame.
Uint8List _buildStream(List<_Stamp> stamps, {bool selfDescribing = true}) {
  final body = BytesBuilder();
  final stampCount = ByteData(4)..setUint32(0, stamps.length, Endian.little);
  body.add(stampCount.buffer.asUint8List());
  for (final stamp in stamps) {
    final hdr = ByteData(12)
      ..setUint64(0, stamp.ticks, Endian.little)
      ..setUint32(8, stamp.samples.length, Endian.little);
    body.add(hdr.buffer.asUint8List());
    for (final sample in stamp.samples) {
      final sh = ByteData(8)
        ..setUint32(0, sample.handle, Endian.little)
        ..setUint32(4, sample.data.length, Endian.little);
      body.add(sh.buffer.asUint8List());
      body.add(Uint8List.fromList(sample.data));
    }
  }
  final bodyBytes = body.toBytes();
  final out = BytesBuilder();
  final len = ByteData(4)
    ..setUint32(
        0, selfDescribing ? bodyBytes.length : bodyBytes.length + 1, Endian.little);
  out.add(len.buffer.asUint8List());
  out.add(bodyBytes);
  return out.toBytes();
}

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
          maxDelay100ns: 0x100000000,
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
          cycleTime100ns: 0x100000000,
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

  group('parseNotificationStream', () {
    final ftA = dateTimeToFiletime(DateTime.utc(2026, 1, 1, 0, 0, 0));
    final ftB = dateTimeToFiletime(DateTime.utc(2026, 1, 1, 0, 0, 1));

    test('parses a nested 2-stamp x 2-sample frame into 4 notifications', () {
      final payload = _buildStream([
        (ticks: ftA, samples: [
          (handle: 10, data: [0xAA]),
          (handle: 11, data: [0xBB, 0xCC]),
        ]),
        (ticks: ftB, samples: [
          (handle: 20, data: [0x01, 0x02, 0x03]),
          (handle: 21, data: [0x04]),
        ]),
      ]);

      final notes = parseNotificationStream(payload);
      expect(notes.length, 4);

      // Stamp 0 samples share stamp-0's timestamp.
      expect(notes[0].handle, 10);
      expect(notes[0].timestamp, filetimeToDateTime(ftA));
      expect(notes[0].data, [0xAA]);
      expect(notes[1].handle, 11);
      expect(notes[1].timestamp, filetimeToDateTime(ftA));
      expect(notes[1].data, [0xBB, 0xCC]);

      // Stamp 1 samples share stamp-1's (distinct) timestamp.
      expect(notes[2].handle, 20);
      expect(notes[2].timestamp, filetimeToDateTime(ftB));
      expect(notes[2].data, [0x01, 0x02, 0x03]);
      expect(notes[3].handle, 21);
      expect(notes[3].timestamp, filetimeToDateTime(ftB));
      expect(notes[3].data, [0x04]);

      expect(notes[0].timestamp, isNot(notes[2].timestamp));
    });

    test('sample data is a defensive copy that does not alias the input', () {
      final payload = _buildStream([
        (ticks: ftA, samples: [
          (handle: 1, data: [0x7F]),
        ]),
      ]);
      final notes = parseNotificationStream(payload);
      final dataOffset = payload.length - 1;
      payload[dataOffset] = 0x00; // mutate the source buffer after parsing
      expect(notes.single.data, [0x7F], reason: 'must not alias the frame');
    });

    test('parses a single 1x1 frame into 1 notification', () {
      final payload = _buildStream([
        (ticks: ftA, samples: [
          (handle: 42, data: [0xDE, 0xAD]),
        ]),
      ]);
      final notes = parseNotificationStream(payload);
      expect(notes.length, 1);
      expect(notes.single.handle, 42);
      expect(notes.single.data, [0xDE, 0xAD]);
    });

    test('yields an empty list when stamps == 0', () {
      final payload = _buildStream(const []);
      expect(parseNotificationStream(payload), isEmpty);
    });

    test('throws when payload.length < 8', () {
      expect(
        () => parseNotificationStream(Uint8List(4)),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('throws when length + 4 != payload.length', () {
      final payload = _buildStream([
        (ticks: ftA, samples: [
          (handle: 1, data: [0x01]),
        ]),
      ], selfDescribing: false);
      expect(
        () => parseNotificationStream(payload),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('throws on a stamp header that overruns the buffer', () {
      // stamps=1 but only 4 bytes of stamp header present (needs 12).
      final body = BytesBuilder();
      body.add((ByteData(4)..setUint32(0, 1, Endian.little)).buffer.asUint8List());
      body.add(Uint8List(4)); // truncated stamp header
      final bodyBytes = body.toBytes();
      final out = BytesBuilder();
      out.add((ByteData(4)..setUint32(0, bodyBytes.length, Endian.little))
          .buffer
          .asUint8List());
      out.add(bodyBytes);
      expect(
        () => parseNotificationStream(out.toBytes()),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('throws on a sample whose size exceeds the remaining bytes', () {
      // One stamp, one sample declaring size 100 with no data bytes present.
      final body = BytesBuilder();
      body.add((ByteData(4)..setUint32(0, 1, Endian.little)).buffer.asUint8List());
      body.add((ByteData(12)
            ..setUint64(0, ftA, Endian.little)
            ..setUint32(8, 1, Endian.little))
          .buffer
          .asUint8List());
      body.add((ByteData(8)
            ..setUint32(0, 5, Endian.little) // handle
            ..setUint32(4, 100, Endian.little)) // size = 100, but no data
          .buffer
          .asUint8List());
      final bodyBytes = body.toBytes();
      final out = BytesBuilder();
      out.add((ByteData(4)..setUint32(0, bodyBytes.length, Endian.little))
          .buffer
          .asUint8List());
      out.add(bodyBytes);
      expect(
        () => parseNotificationStream(out.toBytes()),
        throwsA(isA<MalformedFrameException>()),
      );
    });
  });
}
