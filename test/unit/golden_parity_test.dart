@Tags(['unit', 'golden'])
library;

import 'dart:typed_data';

import 'package:dart_ads/src/protocol/ams_header.dart';
import 'package:dart_ads/src/protocol/ams_net_id.dart';
import 'package:dart_ads/src/protocol/ams_tcp_header.dart';
import 'package:dart_ads/src/protocol/commands.dart';
import 'package:dart_ads/src/protocol/constants.dart';
import 'package:dart_ads/src/protocol/notifications.dart';
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
/// length, command id, response state flags, response addressing, and
/// dataLength are self-consistent.
Uint8List _adsResponsePayload(Uint8List frame, int expectedCommandId) {
  final tcp = AmsTcpHeader.decode(ByteData.sublistView(frame));
  expect(tcp.length, equals(frame.length - AmsTcpHeader.byteLength),
      reason: 'AMS/TCP length must equal the trailing byte count');

  final ams =
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);
  expect(ams.commandId, equals(expectedCommandId));
  expect(ams.stateFlags, equals(AmsStateFlags.response));

  // A response INVERTS the request's addressing (WR-06): it travels to the
  // original source (the client, _source) from the original target (the
  // PLC, _target).
  expect(ams.targetNetId, equals(_source.netId),
      reason: 'response target must be the request source (the client)');
  expect(ams.targetPort, equals(_source.port));
  expect(ams.sourceNetId, equals(_target.netId),
      reason: 'response source must be the request target (the PLC)');
  expect(ams.sourcePort, equals(_target.port));

  const payloadStart = AmsTcpHeader.byteLength + AmsHeader.byteLength;
  expect(ams.dataLength, equals(frame.length - payloadStart),
      reason: 'AMS dataLength must equal the ADS payload length');
  return frame.sublist(payloadStart);
}

/// Strips the 6-byte AMS/TCP wrapper + 32-byte AMS header off a full golden
/// request [frame] and returns the trailing ADS payload, asserting the wrapper
/// length, command id, request state flags, request addressing (to the PLC
/// [_target] from the client [_source]), and dataLength are self-consistent.
///
/// The notification builders from 05-01 produce the ADS payload only (not the
/// full frame), so req goldens are compared payload-to-payload after this strip.
Uint8List _adsRequestPayload(Uint8List frame, int expectedCommandId) {
  final tcp = AmsTcpHeader.decode(ByteData.sublistView(frame));
  expect(tcp.length, equals(frame.length - AmsTcpHeader.byteLength),
      reason: 'AMS/TCP length must equal the trailing byte count');

  final ams =
      AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);
  expect(ams.commandId, equals(expectedCommandId));
  expect(ams.stateFlags, equals(AmsStateFlags.request));

  // A request travels TO the PLC (_target) FROM the client (_source).
  expect(ams.targetNetId, equals(_target.netId));
  expect(ams.targetPort, equals(_target.port));
  expect(ams.sourceNetId, equals(_source.netId));
  expect(ams.sourcePort, equals(_source.port));

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
        adsState: AdsState.run.code, // 5
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
      expect(res.adsState, equals(AdsState.run.code)); // 5
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

  group('device notification goldens', () {
    test('AddDeviceNotification request payload == committed golden', () {
      // The golden was emitted from the C++ struct layout; the pure Dart
      // builder must reproduce the same 40 bytes (field order + reserved zeros).
      final payload = _adsRequestPayload(
        readGolden('test/golden/add_notification_req.hex'),
        AdsCommandId.addDeviceNotification,
      );
      final built = buildAddNotificationPayload(
        indexGroup: 0x4020,
        indexOffset: 4,
        length: 1,
        transMode: AdsTransmissionMode.serverCycle.code, // 3
        maxDelay100ns: 0,
        cycleTime100ns: 1000000,
      );
      expect(built.length, equals(40),
          reason: 'the 24-field + 16-reserved layout must be exactly 40 bytes');
      expect(built, equals(payload));
    });

    test('DeleteDeviceNotification request payload == committed golden', () {
      final payload = _adsRequestPayload(
        readGolden('test/golden/del_notification_req.hex'),
        AdsCommandId.deleteDeviceNotification,
      );
      expect(
          buildDeleteNotificationPayload(handle: 0x0A0B0C0D), equals(payload));
    });

    test('AddDeviceNotification response decodes result + handle', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/add_notification_res.hex'),
        AdsCommandId.addDeviceNotification,
      );
      final res = decodeAddNotificationResponse(payload);
      expect(res.result, equals(0));
      expect(res.handle, equals(0x0A0B0C0D));
    });

    test('DeleteDeviceNotification response decodes result', () {
      final payload = _adsResponsePayload(
        readGolden('test/golden/del_notification_res.hex'),
        AdsCommandId.deleteDeviceNotification,
      );
      expect(decodeDeleteNotificationResponse(payload), equals(0));
    });

    test('notification stream parses 4 samples across 2 stamps (2x2 nesting)',
        () {
      // 0x08 is emitted response-direction, so it inverts addressing like any
      // response frame; strip it with the response helper.
      final payload = _adsResponsePayload(
        readGolden('test/golden/notification_stream.hex'),
        AdsCommandId.deviceNotification,
      );
      final notifications = parseNotificationStream(payload);
      expect(notifications, hasLength(4),
          reason: '2 stamps x 2 samples flattens to 4 notifications');

      // Per-stamp timestamps from the golden FILETIMEs (both whole-µs).
      final stamp0Ts = filetimeToDateTime(132000000000000000);
      final stamp1Ts = filetimeToDateTime(132000000010000000);
      expect(stamp0Ts, isNot(equals(stamp1Ts)),
          reason: 'distinct per-stamp timestamps prove per-stamp binding');

      // stamp0 / sample0: handle 1, 4 bytes 11 22 33 44
      expect(notifications[0].handle, equals(1));
      expect(notifications[0].timestamp, equals(stamp0Ts));
      expect(notifications[0].data,
          equals(Uint8List.fromList([0x11, 0x22, 0x33, 0x44])));
      // stamp0 / sample1: handle 2, 2 bytes aa bb
      expect(notifications[1].handle, equals(2));
      expect(notifications[1].timestamp, equals(stamp0Ts));
      expect(notifications[1].data, equals(Uint8List.fromList([0xaa, 0xbb])));
      // stamp1 / sample0: handle 1, 1 byte 55
      expect(notifications[2].handle, equals(1));
      expect(notifications[2].timestamp, equals(stamp1Ts));
      expect(notifications[2].data, equals(Uint8List.fromList([0x55])));
      // stamp1 / sample1: handle 3, 0 bytes (empty data)
      expect(notifications[3].handle, equals(3));
      expect(notifications[3].timestamp, equals(stamp1Ts));
      expect(notifications[3].data, isEmpty);
    });
  });
}
