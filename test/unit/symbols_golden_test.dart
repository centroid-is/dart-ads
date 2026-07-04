@Tags(['unit', 'golden'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/ams_header.dart';
import 'package:dart_ads/src/protocol/ams_net_id.dart';
import 'package:dart_ads/src/protocol/ams_tcp_header.dart';
import 'package:dart_ads/src/protocol/commands.dart';
import 'package:dart_ads/src/protocol/constants.dart';
import 'package:dart_ads/src/protocol/symbols.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

// ---------------------------------------------------------------------------
// Fixture identities — byte-for-byte the same values dump_golden.cpp baked into
// the committed symbol goldens (target 192.168.0.1.1.1:851, source
// 192.168.0.100.1.1:40001, invokeId 1). A response INVERTS this addressing.
// ---------------------------------------------------------------------------
final AmsAddr _target =
    AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3);
final AmsAddr _source = AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001);

/// Strips the 6-byte AMS/TCP wrapper + 32-byte AMS header off a full golden
/// response [frame] and returns the trailing ADS payload, asserting the wrapper
/// length, command id, response state flags, inverted addressing, and
/// dataLength are self-consistent (mirrors golden_parity_test's helper).
Uint8List _adsResponsePayload(Uint8List frame, int expectedCommandId) {
  final tcp = AmsTcpHeader.decode(ByteData.sublistView(frame));
  expect(tcp.length, equals(frame.length - AmsTcpHeader.byteLength),
      reason: 'AMS/TCP length must equal the trailing byte count');

  final ams =
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);
  expect(ams.commandId, equals(expectedCommandId));
  expect(ams.stateFlags, equals(AmsStateFlags.response));

  // A response travels TO the original source (client) FROM the original
  // target (PLC): the request addressing is inverted (WR-06).
  expect(ams.targetNetId, equals(_source.netId));
  expect(ams.targetPort, equals(_source.port));
  expect(ams.sourceNetId, equals(_target.netId));
  expect(ams.sourcePort, equals(_target.port));

  const payloadStart = AmsTcpHeader.byteLength + AmsHeader.byteLength;
  expect(ams.dataLength, equals(frame.length - payloadStart),
      reason: 'AMS dataLength must equal the ADS payload length');
  return frame.sublist(payloadStart);
}

/// Reads a little-endian u32 out of [bytes] at [offset].
int _u32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

void main() {
  group('symbol upload golden', () {
    test('parseSymbolBlob reproduces the committed 2-symbol blob byte-for-byte',
        () {
      // The 0xF00B upload blob is a Read response: strip the frame, then the
      // ReadResponse envelope (result + readLength) to reach the raw blob.
      final payload = _adsResponsePayload(
        readGolden('test/golden/sym_upload_blob.hex'),
        AdsCommandId.read,
      );
      final res = decodeReadResponse(payload);
      expect(res.result, equals(0));
      // The blob is 110 bytes: entry 0 (MAIN.counter) padded 62->64, entry 1
      // (MAIN.flag) 46 — proving the parser advances by entryLength.
      expect(res.readLength, equals(110));
      expect(res.data, hasLength(110));

      final symbols = parseSymbolBlob(res.data, 2);
      expect(symbols, hasLength(2));

      // Entry 0 — the padded entry (entryLength 62 -> 64, 2 trailing zeros).
      final counter = symbols[0];
      expect(counter.name, equals('MAIN.counter'));
      expect(counter.typeName, equals('DINT'));
      expect(counter.comment, equals('cycle counter'));
      expect(counter.indexGroup, equals(0x4020));
      expect(counter.indexOffset, equals(0x00));
      expect(counter.size, equals(4));
      expect(counter.dataTypeId, equals(3));
      expect(counter.flags, equals(0));

      // Entry 1 — reached only if the parser advanced by entry 0's padded
      // entryLength (64), not by its summed field sizes (62).
      final flag = symbols[1];
      expect(flag.name, equals('MAIN.flag'));
      expect(flag.typeName, equals('BOOL'));
      expect(flag.comment, isEmpty);
      expect(flag.indexGroup, equals(0x4020));
      expect(flag.indexOffset, equals(0x04));
      expect(flag.size, equals(1));
      expect(flag.dataTypeId, equals(33));
      expect(flag.flags, equals(0));
    });

    test('SYM_UPLOADINFO golden decodes to {nSymbols, nSymSize}', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/sym_uploadinfo_res.hex'),
        AdsCommandId.read,
      );
      final res = decodeReadResponse(payload);
      expect(res.result, equals(0));
      expect(res.readLength, equals(8));
      expect(res.data, hasLength(8));

      final nSymbols = _u32le(res.data, 0);
      final nSymSize = _u32le(res.data, 4);
      expect(nSymbols, equals(2));
      // nSymSize is the exact byte count of the committed upload blob.
      expect(nSymSize, equals(110));
    });
  });

  group('handle golden', () {
    test('SYM_HNDBYNAME response carries the 4-byte LE handle', () {
      // 0xF003 GET_SYMHANDLE_BYNAME is a ReadWrite command: the 4-byte handle
      // rides in the ReadWrite response data region.
      final payload = _adsResponsePayload(
        readGolden('test/golden/sym_handle_res.hex'),
        AdsCommandId.readWrite,
      );
      final res = decodeReadWriteResponse(payload);
      expect(res.result, equals(0));
      expect(res.readLength, equals(4));
      expect(res.data, hasLength(4));
      expect(_u32le(res.data, 0), equals(0x00000123));
    });
  });
}
