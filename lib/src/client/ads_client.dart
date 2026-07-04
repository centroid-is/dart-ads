/// The [AdsClient] (L6-lite): the idiomatic async Dart API over the six core ADS
/// commands.
///
/// Each method obtains the raw ADS payload (the bytes AFTER the 38-byte AMS/TCP
/// + AMS header prefix — the header is stamped by [AmsConnection.request]) from
/// the shared `build*Payload` builders in `protocol/commands.dart` — the single
/// source of truth for the wire layouts, also consumed by the full-frame
/// encoders — sends it through the connection, and maps the reply. Error mapping happens at BOTH
/// levels via [AdsException.fromCode] (ERR-01):
///
///   1. the AMS-header `errorCode` is checked BEFORE the payload is decoded, so
///      an empty / short error payload can never masquerade as success and can
///      never trip the decoders' length guards (threat T-3-02); then
///   2. the decoded ADS `result` word is checked AFTER decode.
///
/// A [MalformedFrameException] from a decoder (a well-formed AMS response whose
/// ADS payload is internally inconsistent) propagates unchanged — framing
/// failures stay a distinct family from [AdsException] (threat T-3-06).
///
/// This file lives OUTSIDE `protocol/` because it is async (it imports the
/// connection layer). The `protocol/` subtree stays pure.
library;

import 'dart:async';
import 'dart:typed_data';

import '../connection/ams_connection.dart';
import '../protocol/ads_error.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/commands.dart';
import '../protocol/constants.dart';
import 'ads_types.dart';

/// An idiomatic async client for the six core ADS commands over a single
/// [AmsConnection].
///
/// Construct with a connected [AmsConnection] plus the [target] and [source]
/// AMS addresses (D-01: explicit addressing). In Phase 3 the connection itself
/// stamps addressing onto every outbound frame, so [target] / [source] are held
/// as the Phase-4 router seam — the router will own source stamping without any
/// change to the command-method bodies. They are intentionally NOT used to
/// re-address here, and [AmsConnection] addressing is deliberately not
/// refactored this phase.
class AdsClient {
  /// Creates a client over [connection], addressed [source] → [target].
  ///
  /// [target] / [source] are stored for the Phase-4 router seam only; the
  /// connection stamps the actual on-wire addressing in Phase 3.
  AdsClient(
    this.connection, {
    required this.target,
    required this.source,
  });

  /// The underlying multiplexed AMS/TCP connection this client issues commands
  /// over.
  final AmsConnection connection;

  /// The target AMS address (Phase-4 router seam; not used for addressing here).
  final AmsAddr target;

  /// The source AMS address (Phase-4 router seam; not used for addressing here).
  final AmsAddr source;

  /// Reads [length] bytes at ([indexGroup], [indexOffset]).
  ///
  /// Returns the raw bytes the device returned (a defensive copy).
  Future<Uint8List> read({
    required int indexGroup,
    required int indexOffset,
    required int length,
    Duration? timeout,
  }) async {
    final payload = buildReadPayload(
      indexGroup: indexGroup,
      indexOffset: indexOffset,
      length: length,
    );

    final response = await _command(AdsCommandId.read, payload, timeout);
    final decoded = decodeReadResponse(response);
    _throwOnResult(decoded.result);
    return decoded.data;
  }

  /// Writes [data] at ([indexGroup], [indexOffset]).
  Future<void> write({
    required int indexGroup,
    required int indexOffset,
    required Uint8List data,
    Duration? timeout,
  }) async {
    final payload = buildWritePayload(
      indexGroup: indexGroup,
      indexOffset: indexOffset,
      data: data,
    );

    final response = await _command(AdsCommandId.write, payload, timeout);
    _throwOnResult(decodeWriteResponse(response).result);
  }

  /// Writes [writeData] and reads back [readLength] bytes at
  /// ([indexGroup], [indexOffset]) in a single round-trip.
  ///
  /// Returns the read bytes directly (D-ReadWrite-convenience: yes).
  Future<Uint8List> readWrite({
    required int indexGroup,
    required int indexOffset,
    required int readLength,
    required Uint8List writeData,
    Duration? timeout,
  }) async {
    final payload = buildReadWritePayload(
      indexGroup: indexGroup,
      indexOffset: indexOffset,
      readLength: readLength,
      writeData: writeData,
    );

    final response = await _command(AdsCommandId.readWrite, payload, timeout);
    final decoded = decodeReadWriteResponse(response);
    _throwOnResult(decoded.result);
    return decoded.data;
  }

  /// Reads the device's ADS/device run state.
  ///
  /// Maps the raw ADS state through [AdsState.fromCode] while keeping the raw
  /// u16 [AdsStateInfo.rawAdsState] and [AdsStateInfo.deviceState].
  Future<AdsStateInfo> readState({Duration? timeout}) async {
    final response =
        await _command(AdsCommandId.readState, Uint8List(0), timeout);
    final decoded = decodeReadStateResponse(response);
    _throwOnResult(decoded.result);
    return AdsStateInfo(
      adsState: AdsState.fromCode(decoded.adsState),
      rawAdsState: decoded.adsState,
      deviceState: decoded.deviceState,
    );
  }

  /// Sets the device's ADS run state to [adsState] (and [deviceState]), with an
  /// optional trailing [data] blob (empty by default — D-WriteControl-data).
  Future<void> writeControl({
    required AdsState adsState,
    int deviceState = 0,
    Uint8List? data,
    Duration? timeout,
  }) async {
    final payload = buildWriteControlPayload(
      adsState: adsState.code,
      deviceState: deviceState,
      data: data,
    );

    final response =
        await _command(AdsCommandId.writeControl, payload, timeout);
    _throwOnResult(decodeWriteControlResponse(response).result);
  }

  /// Reads the device name and version triple.
  Future<DeviceInfo> readDeviceInfo({Duration? timeout}) async {
    final response =
        await _command(AdsCommandId.readDeviceInfo, Uint8List(0), timeout);
    final decoded = decodeReadDeviceInfoResponse(response);
    _throwOnResult(decoded.result);
    return DeviceInfo(
      name: decoded.name,
      version: decoded.version,
      revision: decoded.revision,
      build: decoded.build,
    );
  }

  /// The single AMS-level throw site: sends [adsPayload] under [commandId],
  /// then throws [AdsException] for a non-zero AMS-header `errorCode` BEFORE any
  /// payload decode (threat T-3-02), otherwise returns the raw ADS payload.
  Future<Uint8List> _command(
    int commandId,
    Uint8List adsPayload,
    Duration? timeout,
  ) async {
    final response =
        await connection.request(commandId, adsPayload, timeout: timeout);
    if (response.errorCode != 0) {
      throw AdsException.fromCode(response.errorCode);
    }
    return response.payload;
  }

  /// The single payload-level throw site: throws [AdsException] for a non-zero
  /// decoded ADS `result` word (checked AFTER decode).
  void _throwOnResult(int result) {
    if (result != 0) {
      throw AdsException.fromCode(result);
    }
  }
}
