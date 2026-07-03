@Tags(['unit', 'golden'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/ams_header.dart';
import 'package:dart_ads/src/protocol/ams_net_id.dart';
import 'package:dart_ads/src/protocol/ams_tcp_header.dart';
import 'package:dart_ads/src/protocol/commands.dart';
import 'package:dart_ads/src/protocol/constants.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

// ---------------------------------------------------------------------------
// Fixture identities — byte-for-byte the same values dump_golden.cpp baked into
// the committed goldens (target 192.168.0.1.1.1:851, source
// 192.168.0.100.1.1:40001, invokeId 1).
// ---------------------------------------------------------------------------
final AmsAddr _target =
    AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3);
final AmsAddr _source = AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001);
const int _invokeId = 1;

/// Little-endian u32 as a 4-byte [Uint8List] — used for sample request/response
/// data blobs.
Uint8List _u32le(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

/// Strips the 6-byte AMS/TCP wrapper + 32-byte AMS header off a full golden
/// response [frame] and returns the trailing ADS payload, asserting the wrapper
/// length, command id, response state flags, and dataLength are self-consistent.
Uint8List _adsResponsePayload(Uint8List frame, int expectedCommandId) {
  final tcp = AmsTcpHeader.decode(ByteData.sublistView(frame));
  expect(tcp.length, equals(frame.length - AmsTcpHeader.byteLength),
      reason: 'AMS/TCP length must equal the trailing byte count');

  final ams =
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);
  expect(ams.commandId, equals(expectedCommandId));
  expect(ams.stateFlags, equals(AmsStateFlags.response));

  const payloadStart = AmsTcpHeader.byteLength + AmsHeader.byteLength;
  expect(ams.dataLength, equals(frame.length - payloadStart),
      reason: 'AMS dataLength must equal the ADS payload length');
  return frame.sublist(payloadStart);
}

void main() {
  group('encode(request) == committed golden', () {
    test('ReadDeviceInfo', () {
      final frame = encodeReadDeviceInfoRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
      );
      expect(frame, equals(readGolden('test/golden/read_device_info_req.hex')));
      // The verified 38-byte anchor with AMS/TCP length field == 0x20 (32).
      expect(frame.length, equals(38));
      expect(frame[2], equals(0x20));
    });

    test('Read', () {
      final frame = encodeReadRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
        indexGroup: 0xF005,
        indexOffset: 0x123,
        length: 4,
      );
      expect(frame, equals(readGolden('test/golden/read_req.hex')));
    });

    test('Write', () {
      final frame = encodeWriteRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
        indexGroup: 0xF005,
        indexOffset: 0x123,
        data: _u32le(42),
      );
      expect(frame, equals(readGolden('test/golden/write_req.hex')));
    });

    test('ReadState', () {
      final frame = encodeReadStateRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
      );
      expect(frame, equals(readGolden('test/golden/read_state_req.hex')));
    });

    test('WriteControl', () {
      final frame = encodeWriteControlRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
        adsState: AdsState.run, // 5
        deviceState: 0,
      );
      expect(frame, equals(readGolden('test/golden/write_control_req.hex')));
    });

    test('ReadWrite', () {
      final frame = encodeReadWriteRequest(
        target: _target,
        source: _source,
        invokeId: _invokeId,
        indexGroup: 0xF003,
        indexOffset: 0,
        readLength: 4,
        writeData: Uint8List.fromList('MAIN.foo'.codeUnits),
      );
      expect(frame, equals(readGolden('test/golden/read_write_req.hex')));
    });
  });

  group('decode(golden response) == expected typed values', () {
    test('ReadDeviceInfo', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/read_device_info_res.hex'),
        AdsCommandId.readDeviceInfo,
      );
      final res = decodeReadDeviceInfoResponse(payload);
      expect(res.result, equals(0));
      expect(res.version, equals(3));
      expect(res.revision, equals(1));
      expect(res.build, equals(4024));
      expect(res.name, equals('Dart ADS Mock'));
    });

    test('Read', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/read_res.hex'),
        AdsCommandId.read,
      );
      final res = decodeReadResponse(payload);
      expect(res.result, equals(0));
      expect(res.readLength, equals(4));
      expect(res.data, equals(_u32le(42)));
    });

    test('Write', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/write_res.hex'),
        AdsCommandId.write,
      );
      final res = decodeWriteResponse(payload);
      expect(res.result, equals(0));
    });

    test('ReadState', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/read_state_res.hex'),
        AdsCommandId.readState,
      );
      final res = decodeReadStateResponse(payload);
      expect(res.result, equals(0));
      expect(res.adsState, equals(AdsState.run)); // 5
      expect(res.deviceState, equals(0));
    });

    test('WriteControl', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/write_control_res.hex'),
        AdsCommandId.writeControl,
      );
      final res = decodeWriteControlResponse(payload);
      expect(res.result, equals(0));
    });

    test('ReadWrite', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/read_write_res.hex'),
        AdsCommandId.readWrite,
      );
      final res = decodeReadWriteResponse(payload);
      expect(res.result, equals(0));
      expect(res.readLength, equals(4));
      expect(res.data, equals(_u32le(0x80000001)));
    });
  });

  group('encoder range validation (WR-04)', () {
    test('out-of-range integer fields throw instead of silently truncating',
        () {
      // ByteData.setUint32 stores only the low 32 bits, so without validation
      // these would emit well-formed frames carrying WRONG field values.
      expect(
        () => encodeReadRequest(
          target: _target,
          source: _source,
          invokeId: _invokeId,
          indexGroup: 0xF005,
          indexOffset: 0x123,
          length: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeReadRequest(
          target: _target,
          source: _source,
          invokeId: _invokeId,
          indexGroup: 0x100000000, // 33 bits
          indexOffset: 0,
          length: 4,
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeReadDeviceInfoRequest(
          target: _target,
          source: _source,
          invokeId: 0x100000000, // 33-bit invoke-id counter wrap
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeWriteControlRequest(
          target: _target,
          source: _source,
          invokeId: _invokeId,
          adsState: 0x10000, // 17 bits: would truncate to 0
          deviceState: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeReadWriteRequest(
          target: _target,
          source: _source,
          invokeId: _invokeId,
          indexGroup: 0xF003,
          indexOffset: 0,
          readLength: -4,
          writeData: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });
  });
}
