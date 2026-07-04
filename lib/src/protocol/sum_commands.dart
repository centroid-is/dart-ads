/// Pure builders, decoders, and value types for the three ADS SUMUP batched
/// commands: SUMUP_READ (0xF080), SUMUP_WRITE (0xF081), SUMUP_READWRITE
/// (0xF082).
///
/// Each of the three sum commands is transported as a single ADS ReadWrite
/// (0x09) call to its SUMUP index group with `indexOffset == N` (the item
/// count). The builders here produce ONLY the *inner* write-buffer plus the
/// outer `readLength` — they do NOT wrap the buffer in the ReadWrite envelope.
/// That wrapping stays in [buildReadWritePayload] (`commands.dart`), its single
/// source of truth; the client passes these outputs to it. Each builder returns
/// a `(Uint8List writeBuffer, int readLength)` record so the `readLength`
/// FORMULA lives in exactly this one pure place and cannot silently diverge.
///
/// The decoders take the *inner* read-buffer ([ReadWriteResponse.data] after the
/// outer decode) and reconstruct per-item results as `List<SumResult<T>>`.
///
/// ## Frozen convention: a failed item contributes ZERO data bytes
///
/// For SUMUP_READ and SUMUP_READWRITE, a per-item error (non-zero result word)
/// means that item emits **0 data bytes** — the data cursor advances by `0` for
/// a failed item, not by its requested length. Every *other* item's data
/// therefore still lands at the correct offset (the SUM-04 alignment rule). This
/// 0-byte-on-failure convention is OUR contract: it is frozen by the mock server
/// and the golden fixtures, not observed from a real PLC. No C++ AdsLibTest sum
/// scenario exists to cross-validate it — FLAGGED for the Phase 9 parity audit.
///
/// Pure: imports only `dart:typed_data` plus the local, pure protocol types
/// ([checkUint], [MalformedFrameException], [AdsException]). No `dart:async` /
/// `dart:io`. Intentionally NOT re-exported by the package barrel.
library;

import 'dart:typed_data';

import 'ads_error.dart';
import 'exceptions.dart';
import 'range_check.dart';

// ---------------------------------------------------------------------------
// Request value types
// ---------------------------------------------------------------------------

/// One item of a SUMUP_READ (0xF080) batch: read [length] bytes at
/// [indexGroup]/[indexOffset].
final class SumReadRequest {
  /// Creates a read item targeting [indexGroup]/[indexOffset] for [length]
  /// bytes.
  const SumReadRequest({
    required this.indexGroup,
    required this.indexOffset,
    required this.length,
  });

  /// The item's ADS index group (u32).
  final int indexGroup;

  /// The item's ADS index offset (u32).
  final int indexOffset;

  /// The number of bytes to read for this item (u32). The READ response carries
  /// no per-item length, so the decoder slices the data region using this
  /// requested length.
  final int length;
}

/// One item of a SUMUP_WRITE (0xF081) batch: write [data] at
/// [indexGroup]/[indexOffset].
final class SumWriteRequest {
  /// Creates a write item targeting [indexGroup]/[indexOffset] with [data].
  const SumWriteRequest({
    required this.indexGroup,
    required this.indexOffset,
    required this.data,
  });

  /// The item's ADS index group (u32).
  final int indexGroup;

  /// The item's ADS index offset (u32).
  final int indexOffset;

  /// The bytes to write for this item (its wire length is `data.length`).
  final Uint8List data;
}

/// One item of a SUMUP_READWRITE (0xF082) batch: write [writeData] then read
/// back up to [readLength] bytes at [indexGroup]/[indexOffset].
final class SumReadWriteRequest {
  /// Creates a read-write item targeting [indexGroup]/[indexOffset], writing
  /// [writeData] and requesting up to [readLength] bytes back.
  const SumReadWriteRequest({
    required this.indexGroup,
    required this.indexOffset,
    required this.readLength,
    required this.writeData,
  });

  /// The item's ADS index group (u32).
  final int indexGroup;

  /// The item's ADS index offset (u32).
  final int indexOffset;

  /// The maximum number of bytes requested back for this item (u32). The
  /// RESPONSE carries a per-item *returned* length that may be `<= readLength`;
  /// the decoder slices by the returned length, never this requested value.
  final int readLength;

  /// The bytes to write for this item (its wire length is `writeData.length`).
  final Uint8List writeData;
}

// ---------------------------------------------------------------------------
// Per-item result value type
// ---------------------------------------------------------------------------

/// One item's outcome within a sum batch.
///
/// [errorCode] is the per-item ADS status word (`0` == success). A non-zero
/// [errorCode] does NOT throw at decode time — the whole point of a sum batch is
/// that partial failure surfaces per item (SUM-04). Only the *outer* AMS /
/// ReadWrite result throws (the client's job). Call [valueOrThrow] to convert a
/// failed item into an [AdsException] at the point of use.
///
/// [value] is the returned bytes ([Uint8List]) for READ/READWRITE items, or
/// `null` for WRITE items (`T == void`, value unused).
final class SumResult<T> {
  /// Creates a per-item result carrying [errorCode] and an optional [value].
  const SumResult({required this.errorCode, this.value});

  /// The per-item ADS status word (`0` == success).
  final int errorCode;

  /// The per-item value: returned bytes for READ/READWRITE, `null` for WRITE.
  final T? value;

  /// Whether this item succeeded (`errorCode == 0`).
  bool get isSuccess => errorCode == 0;

  /// The [value] if this item succeeded, otherwise throws an [AdsException]
  /// built from [errorCode].
  T get valueOrThrow =>
      isSuccess ? value as T : throw AdsException.fromCode(errorCode);

  @override
  String toString() =>
      'SumResult(errorCode: $errorCode, isSuccess: $isSuccess)';
}

// ---------------------------------------------------------------------------
// Builders — inner write-buffer + outer readLength (single source of truth)
// ---------------------------------------------------------------------------

/// Builds the SUMUP_READ (0xF080) inner write-buffer and its outer `readLength`.
///
/// Write-buffer = `N × 12` bytes, one item as `indexGroup u32, indexOffset u32,
/// length u32`. `readLength = N*4 + Σ length_i` (N result words + the sum of the
/// requested data lengths). The client wraps this via
/// `buildReadWritePayload(indexGroup: 0xF080, indexOffset: N, readLength: …,
/// writeData: writeBuffer)`.
(Uint8List writeBuffer, int readLength) buildSumReadPayload(
  List<SumReadRequest> items,
) {
  final out = Uint8List(items.length * 12);
  final bd = ByteData.sublistView(out);
  var o = 0;
  var sumLen = 0;
  for (final it in items) {
    bd.setUint32(o, checkUint(it.indexGroup, 32, 'indexGroup'), Endian.little);
    bd.setUint32(
        o + 4, checkUint(it.indexOffset, 32, 'indexOffset'), Endian.little);
    bd.setUint32(o + 8, checkUint(it.length, 32, 'length'), Endian.little);
    sumLen += it.length;
    o += 12;
  }
  return (out, items.length * 4 + sumLen);
}

/// Builds the SUMUP_WRITE (0xF081) inner write-buffer and its outer `readLength`.
///
/// Write-buffer = `N × 12` byte headers (`indexGroup u32, indexOffset u32,
/// data.length u32`) THEN the concatenated write payloads (`Σ data.length_i`
/// bytes, item order). `readLength = N*4` — one result word per item comes back,
/// nothing else.
(Uint8List writeBuffer, int readLength) buildSumWritePayload(
  List<SumWriteRequest> items,
) {
  final n = items.length;
  var dataTotal = 0;
  for (final it in items) {
    dataTotal += it.data.length;
  }
  final out = Uint8List(n * 12 + dataTotal);
  final bd = ByteData.sublistView(out);
  var dataCursor = n * 12;
  var o = 0;
  for (final it in items) {
    bd.setUint32(o, checkUint(it.indexGroup, 32, 'indexGroup'), Endian.little);
    bd.setUint32(
        o + 4, checkUint(it.indexOffset, 32, 'indexOffset'), Endian.little);
    bd.setUint32(
        o + 8, checkUint(it.data.length, 32, 'data.length'), Endian.little);
    out.setRange(dataCursor, dataCursor + it.data.length, it.data);
    dataCursor += it.data.length;
    o += 12;
  }
  return (out, n * 4);
}

/// Builds the SUMUP_READWRITE (0xF082) inner write-buffer and its outer
/// `readLength`.
///
/// Write-buffer = `N × 16` byte headers (`indexGroup u32, indexOffset u32,
/// readLength u32, writeData.length u32`) THEN the concatenated write payloads
/// (`Σ writeData.length_i` bytes, item order). `readLength = N*8 + Σ
/// readLength_i` (per item: a 4-byte result + a 4-byte returned-length header,
/// plus the requested read data).
(Uint8List writeBuffer, int readLength) buildSumReadWritePayload(
  List<SumReadWriteRequest> items,
) {
  final n = items.length;
  var writeTotal = 0;
  var readTotal = 0;
  for (final it in items) {
    writeTotal += it.writeData.length;
    readTotal += it.readLength;
  }
  final out = Uint8List(n * 16 + writeTotal);
  final bd = ByteData.sublistView(out);
  var dataCursor = n * 16;
  var o = 0;
  for (final it in items) {
    bd.setUint32(o, checkUint(it.indexGroup, 32, 'indexGroup'), Endian.little);
    bd.setUint32(
        o + 4, checkUint(it.indexOffset, 32, 'indexOffset'), Endian.little);
    bd.setUint32(
        o + 8, checkUint(it.readLength, 32, 'readLength'), Endian.little);
    bd.setUint32(o + 12, checkUint(it.writeData.length, 32, 'writeData.length'),
        Endian.little);
    out.setRange(dataCursor, dataCursor + it.writeData.length, it.writeData);
    dataCursor += it.writeData.length;
    o += 16;
  }
  return (out, n * 8 + readTotal);
}

// ---------------------------------------------------------------------------
// Decoders — inner read-buffer -> per-item results
// ---------------------------------------------------------------------------
//
// All three take the INNER read-buffer (ReadWriteResponse.data after the outer
// decode). None throws on a per-item error word — partial failure is a value,
// not an exception (SUM-04). Only an over-run of the buffer throws
// MalformedFrameException, mirroring `_decodeResultAndData` (threat T-6-01).

/// Decodes a SUMUP_READ (0xF080) inner read-buffer into per-item results.
///
/// Layout: `N × u32` error words (item order) THEN concatenated data blocks.
/// The READ response carries NO per-item length, so [items] supplies the
/// requested `length_i` used to slice each block.
///
/// Frozen 0-byte-on-failure convention (see the library doc-comment): a failed
/// item (`err != 0`) yields an EMPTY value and advances the data cursor by `0`;
/// a successful item advances the cursor by its requested `length_i`. This keeps
/// every other item's data at the correct offset (the SUM-04 alignment rule).
/// This convention is frozen by the golden fixtures — FLAGGED for the Phase 9
/// parity audit (no C++ AdsLibTest sum scenario cross-validates it).
///
/// Bounds-checks `cursor + length_i <= data.length` before every slice, throwing
/// [MalformedFrameException] on an over-run before reading (T-6-01).
List<SumResult<Uint8List>> decodeSumReadResponse(
  Uint8List data,
  List<SumReadRequest> items,
) {
  final n = items.length;
  _requireHeader(data, n * 4, 'SUMUP_READ response');
  final bd = ByteData.sublistView(data);
  final results = <SumResult<Uint8List>>[];
  var cursor = n * 4;
  for (var i = 0; i < n; i++) {
    final err = bd.getUint32(i * 4, Endian.little);
    if (err != 0) {
      results.add(SumResult<Uint8List>(errorCode: err, value: _emptyBytes));
      continue; // failed item: 0 data bytes, cursor unchanged.
    }
    final len = items[i].length;
    _requireBlock(data, cursor, len, 'SUMUP_READ response', i);
    results.add(SumResult<Uint8List>(
      errorCode: 0,
      value: Uint8List.fromList(data.sublist(cursor, cursor + len)),
    ));
    cursor += len;
  }
  return results;
}

/// Decodes a SUMUP_WRITE (0xF081) inner read-buffer into per-item results.
///
/// Layout: `N × u32` error words only. Successful items carry no data, so every
/// result's value is `null` (`T == void`).
List<SumResult<void>> decodeSumWriteResponse(Uint8List data, int n) {
  _requireHeader(data, n * 4, 'SUMUP_WRITE response');
  final bd = ByteData.sublistView(data);
  return <SumResult<void>>[
    for (var i = 0; i < n; i++)
      SumResult<void>(errorCode: bd.getUint32(i * 4, Endian.little)),
  ];
}

/// Decodes a SUMUP_READWRITE (0xF082) inner read-buffer into per-item results.
///
/// Layout: `N × (result u32, returnedLength u32)` headers (item order) THEN
/// concatenated data blocks. Each block *i* is sliced by the RETURNED length
/// from the response header — NEVER the requested `readLength` (a failed item's
/// returned length is `0`). The requested length is only an upper bound.
///
/// Bounds-checks `cursor + returnedLength_i <= data.length` before every slice,
/// throwing [MalformedFrameException] on an over-run (T-6-01).
List<SumResult<Uint8List>> decodeSumReadWriteResponse(Uint8List data, int n) {
  _requireHeader(data, n * 8, 'SUMUP_READWRITE response');
  final bd = ByteData.sublistView(data);
  final errs = List<int>.filled(n, 0);
  final lens = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    errs[i] = bd.getUint32(i * 8, Endian.little);
    lens[i] = bd.getUint32(i * 8 + 4, Endian.little);
  }
  final results = <SumResult<Uint8List>>[];
  var cursor = n * 8;
  for (var i = 0; i < n; i++) {
    final len = lens[i];
    _requireBlock(data, cursor, len, 'SUMUP_READWRITE response', i);
    results.add(SumResult<Uint8List>(
      errorCode: errs[i],
      value: Uint8List.fromList(data.sublist(cursor, cursor + len)),
    ));
    cursor += len;
  }
  return results;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// A shared empty value for failed READ items.
final Uint8List _emptyBytes = Uint8List(0);

/// Throws [MalformedFrameException] if [data] cannot hold the fixed [headerLen]
/// result/length header region.
void _requireHeader(Uint8List data, int headerLen, String what) {
  if (data.length < headerLen) {
    throw MalformedFrameException(
      '$what requires a $headerLen-byte header region, got ${data.length}',
      length: headerLen,
    );
  }
}

/// Throws [MalformedFrameException] if the block `[cursor, cursor + len)` would
/// over-run [data] — checked (subtraction-safe) BEFORE any slice (T-6-01).
void _requireBlock(
  Uint8List data,
  int cursor,
  int len,
  String what,
  int item,
) {
  if (len < 0 || len > data.length - cursor) {
    throw MalformedFrameException(
      '$what item $item declares $len data bytes but only '
      '${data.length - cursor} remain',
      length: len,
      offset: cursor,
    );
  }
}
