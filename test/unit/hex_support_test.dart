@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../support/hex.dart';

/// Writes [contents] to a fresh temp `.hex` file and returns its path.
String _writeHex(Directory dir, String name, String contents) {
  final file = File('${dir.path}/$name');
  file.writeAsStringSync(contents);
  return file.path;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart_ads_hex_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('readGolden', () {
    test('strips inline # comments and whitespace, decodes nibble pairs', () {
      final path = _writeHex(tempDir, 'comment.hex', '00 20# comment\n0000');
      final bytes = readGolden(path);
      expect(bytes, isA<Uint8List>());
      expect(bytes, equals(Uint8List.fromList([0x00, 0x20, 0x00, 0x00])));
    });

    test('a fully-commented / whitespace-only file yields an empty Uint8List',
        () {
      final path = _writeHex(
        tempDir,
        'empty.hex',
        '# only a comment\n   \n\t# another comment\n',
      );
      final bytes = readGolden(path);
      expect(bytes, isA<Uint8List>());
      expect(bytes, isEmpty);
    });

    test(
        'the 38-byte ReadDeviceInfo anchor round-trips with the documented '
        'leading bytes', () {
      const anchor = '000020000000c0a8000101015303c0a800640101419c0100'
          '0400000000000000000001000000';
      final path = _writeHex(tempDir, 'anchor.hex', anchor);
      final bytes = readGolden(path);
      expect(bytes.length, equals(38));
      // AMS/TCP: reserved u16 = 0x0000, length u32 low bytes 0x20, 0x00
      expect(
        bytes.sublist(0, 4),
        equals(Uint8List.fromList([0x00, 0x00, 0x20, 0x00])),
      );
    });

    test('anchor tolerates # comments interleaved with the hex payload', () {
      const annotated = '''
0000 20000000                 # AMS/TCP: reserved u16=0, length u32=0x20=32
c0a8000101 01 5303            # AMS: targetNetId + targetPort
c0a8006401 01 419c            # AMS: sourceNetId + sourcePort
0100 0400                     # cmdId ReadDeviceInfo, stateFlags request
00000000 00000000 01000000    # dataLength, errorCode, invokeId
''';
      final path = _writeHex(tempDir, 'annotated.hex', annotated);
      final bytes = readGolden(path);
      expect(bytes.length, equals(38));
      expect(bytes[0], equals(0x00));
      expect(bytes[2], equals(0x20));
    });
  });
}
