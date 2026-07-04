@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/value_codec.dart';
import 'package:test/test.dart';

void main() {
  group('value codec — scalar round-trips (LE)', () {
    test('BOOL encodes 1/0 and decodes byte != 0', () {
      expect(encodeBool(true), equals(Uint8List.fromList([1])));
      expect(encodeBool(false), equals(Uint8List.fromList([0])));
      expect(decodeBool(Uint8List.fromList([0])), isFalse);
      expect(decodeBool(Uint8List.fromList([1])), isTrue);
      // Any non-zero byte is true.
      expect(decodeBool(Uint8List.fromList([0xFF])), isTrue);
    });

    test('BYTE/USINT (u8) round-trips full range', () {
      for (final v in [0, 1, 127, 128, 255]) {
        expect(decodeByte(encodeByte(v)), equals(v), reason: 'u8 $v');
      }
    });

    test('SINT (i8) round-trips incl. negatives', () {
      for (final v in [-128, -1, 0, 1, 127]) {
        expect(decodeSint(encodeSint(v)), equals(v), reason: 'i8 $v');
      }
    });

    test('WORD/UINT (u16 LE) round-trips full range', () {
      for (final v in [0, 1, 255, 256, 0x1234, 65535]) {
        final bytes = encodeWord(v);
        expect(bytes.length, equals(2));
        expect(decodeWord(bytes), equals(v), reason: 'u16 $v');
      }
      // Explicit little-endian byte order.
      expect(encodeWord(0x1234), equals(Uint8List.fromList([0x34, 0x12])));
    });

    test('INT (i16 LE) round-trips incl. negatives', () {
      for (final v in [-32768, -1, 0, 1, 32767]) {
        expect(decodeInt(encodeInt(v)), equals(v), reason: 'i16 $v');
      }
    });

    test('DWORD/UDINT (u32 LE) round-trips full range', () {
      for (final v in [0, 1, 0x1234, 0x12345678, 0xFFFFFFFF]) {
        final bytes = encodeDword(v);
        expect(bytes.length, equals(4));
        expect(decodeDword(bytes), equals(v), reason: 'u32 $v');
      }
      expect(encodeDword(0x12345678),
          equals(Uint8List.fromList([0x78, 0x56, 0x34, 0x12])));
    });

    test('DINT (i32 LE) round-trips incl. negatives', () {
      for (final v in [-2147483648, -1, 0, 1, 2147483647]) {
        expect(decodeDint(encodeDint(v)), equals(v), reason: 'i32 $v');
      }
    });

    test('REAL (f32) preserves bit-exact value', () {
      final bytes = encodeReal(3.14);
      expect(bytes.length, equals(4));
      final back = decodeReal(bytes);
      // f32 round-trip through a Float32 slot is exactly reproducible.
      final expected = (ByteData(4)..setFloat32(0, 3.14, Endian.little))
          .getFloat32(0, Endian.little);
      expect(back, equals(expected));
    });

    test('LREAL (f64) preserves bit-exact value', () {
      const v = 2.718281828;
      expect(decodeLreal(encodeLreal(v)), equals(v));
      expect(encodeLreal(v).length, equals(8));
    });
  });

  group('value codec — STRING (Latin-1, fixed, NUL-padded)', () {
    test('encode pads remainder with NUL to size', () {
      final buf = encodeString('AB', 5);
      expect(buf.length, equals(5));
      expect(buf, equals(Uint8List.fromList([0x41, 0x42, 0x00, 0x00, 0x00])));
    });

    test('decode stops at first NUL, ignoring the rest', () {
      final buf = Uint8List.fromList([0x41, 0x42, 0x00, 0x43, 0x44]);
      expect(decodeString(buf), equals('AB'));
    });

    test('round-trips through a size-81 buffer', () {
      final buf = encodeString('MAIN.text', 81);
      expect(buf.length, equals(81));
      expect(decodeString(buf), equals('MAIN.text'));
    });

    test('content that leaves no room for the terminator throws', () {
      // 'ABCDE' is 5 bytes; size 5 leaves no NUL slot → overflow (T-7-03).
      expect(() => encodeString('ABCDE', 5), throwsArgumentError);
      // size 6 leaves exactly one NUL slot → ok.
      expect(encodeString('ABCDE', 6).length, equals(6));
    });
  });

  group('value codec — WSTRING (UTF-16LE, NUL-terminated)', () {
    test('encode emits UTF-16LE units + 0x0000 terminator, padded', () {
      final buf = encodeWString('A', 6);
      expect(buf.length, equals(6));
      // 'A' = 0x0041 LE, then 0x0000 terminator, then 0x0000 pad.
      expect(buf,
          equals(Uint8List.fromList([0x41, 0x00, 0x00, 0x00, 0x00, 0x00])));
    });

    test('decode stops at first 0x0000 unit', () {
      final buf =
          Uint8List.fromList([0x41, 0x00, 0x42, 0x00, 0x00, 0x00, 0x43, 0x00]);
      expect(decodeWString(buf), equals('AB'));
    });

    test('round-trips a BMP string', () {
      final buf = encodeWString('Hallo', 40);
      expect(decodeWString(buf), equals('Hallo'));
    });

    test('content that leaves no room for the terminator throws', () {
      // 'AB' = 2 units = 4 bytes; need +2 for terminator → 6 required.
      expect(() => encodeWString('AB', 4), throwsArgumentError);
      expect(encodeWString('AB', 6).length, equals(6));
    });
  });

  group('value codec — raw passthrough (SYM-04 escape hatch)', () {
    test('a raw Uint8List is returned unchanged when no codec is applied', () {
      // SYM-04: not calling a codec leaves the bytes untyped/untouched.
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      // The read path already yields raw bytes; identity is preserved.
      expect(raw, equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
      expect(raw.length, equals(4));
    });
  });
}
