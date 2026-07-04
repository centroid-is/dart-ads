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
import 'dart:convert';
import 'dart:typed_data';

import '../connection/ams_connection.dart';
import '../protocol/ads_error.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/commands.dart';
import '../protocol/constants.dart';
import '../protocol/exceptions.dart';
import '../protocol/notifications.dart';
import '../protocol/sum_commands.dart';
import '../protocol/symbols.dart';
import '../protocol/value_codec.dart' as codec;
import 'ads_types.dart';

/// The `{nSymbols, nSymSize}` header a SYM_UPLOADINFO (0xF00C) read returns —
/// the symbol count and the total byte size of the SYM_UPLOAD (0xF00B) blob.
typedef SymbolUploadInfo = ({int symbolCount, int symbolSize});

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

  // -------------------------------------------------------------------------
  // Symbol access — handle lifecycle (SYM-01)
  // -------------------------------------------------------------------------

  /// Resolves the symbol [name] to a device handle via SYM_HNDBYNAME
  /// (ReadWrite 0xF003).
  ///
  /// The name is encoded Latin-1 with a trailing NUL (locked decision A1:
  /// real-PLC-safe, matches pyads; the mock strips the NUL before lookup). The
  /// device returns exactly 4 bytes — the u32 handle, little-endian. Reuses the
  /// existing [readWrite] path, so no new [AdsException] throw site is added.
  Future<int> getHandleByName(String name, {Duration? timeout}) async {
    final nameBytes = latin1.encode(name);
    final writeData = Uint8List(nameBytes.length + 1)
      ..setRange(0, nameBytes.length, nameBytes); // trailing NUL (zero-filled)
    final data = await readWrite(
      indexGroup: AdsIndexGroup.symbolHandleByName,
      indexOffset: 0,
      readLength: 4,
      writeData: writeData,
      timeout: timeout,
    );
    if (data.length < 4) {
      throw MalformedFrameException(
        'SYM_HNDBYNAME returned ${data.length} bytes, expected a 4-byte handle',
        length: 4,
        offset: 0,
      );
    }
    return ByteData.sublistView(data).getUint32(0, Endian.little);
  }

  /// Reads [size] bytes of the symbol identified by [handle] via SYM_VALBYHND
  /// (Read 0xF005, indexOffset == handle). Returns raw bytes (SYM-04).
  Future<Uint8List> readByHandle(int handle, int size, {Duration? timeout}) =>
      read(
        indexGroup: AdsIndexGroup.symbolValueByHandle,
        indexOffset: handle,
        length: size,
        timeout: timeout,
      );

  /// Writes [data] to the symbol identified by [handle] via SYM_VALBYHND
  /// (Write 0xF005, indexOffset == handle).
  Future<void> writeByHandle(int handle, Uint8List data, {Duration? timeout}) =>
      write(
        indexGroup: AdsIndexGroup.symbolValueByHandle,
        indexOffset: handle,
        data: data,
        timeout: timeout,
      );

  /// Releases [handle] via SYM_RELEASEHND (Write 0xF006).
  ///
  /// Per the vendored AdsLib the handle is the 4-byte little-endian DATA payload
  /// and indexOffset is 0 — NOT the other way around.
  Future<void> releaseHandle(int handle, {Duration? timeout}) {
    final data = Uint8List(4);
    ByteData.sublistView(data).setUint32(0, handle, Endian.little);
    return write(
      indexGroup: AdsIndexGroup.symbolReleaseHandle,
      indexOffset: 0,
      data: data,
      timeout: timeout,
    );
  }

  /// Resolves [name], reads [size] bytes, then releases the handle — even if the
  /// read fails (T-7-01: no handle leak on op failure). Returns raw bytes.
  Future<Uint8List> readByName(String name, int size,
      {Duration? timeout}) async {
    final handle = await getHandleByName(name, timeout: timeout);
    try {
      return await readByHandle(handle, size, timeout: timeout);
    } finally {
      await _releaseQuietly(handle, timeout);
    }
  }

  /// Resolves [name], writes [data], then releases the handle — even if the
  /// write fails (T-7-01: no handle leak on op failure).
  Future<void> writeByName(String name, Uint8List data,
      {Duration? timeout}) async {
    final handle = await getHandleByName(name, timeout: timeout);
    try {
      await writeByHandle(handle, data, timeout: timeout);
    } finally {
      await _releaseQuietly(handle, timeout);
    }
  }

  /// Releases [handle], swallowing any error so a failing release in a `finally`
  /// never masks the real operation result (mirrors [_deleteQuietly]).
  Future<void> _releaseQuietly(int handle, Duration? timeout) async {
    try {
      await releaseHandle(handle, timeout: timeout);
    } catch (_) {
      // Intentionally swallowed — a best-effort release must never throw over
      // the operation's own outcome.
    }
  }

  // -------------------------------------------------------------------------
  // Symbol browse (SYM-02)
  // -------------------------------------------------------------------------

  /// A defensive ceiling on the SYM_UPLOAD blob size before allocating a read
  /// buffer for a device-controlled length (threat T-7-02b). 16 MiB dwarfs any
  /// realistic symbol table yet caps a hostile/garbage `nSymSize`.
  static const int _maxSymbolBlobBytes = 16 * 1024 * 1024;

  /// Reads the SYM_UPLOADINFO (0xF00C) header: the symbol count and the total
  /// byte size of the upload blob.
  Future<SymbolUploadInfo> uploadSymbolInfo({Duration? timeout}) async {
    final raw = await read(
      indexGroup: AdsIndexGroup.symbolUploadInfo,
      indexOffset: 0,
      length: 8,
      timeout: timeout,
    );
    if (raw.length < 8) {
      throw MalformedFrameException(
        'SYM_UPLOADINFO returned ${raw.length} bytes, expected 8',
        length: 8,
        offset: 0,
      );
    }
    final bd = ByteData.sublistView(raw);
    return (
      symbolCount: bd.getUint32(0, Endian.little),
      symbolSize: bd.getUint32(4, Endian.little),
    );
  }

  /// Browses the device's symbol table: SYM_UPLOADINFO (0xF00C) then a
  /// SYM_UPLOAD (0xF00B) read of `nSymSize` bytes, parsed into an ordered
  /// `List<AdsSymbolInfo>` by the pure [parseSymbolBlob] (order preserved).
  ///
  /// `nSymSize` is sanity-capped against [_maxSymbolBlobBytes] BEFORE allocating
  /// the read buffer (threat T-7-02b); an out-of-range value throws
  /// [MalformedFrameException] instead of attempting a huge allocation. An empty
  /// table returns `const []` with no second read.
  Future<List<AdsSymbolInfo>> browseSymbols({Duration? timeout}) async {
    final info = await uploadSymbolInfo(timeout: timeout);
    final size = info.symbolSize;
    if (size < 0 || size > _maxSymbolBlobBytes) {
      throw MalformedFrameException(
        'SYM_UPLOADINFO declares nSymSize $size, outside the sane range '
        '[0, $_maxSymbolBlobBytes]',
        length: size,
        offset: 0,
      );
    }
    if (size == 0) return const <AdsSymbolInfo>[];
    final blob = await read(
      indexGroup: AdsIndexGroup.symbolUpload,
      indexOffset: 0,
      length: size,
      timeout: timeout,
    );
    return parseSymbolBlob(blob, info.symbolCount);
  }

  // -------------------------------------------------------------------------
  // Typed convenience over value_codec (SYM-03)
  // -------------------------------------------------------------------------
  //
  // Each typed read is a `readByName` + a codec decode; each typed write is a
  // codec encode + a `writeByName`. The raw `Uint8List` path stays available
  // unchanged (SYM-04) — these are additive conveniences, not a replacement.
  // STRING/WSTRING take the symbol's declared buffer `size` (STRING(80) == 81).

  /// Reads a BOOL by [name].
  Future<bool> readBoolByName(String name, {Duration? timeout}) async =>
      codec.decodeBool(await readByName(name, 1, timeout: timeout));

  /// Writes a BOOL by [name].
  Future<void> writeBoolByName(String name, bool value, {Duration? timeout}) =>
      writeByName(name, codec.encodeBool(value), timeout: timeout);

  /// Reads a BYTE/USINT (u8) by [name].
  Future<int> readByteByName(String name, {Duration? timeout}) async =>
      codec.decodeByte(await readByName(name, 1, timeout: timeout));

  /// Writes a BYTE/USINT (u8) by [name].
  Future<void> writeByteByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeByte(value), timeout: timeout);

  /// Reads a SINT (i8) by [name].
  Future<int> readSintByName(String name, {Duration? timeout}) async =>
      codec.decodeSint(await readByName(name, 1, timeout: timeout));

  /// Writes a SINT (i8) by [name].
  Future<void> writeSintByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeSint(value), timeout: timeout);

  /// Reads a WORD/UINT (u16) by [name].
  Future<int> readWordByName(String name, {Duration? timeout}) async =>
      codec.decodeWord(await readByName(name, 2, timeout: timeout));

  /// Writes a WORD/UINT (u16) by [name].
  Future<void> writeWordByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeWord(value), timeout: timeout);

  /// Reads an INT (i16) by [name].
  Future<int> readIntByName(String name, {Duration? timeout}) async =>
      codec.decodeInt(await readByName(name, 2, timeout: timeout));

  /// Writes an INT (i16) by [name].
  Future<void> writeIntByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeInt(value), timeout: timeout);

  /// Reads a DWORD/UDINT (u32) by [name].
  Future<int> readDwordByName(String name, {Duration? timeout}) async =>
      codec.decodeDword(await readByName(name, 4, timeout: timeout));

  /// Writes a DWORD/UDINT (u32) by [name].
  Future<void> writeDwordByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeDword(value), timeout: timeout);

  /// Reads a DINT (i32) by [name].
  Future<int> readDintByName(String name, {Duration? timeout}) async =>
      codec.decodeDint(await readByName(name, 4, timeout: timeout));

  /// Writes a DINT (i32) by [name].
  Future<void> writeDintByName(String name, int value, {Duration? timeout}) =>
      writeByName(name, codec.encodeDint(value), timeout: timeout);

  /// Reads a REAL (f32) by [name].
  Future<double> readRealByName(String name, {Duration? timeout}) async =>
      codec.decodeReal(await readByName(name, 4, timeout: timeout));

  /// Writes a REAL (f32) by [name].
  Future<void> writeRealByName(String name, double value,
          {Duration? timeout}) =>
      writeByName(name, codec.encodeReal(value), timeout: timeout);

  /// Reads an LREAL (f64) by [name].
  Future<double> readLrealByName(String name, {Duration? timeout}) async =>
      codec.decodeLreal(await readByName(name, 8, timeout: timeout));

  /// Writes an LREAL (f64) by [name].
  Future<void> writeLrealByName(String name, double value,
          {Duration? timeout}) =>
      writeByName(name, codec.encodeLreal(value), timeout: timeout);

  /// Reads a STRING by [name] from a [size]-byte buffer (use the symbol's
  /// declared `size`; STRING(80) reports 81).
  Future<String> readStringByName(String name, int size,
          {Duration? timeout}) async =>
      codec.decodeString(await readByName(name, size, timeout: timeout));

  /// Writes a STRING by [name] into a [size]-byte buffer (NUL-padded).
  Future<void> writeStringByName(String name, String value, int size,
          {Duration? timeout}) =>
      writeByName(name, codec.encodeString(value, size), timeout: timeout);

  /// Reads a WSTRING by [name] from a [size]-byte buffer.
  Future<String> readWStringByName(String name, int size,
          {Duration? timeout}) async =>
      codec.decodeWString(await readByName(name, size, timeout: timeout));

  /// Writes a WSTRING by [name] into a [size]-byte buffer.
  Future<void> writeWStringByName(String name, String value, int size,
          {Duration? timeout}) =>
      writeByName(name, codec.encodeWString(value, size), timeout: timeout);

  /// Issues a SUMUP_READ (0xF080) batch — reads every item in [items] in a
  /// SINGLE ReadWrite round-trip — returning one [SumResult] per item in request
  /// order (SUM-01).
  ///
  /// Two-layer error model (SUM-04): a non-zero AMS-header `errorCode` (via
  /// [_command]) or a non-zero outer ADS `result` word (via [_throwOnResult])
  /// throws [AdsException] BEFORE any list is returned. A per-item error word is
  /// NOT a throw — it surfaces as [SumResult.errorCode] with `isSuccess == false`
  /// so a single bad item never fails the whole batch.
  ///
  /// An empty [items] returns `[]` immediately with NO wire call (empty-batch
  /// guard) — there is nothing to read and a zero-item ReadWrite envelope is
  /// meaningless.
  Future<List<SumResult<Uint8List>>> sumRead(
    List<SumReadRequest> items, {
    Duration? timeout,
  }) async {
    if (items.isEmpty) return <SumResult<Uint8List>>[];
    // Snapshot: the caller's list must not be re-read after the await —
    // mid-flight mutation would silently mis-slice the response (WR-01).
    final snapshot = List<SumReadRequest>.unmodifiable(items);
    final (inner, readLength) = buildSumReadPayload(snapshot);
    final payload = buildReadWritePayload(
      indexGroup: AdsIndexGroup.sumUpRead,
      indexOffset: snapshot.length,
      readLength: readLength,
      writeData: inner,
    );
    final response = await _command(AdsCommandId.readWrite, payload, timeout);
    final decoded = decodeReadWriteResponse(response);
    _throwOnResult(decoded.result);
    return decodeSumReadResponse(decoded.data, snapshot);
  }

  /// Issues a SUMUP_WRITE (0xF081) batch — writes every item in [items] in a
  /// SINGLE ReadWrite round-trip — returning one `SumResult<void>` per item in
  /// request order (SUM-02).
  ///
  /// Same two-layer error model as [sumRead]: outer AMS / ADS-result errors
  /// throw; a per-item error word populates [SumResult.errorCode] and never
  /// throws (SUM-04). An empty [items] returns `[]` with NO wire call.
  Future<List<SumResult<void>>> sumWrite(
    List<SumWriteRequest> items, {
    Duration? timeout,
  }) async {
    if (items.isEmpty) return <SumResult<void>>[];
    final snapshot = List<SumWriteRequest>.unmodifiable(items);
    final (inner, readLength) = buildSumWritePayload(snapshot);
    final payload = buildReadWritePayload(
      indexGroup: AdsIndexGroup.sumUpWrite,
      indexOffset: snapshot.length,
      readLength: readLength,
      writeData: inner,
    );
    final response = await _command(AdsCommandId.readWrite, payload, timeout);
    final decoded = decodeReadWriteResponse(response);
    _throwOnResult(decoded.result);
    return decodeSumWriteResponse(decoded.data, snapshot.length);
  }

  /// Issues a SUMUP_READWRITE (0xF082) batch — writes-then-reads every item in
  /// [items] in a SINGLE ReadWrite round-trip — returning one [SumResult] per
  /// item in request order (SUM-03).
  ///
  /// Same two-layer error model as [sumRead]: outer AMS / ADS-result errors
  /// throw; a per-item error word populates [SumResult.errorCode] and never
  /// throws (SUM-04). An empty [items] returns `[]` with NO wire call.
  Future<List<SumResult<Uint8List>>> sumReadWrite(
    List<SumReadWriteRequest> items, {
    Duration? timeout,
  }) async {
    if (items.isEmpty) return <SumResult<Uint8List>>[];
    final snapshot = List<SumReadWriteRequest>.unmodifiable(items);
    final (inner, readLength) = buildSumReadWritePayload(snapshot);
    final payload = buildReadWritePayload(
      indexGroup: AdsIndexGroup.sumUpReadWrite,
      indexOffset: snapshot.length,
      readLength: readLength,
      writeData: inner,
    );
    final response = await _command(AdsCommandId.readWrite, payload, timeout);
    final decoded = decodeReadWriteResponse(response);
    _throwOnResult(decoded.result);
    return decodeSumReadWriteResponse(decoded.data, snapshot.length);
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

  /// Subscribes to device notifications for the variable at
  /// ([indexGroup], [indexOffset]), returning a lazy single-subscription
  /// `Stream<AdsNotification>` (NOTIF-01/02/04).
  ///
  /// Lifecycle state machine (RESEARCH Pattern 3):
  ///
  ///   * **Lazy Add.** NO AddDeviceNotification is sent until the stream is
  ///     first listened. On first listen [onListen] builds the 40-byte Add
  ///     payload — [mode].code at offset 12, [maxDelay]/[cycleTime] converted to
  ///     100ns units (`Duration.inMicroseconds * 10`) at 16/20 — and calls
  ///     [AmsConnection.addNotification], which registers this stream's
  ///     controller as the demux target ahead of the first sample.
  ///   * **Always-Delete cancel.** [onCancel] always attempts a
  ///     DeleteDeviceNotification for the acquired handle via [_deleteQuietly],
  ///     which NEVER throws — cancel must always complete (threat T-5-12).
  ///   * **Cancel-during-pending-add.** If [onCancel] fires before the Add
  ///     resolves, `handle` is still `null`, so the Delete is deferred: once the
  ///     Add finally returns its handle, [onListen] sees `cancelled` and
  ///     immediately releases it — no leak, no throw (threat T-5-01).
  ///   * **Add failure.** An Add error surfaces to the listener via `addError`
  ///     (not as a leaked handle); no Delete is issued because none was acquired.
  ///
  /// No auto-resubscribe (v2 RECON-01): a dead stream stays dead. On disconnect
  /// the connection's fan-out error-closes this controller and invalidates the
  /// handle locally, so a later stale-handle Delete against a reconnected session
  /// is impossible (threat T-5-10).
  Stream<AdsNotification> subscribe({
    required int indexGroup,
    required int indexOffset,
    required int length,
    AdsTransmissionMode mode = AdsTransmissionMode.serverOnChange,
    Duration cycleTime = Duration.zero,
    Duration maxDelay = Duration.zero,
    Duration? timeout,
  }) {
    // `handle` is null until the Add resolves; `cancelled` records an onCancel
    // that raced ahead of that resolution.
    int? handle;
    var cancelled = false;
    late final StreamController<AdsNotification> controller;
    controller = StreamController<AdsNotification>(
      onListen: () async {
        try {
          final payload = buildAddNotificationPayload(
            indexGroup: indexGroup,
            indexOffset: indexOffset,
            length: length,
            transMode: mode.code,
            maxDelay100ns: maxDelay.inMicroseconds * 10,
            cycleTime100ns: cycleTime.inMicroseconds * 10,
          );
          final acquired = await connection.addNotification(
            payload,
            controller,
            timeout: timeout,
          );
          if (cancelled) {
            // Cancelled while the Add was in flight: release the handle the
            // moment it arrives so it is never leaked.
            await _deleteQuietly(acquired);
            return;
          }
          handle = acquired;
        } catch (e, st) {
          // Surface the Add failure to the listener rather than leaking a handle.
          if (!controller.isClosed) {
            controller.addError(e, st);
          }
        }
      },
      onCancel: () async {
        cancelled = true;
        final acquired = handle;
        if (acquired != null) {
          await _deleteQuietly(acquired);
        }
        // If `acquired` is null the Add is still pending; the onListen path
        // performs the deferred Delete once the handle arrives.
      },
    );
    return controller.stream;
  }

  /// Sends a DeleteDeviceNotification for [handle], swallowing any error.
  ///
  /// Cancel must never throw (threat T-5-12): a dead connection surfaces
  /// [AdsConnectionException] and a stale/reconnected session surfaces a device
  /// error, but the handle is invalidated locally on disconnect regardless
  /// (stale-handle rule, threat T-5-10), so both are safe to discard here.
  Future<void> _deleteQuietly(int handle) async {
    try {
      await connection.deleteNotification(
        handle,
        buildDeleteNotificationPayload(handle: handle),
      );
    } catch (_) {
      // Intentionally swallowed — see doc comment.
    }
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
