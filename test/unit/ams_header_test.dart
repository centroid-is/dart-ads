@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/ams_header.dart';
import 'package:dart_ads/src/protocol/ams_net_id.dart';
import 'package:dart_ads/src/protocol/ams_tcp_header.dart';
import 'package:dart_ads/src/protocol/constants.dart';
import 'package:dart_ads/src/protocol/exceptions.dart';
import 'package:test/test.dart';

/// The RESEARCH-verified anchor: a zero-payload ReadDeviceInfo request.
///
/// target 192.168.0.1.1.1:851, source 192.168.0.100.1.1:40001, invokeId 1.
/// Raw 38-byte frame produced by the reference C++ dumper:
///   000020000000c0a8000101015303c0a800640101419c01000400000000000000000001000000
///
/// Offsets 0..5 are the AMS/TCP wrapper; offsets 6..37 are the 32-byte AMS
/// header asserted below.
final Uint8List _anchorAmsHeaderBytes = Uint8List.fromList([
  0xc0, 0xa8, 0x00, 0x01, 0x01, 0x01, // targetNetId 192.168.0.1.1.1
  0x53, 0x03, //                          targetPort 851
  0xc0, 0xa8, 0x00, 0x64, 0x01, 0x01, // sourceNetId 192.168.0.100.1.1
  0x41, 0x9c, //                          sourcePort 40001
  0x01, 0x00, //                          commandId 0x0001 ReadDeviceInfo
  0x04, 0x00, //                          stateFlags 0x0004 request
  0x00, 0x00, 0x00, 0x00, //              dataLength 0
  0x00, 0x00, 0x00, 0x00, //              errorCode 0
  0x01, 0x00, 0x00, 0x00, //              invokeId 1
]);

AmsHeader _anchorHeader() => AmsHeader(
      targetNetId: AmsNetId.parse('192.168.0.1.1.1'),
      targetPort: AmsPort.plcTc3,
      sourceNetId: AmsNetId.parse('192.168.0.100.1.1'),
      sourcePort: 40001,
      commandId: AdsCommandId.readDeviceInfo,
      stateFlags: AmsStateFlags.request,
      dataLength: 0,
      errorCode: 0,
      invokeId: 1,
    );

void main() {
  group('AmsNetId', () {
    test('round-trips 6 bytes via .bytes', () {
      final id = AmsNetId([192, 168, 0, 1, 1, 1]);
      expect(id.bytes, equals(Uint8List.fromList([192, 168, 0, 1, 1, 1])));
    });

    test('dotted-string factory parses to the same bytes', () {
      final id = AmsNetId.parse('192.168.0.1.1.1');
      expect(id.bytes, equals(Uint8List.fromList([192, 168, 0, 1, 1, 1])));
    });

    test('rejects a 5-byte list', () {
      expect(
        () => AmsNetId([1, 2, 3, 4, 5]),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('rejects a 7-byte list', () {
      expect(
        () => AmsNetId([1, 2, 3, 4, 5, 6, 7]),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('value equality: equal bytes compare equal', () {
      expect(
        AmsNetId([192, 168, 0, 1, 1, 1]),
        equals(AmsNetId([192, 168, 0, 1, 1, 1])),
      );
      expect(
        AmsNetId([192, 168, 0, 1, 1, 1]).hashCode,
        equals(AmsNetId([192, 168, 0, 1, 1, 1]).hashCode),
      );
      expect(
        AmsNetId([192, 168, 0, 1, 1, 1]) == AmsNetId([192, 168, 0, 100, 1, 1]),
        isFalse,
      );
    });

    test('.bytes view is unmodifiable', () {
      final id = AmsNetId([1, 2, 3, 4, 5, 6]);
      expect(() => id.bytes[0] = 9, throwsUnsupportedError);
    });
  });

  group('AmsTcpHeader', () {
    test('byteLength is 6', () {
      expect(AmsTcpHeader.byteLength, equals(6));
    });

    test('encode(length: 32) yields 00 00 20 00 00 00', () {
      final bytes = const AmsTcpHeader(length: 32).encode();
      expect(
        bytes,
        equals(Uint8List.fromList([0x00, 0x00, 0x20, 0x00, 0x00, 0x00])),
      );
    });

    test('decode recovers length == 32', () {
      final bd = ByteData.sublistView(
        Uint8List.fromList([0x00, 0x00, 0x20, 0x00, 0x00, 0x00]),
      );
      expect(AmsTcpHeader.decode(bd).length, equals(32));
    });

    test('encode -> decode round-trips length', () {
      const original = AmsTcpHeader(length: 0xDEADBEEF);
      final decoded = AmsTcpHeader.decode(
        ByteData.sublistView(original.encode()),
      );
      expect(decoded.length, equals(0xDEADBEEF));
      expect(decoded, equals(original));
    });

    test('decode honors a non-zero offset', () {
      final buf = Uint8List(8)
        ..setRange(2, 8, const AmsTcpHeader(length: 32).encode());
      final decoded = AmsTcpHeader.decode(ByteData.sublistView(buf), 2);
      expect(decoded.length, equals(32));
    });
  });

  group('AmsHeader', () {
    test('byteLength is 32', () {
      expect(AmsHeader.byteLength, equals(32));
    });

    test('anchor header encodes to the verified 32 bytes', () {
      expect(_anchorHeader().encode(), equals(_anchorAmsHeaderBytes));
    });

    test('encode -> decode round-trips all fields', () {
      final header = _anchorHeader();
      final decoded = AmsHeader.decode(ByteData.sublistView(header.encode()));
      expect(decoded.targetNetId, equals(header.targetNetId));
      expect(decoded.targetPort, equals(header.targetPort));
      expect(decoded.sourceNetId, equals(header.sourceNetId));
      expect(decoded.sourcePort, equals(header.sourcePort));
      expect(decoded.commandId, equals(header.commandId));
      expect(decoded.stateFlags, equals(header.stateFlags));
      expect(decoded.dataLength, equals(header.dataLength));
      expect(decoded.errorCode, equals(header.errorCode));
      expect(decoded.invokeId, equals(header.invokeId));
      expect(decoded, equals(header));
    });

    test('decode of the anchor bytes yields the anchor field values', () {
      final decoded = AmsHeader.decode(
        ByteData.sublistView(_anchorAmsHeaderBytes),
      );
      expect(decoded.targetNetId, equals(AmsNetId.parse('192.168.0.1.1.1')));
      expect(decoded.targetPort, equals(851));
      expect(decoded.sourceNetId, equals(AmsNetId.parse('192.168.0.100.1.1')));
      expect(decoded.sourcePort, equals(40001));
      expect(decoded.commandId, equals(AdsCommandId.readDeviceInfo));
      expect(decoded.stateFlags, equals(AmsStateFlags.request));
      expect(decoded.dataLength, equals(0));
      expect(decoded.errorCode, equals(0));
      expect(decoded.invokeId, equals(1));
    });

    test('asymmetric multi-byte fields are little-endian on the wire', () {
      // 40001 = 0x9C41 -> LE bytes 41 9C at the sourcePort offset (14).
      final bytes = _anchorHeader().encode();
      expect(bytes[14], equals(0x41));
      expect(bytes[15], equals(0x9c));
    });

    test('decode honors a non-zero offset', () {
      final buf = Uint8List(6 + AmsHeader.byteLength)
        ..setRange(6, 6 + AmsHeader.byteLength, _anchorAmsHeaderBytes);
      final decoded = AmsHeader.decode(ByteData.sublistView(buf), 6);
      expect(decoded, equals(_anchorHeader()));
    });

    test(
        'decode never escapes a short ByteData view, even when the backing '
        'buffer holds more bytes past the view (WR-03)', () {
      // A 16-byte clamped view over a 64-byte backing buffer whose bytes
      // BEYOND the view would decode as a plausible header. Reads must be
      // range-checked against the view, not the buffer, so this throws the
      // typed exception — never a RangeError, never a garbage header built
      // from adjacent buffer contents.
      final backing = Uint8List(64)
        ..setRange(0, _anchorAmsHeaderBytes.length, _anchorAmsHeaderBytes);
      final shortView = ByteData.sublistView(backing, 0, 16);

      expect(
        () => AmsHeader.decode(shortView),
        throwsA(isA<MalformedFrameException>()
            .having((e) => e.length, 'length', 16)),
        reason: '16 available bytes < the required 32 must be a typed error',
      );

      // Same guard for a non-zero offset that leaves too few view bytes.
      final fullView = ByteData.sublistView(backing, 0, AmsHeader.byteLength);
      expect(
        () => AmsHeader.decode(fullView, 6),
        throwsA(isA<MalformedFrameException>()),
        reason: 'offset 6 leaves 26 view bytes < 32',
      );
    });
  });
}
