@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:dart_ads/src/protocol/frame_assembler.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

// ---------------------------------------------------------------------------
// Real golden frames off the wire (produced by dump_golden.cpp, committed by
// plan 01-02). We reassemble these exact bytes — never synthetic frames — so
// the tests prove recovery against genuine AMS/TCP framing.
//
//   frameA: ReadDeviceInfo request  — 38 bytes (AMS/TCP length field = 32)
//   frameB: Read response           — 50 bytes (AMS/TCP length field = 44)
// ---------------------------------------------------------------------------
final Uint8List frameA = readGolden('test/golden/read_device_info_req.hex');
final Uint8List frameB = readGolden('test/golden/read_res.hex');

/// Concatenates byte buffers into one contiguous [Uint8List].
Uint8List _cat(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (sum, p) => sum + p.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

void main() {
  // Sanity: the goldens are the sizes the reassembly math assumes. A frame's
  // total on-wire size is `6 + <AMS/TCP length field>`.
  setUpAll(() {
    expect(frameA.length, equals(38),
        reason: 'ReadDeviceInfo req golden must be 6 + 32 bytes');
    expect(frameB.length, equals(50),
        reason: 'Read res golden must be 6 + 44 bytes');
  });

  group('FrameAssembler adversarial reassembly', () {
    test(
        'Fragmentation: a golden fed one byte at a time emits nothing until '
        'the final byte, then exactly one frame equal to the golden', () {
      final assembler = FrameAssembler();
      final emitted = <Uint8List>[];

      for (var i = 0; i < frameA.length; i++) {
        final frames = assembler.add(Uint8List.fromList(<int>[frameA[i]]));
        if (i < frameA.length - 1) {
          // Nothing may emit while the frame is still incomplete.
          expect(frames, isEmpty,
              reason: 'no frame may emit after byte ${i + 1}/${frameA.length}');
        }
        emitted.addAll(frames);
      }

      expect(emitted, hasLength(1),
          reason: 'exactly one frame reassembles from the fragments');
      expect(emitted.single, orderedEquals(frameA),
          reason: 'reassembled frame must be byte-equal to the golden');
      expect(assembler.hasBufferedBytes, isFalse,
          reason: 'buffer is empty once the frame is consumed');
    });

    test(
        'Coalescing: two goldens in a single chunk emit two complete frames '
        'in order, each byte-equal to its source', () {
      final assembler = FrameAssembler();

      final frames = assembler.add(_cat(<Uint8List>[frameA, frameB]));

      expect(frames, hasLength(2), reason: 'both coalesced frames must emit');
      expect(frames[0], orderedEquals(frameA),
          reason: 'first emitted frame is frame A');
      expect(frames[1], orderedEquals(frameB),
          reason: 'second emitted frame is frame B');
      expect(assembler.hasBufferedBytes, isFalse,
          reason: 'nothing left buffered after both frames emit');
    });

    test(
        'Mixed: [full A][first half of B] emits A on call 1; the rest of B '
        'emits B on call 2', () {
      final assembler = FrameAssembler();
      final splitAt = frameB.length ~/ 2;
      final firstHalfB = Uint8List.sublistView(frameB, 0, splitAt);
      final secondHalfB = Uint8List.sublistView(frameB, splitAt);

      final call1 = assembler.add(_cat(<Uint8List>[frameA, firstHalfB]));
      expect(call1, hasLength(1), reason: 'call 1 emits only the full frame A');
      expect(call1.single, orderedEquals(frameA));
      expect(assembler.hasBufferedBytes, isTrue,
          reason: 'the partial frame B is retained');

      final call2 = assembler.add(Uint8List.fromList(secondHalfB));
      expect(call2, hasLength(1), reason: 'call 2 completes and emits frame B');
      expect(call2.single, orderedEquals(frameB));
      expect(assembler.hasBufferedBytes, isFalse,
          reason: 'buffer drains once frame B completes');
    });

    test(
        'Max-frame guard: a wrapper whose length u32 exceeds 4 MiB throws '
        'MalformedFrameException without allocating a giant buffer', () {
      final assembler = FrameAssembler();

      // Craft ONLY a 6-byte AMS/TCP wrapper: reserved u16 = 0, length u32 =
      // 0x00500000 (5 MiB) > the 4 MiB guard. No payload is supplied, proving
      // the guard fires on the length field alone — before any allocation.
      const hostileLength = 0x00500000;
      expect(hostileLength, greaterThan(4 * 1024 * 1024));
      final wrapper = Uint8List(6);
      ByteData.sublistView(wrapper)
        ..setUint16(0, 0, Endian.little)
        ..setUint32(2, hostileLength, Endian.little);

      expect(
        () => assembler.add(wrapper),
        throwsA(isA<MalformedFrameException>()
            .having((e) => e.length, 'length', hostileLength)),
        reason: 'oversized length must be rejected with a typed exception',
      );
    });

    test(
        'Poison after a complete frame: [full A][oversized wrapper] in one '
        'add returns A; the next add throws; the poison is dropped, not '
        're-scanned (WR-01)', () {
      final assembler = FrameAssembler();
      final poison = Uint8List(6);
      ByteData.sublistView(poison)
        ..setUint16(0, 0, Endian.little)
        ..setUint32(2, 0x00500000, Endian.little); // 5 MiB > 4 MiB guard

      // Frame A completed before the poison arrived in the SAME chunk — it
      // must be returned, never silently lost to the guard exception.
      final frames = assembler.add(_cat(<Uint8List>[frameA, poison]));
      expect(frames, hasLength(1),
          reason: 'the frame completed before the poison must not be lost');
      expect(frames.single, orderedEquals(frameA));

      // The deferred guard fires on the next add, even with no new bytes.
      expect(
        () => assembler.add(Uint8List(0)),
        throwsA(isA<MalformedFrameException>()
            .having((e) => e.length, 'length', 0x00500000)),
      );

      // The poisoned remainder was dropped with the throw, so feeding the
      // assembler again cannot re-scan the poison or grow the buffer
      // without bound.
      expect(assembler.hasBufferedBytes, isFalse,
          reason: 'the poisoned remainder is dropped when the guard throws');
      expect(assembler.add(Uint8List.fromList(frameA)).single,
          orderedEquals(frameA),
          reason: 'subsequent adds parse fresh bytes deterministically');
    });

    test(
        'Truncated: a frame missing its last byte emits nothing and throws no '
        'RangeError', () {
      final assembler = FrameAssembler();
      final truncated = Uint8List.sublistView(frameA, 0, frameA.length - 1);

      late final List<Uint8List> frames;
      expect(
        () => frames = assembler.add(Uint8List.fromList(truncated)),
        returnsNormally,
        reason: 'a short frame must never index past the buffer',
      );
      expect(frames, isEmpty, reason: 'no frame emits until the last byte');
      expect(assembler.hasBufferedBytes, isTrue,
          reason: 'the truncated frame stays buffered awaiting its final byte');

      // Delivering the final byte completes the frame — proof the buffered
      // truncation was fully recoverable.
      final completed =
          assembler.add(Uint8List.fromList(<int>[frameA[frameA.length - 1]]));
      expect(completed, hasLength(1));
      expect(completed.single, orderedEquals(frameA));
    });
  });
}
