@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

/// Verifies the curated public barrel (`package:dart_ads/dart_ads.dart`)
/// exposes the codec surface a consumer needs — referencing the types purely
/// through the public import, with no `src/` reach-in. If any of these symbols
/// were dropped from the barrel this file would fail to analyze/compile, which
/// is the behavioural assertion the acceptance criteria call for.
void main() {
  group('public barrel surface', () {
    test('address + header types are reachable and encode', () {
      final target = AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3);
      final source = AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001);

      final header = AmsHeader(
        targetNetId: target.netId,
        targetPort: target.port,
        sourceNetId: source.netId,
        sourcePort: source.port,
        commandId: AdsCommandId.readDeviceInfo,
        stateFlags: AmsStateFlags.request,
        dataLength: 0,
        errorCode: 0,
        invokeId: 1,
      );
      expect(header.encode().length, equals(AmsHeader.byteLength));

      final wrapper = AmsTcpHeader(length: AmsHeader.byteLength);
      expect(wrapper.encode().length, equals(AmsTcpHeader.byteLength));
    });

    test('encoders + FrameAssembler + decoder round-trip through the barrel',
        () {
      final target = AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3);
      final source = AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001);

      final frame = encodeReadDeviceInfoRequest(
        target: target,
        source: source,
        invokeId: 1,
      );

      final assembler = FrameAssembler();
      final frames = assembler.add(frame);
      expect(frames, hasLength(1));
      expect(frames.single, equals(frame));
      expect(assembler.hasBufferedBytes, isFalse);
    });

    test('MalformedFrameException is catchable through the barrel', () {
      expect(
        () => AmsNetId(Uint8List(3)),
        throwsA(isA<MalformedFrameException>()),
      );
    });

    test('AdsResponse hierarchy + decoders are exported', () {
      final payload = Uint8List(8);
      final AdsResponse res = decodeReadStateResponse(payload);
      expect(res, isA<ReadStateResponse>());
      expect(res.result, equals(0));
    });

    test('notification value types are reachable through the barrel', () {
      // AdsTransmissionMode: the enum consumers pass to subscribe(); its wire
      // code is the public contract.
      expect(AdsTransmissionMode.serverOnChange.code, equals(4));

      // AdsNotification: the delivered sample value type, constructible and
      // readable purely through the public import.
      final sample = AdsNotification(
        handle: 0x2A,
        timestamp: DateTime.utc(2026),
        data: Uint8List.fromList([1, 2, 3]),
      );
      expect(sample.handle, equals(0x2A));
      expect(sample.data, hasLength(3));
    });
  });
}
