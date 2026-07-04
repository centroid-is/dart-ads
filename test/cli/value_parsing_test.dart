import 'dart:typed_data';

import 'package:dart_ads/src/cli/value_parsing.dart';
import 'package:test/test.dart';

void main() {
  group('parseHex', () {
    test('accepts 0x prefix', () {
      expect(parseHex('0x0A0B'), equals(Uint8List.fromList([10, 11])));
    });

    test('accepts 0X prefix (upper-case)', () {
      expect(parseHex('0X0a0b'), equals(Uint8List.fromList([10, 11])));
    });

    test('tolerates internal whitespace', () {
      expect(parseHex('aa bb'), equals(Uint8List.fromList([170, 187])));
    });

    test('tolerates whitespace with prefix', () {
      expect(parseHex('0x aa  bb '), equals(Uint8List.fromList([170, 187])));
    });

    test('empty string yields empty bytes', () {
      expect(parseHex(''), equals(Uint8List(0)));
    });

    test('bare prefix yields empty bytes', () {
      expect(parseHex('0x'), equals(Uint8List(0)));
    });

    test('rejects non-hex digits (0xZZ)', () {
      expect(() => parseHex('0xZZ'), throwsFormatException);
    });

    test('rejects odd nibble count (abc)', () {
      expect(() => parseHex('abc'), throwsFormatException);
    });
  });

  group('formatHex', () {
    test('lower-case, 0x-prefixed', () {
      expect(formatHex(Uint8List.fromList([10, 187])), equals('0x0abb'));
    });

    test('empty bytes -> 0x', () {
      expect(formatHex(Uint8List(0)), equals('0x'));
    });

    test('round-trips with parseHex', () {
      final bytes = Uint8List.fromList([0, 1, 15, 16, 170, 255]);
      expect(parseHex(formatHex(bytes)), equals(bytes));
    });
  });

  group('encodeTypedValue', () {
    test('bool true -> [1]', () {
      expect(encodeTypedValue('bool', 'true'), equals(Uint8List.fromList([1])));
    });

    test('bool 0 -> [0]', () {
      expect(encodeTypedValue('bool', '0'), equals(Uint8List.fromList([0])));
    });

    test('bool is case-insensitive on type name', () {
      expect(
          encodeTypedValue('BOOL', 'false'), equals(Uint8List.fromList([0])));
    });

    test('dint -5 -> 4 LE bytes', () {
      expect(encodeTypedValue('dint', '-5'),
          equals(Uint8List.fromList([0xFB, 0xFF, 0xFF, 0xFF])));
    });

    test('real 1.5 -> 4 bytes', () {
      expect(encodeTypedValue('real', '1.5').length, equals(4));
    });

    test('string hi size 8 -> 8 NUL-padded bytes', () {
      final out = encodeTypedValue('string', 'hi', size: 8);
      expect(out.length, equals(8));
      expect(out.sublist(0, 2), equals(Uint8List.fromList([104, 105])));
      expect(out.sublist(2), equals(Uint8List(6)));
    });

    test('dint notanint -> FormatException', () {
      expect(() => encodeTypedValue('dint', 'notanint'), throwsFormatException);
    });

    test('word 70000 -> FormatException (out of u16 range)', () {
      expect(() => encodeTypedValue('word', '70000'), throwsFormatException);
    });

    test('word -1 -> FormatException (below u16 range)', () {
      expect(() => encodeTypedValue('word', '-1'), throwsFormatException);
    });

    test('byte 256 -> FormatException (out of u8 range)', () {
      expect(() => encodeTypedValue('byte', '256'), throwsFormatException);
    });

    test('sint 128 -> FormatException (out of i8 range)', () {
      expect(() => encodeTypedValue('sint', '128'), throwsFormatException);
    });

    test('int 40000 -> FormatException (out of i16 range)', () {
      expect(() => encodeTypedValue('int', '40000'), throwsFormatException);
    });

    test('dword -1 -> FormatException (out of u32 range)', () {
      expect(() => encodeTypedValue('dword', '-1'), throwsFormatException);
    });

    test('real notanumber -> FormatException', () {
      expect(
          () => encodeTypedValue('real', 'notanumber'), throwsFormatException);
    });

    test('bogus type -> FormatException', () {
      expect(() => encodeTypedValue('bogus', '1'), throwsFormatException);
    });

    test('string without size -> FormatException', () {
      expect(() => encodeTypedValue('string', 'hi'), throwsFormatException);
    });

    test('wstring without size -> FormatException', () {
      expect(() => encodeTypedValue('wstring', 'hi'), throwsFormatException);
    });

    test('string overflow -> FormatException (no truncation)', () {
      expect(() => encodeTypedValue('string', 'toolong', size: 4),
          throwsFormatException);
    });
  });

  group('decodeTypedValue', () {
    test('short buffer -> FormatException, never RangeError (dint)', () {
      expect(() => decodeTypedValue('dint', Uint8List.fromList([1, 2])),
          throwsFormatException);
    });

    test('short buffer -> FormatException (lreal needs 8)', () {
      expect(
          () => decodeTypedValue('lreal', Uint8List(4)), throwsFormatException);
    });

    test('empty buffer -> FormatException (word needs 2)', () {
      expect(
          () => decodeTypedValue('word', Uint8List(0)), throwsFormatException);
    });

    test('bogus type -> FormatException', () {
      expect(
          () => decodeTypedValue('bogus', Uint8List(4)), throwsFormatException);
    });
  });

  group('round-trip encode/decode per scalar', () {
    test('bool', () {
      expect(decodeTypedValue('bool', encodeTypedValue('bool', 'true')),
          equals('true'));
      expect(decodeTypedValue('bool', encodeTypedValue('bool', 'false')),
          equals('false'));
    });

    test('byte', () {
      expect(decodeTypedValue('byte', encodeTypedValue('byte', '200')),
          equals('200'));
    });

    test('sint', () {
      expect(decodeTypedValue('sint', encodeTypedValue('sint', '-5')),
          equals('-5'));
    });

    test('word', () {
      expect(decodeTypedValue('word', encodeTypedValue('word', '65000')),
          equals('65000'));
    });

    test('int', () {
      expect(decodeTypedValue('int', encodeTypedValue('int', '-100')),
          equals('-100'));
    });

    test('dword', () {
      expect(decodeTypedValue('dword', encodeTypedValue('dword', '4000000000')),
          equals('4000000000'));
    });

    test('dint', () {
      expect(decodeTypedValue('dint', encodeTypedValue('dint', '-5')),
          equals('-5'));
    });

    test('real', () {
      expect(decodeTypedValue('real', encodeTypedValue('real', '1.5')),
          equals('1.5'));
    });

    test('lreal', () {
      expect(decodeTypedValue('lreal', encodeTypedValue('lreal', '3.25')),
          equals('3.25'));
    });

    test('string', () {
      expect(
          decodeTypedValue(
              'string', encodeTypedValue('string', 'hello', size: 16)),
          equals('hello'));
    });

    test('wstring', () {
      expect(
          decodeTypedValue(
              'wstring', encodeTypedValue('wstring', 'héllo', size: 32)),
          equals('héllo'));
    });
  });

  group('parseHex strict digits (CR-01)', () {
    test('signed tokens throw FormatException', () {
      expect(() => parseHex('-1-1'), throwsFormatException);
      expect(() => parseHex('+f+f'), throwsFormatException);
      expect(() => parseHex('0x-1'), throwsFormatException);
    });
  });
}
