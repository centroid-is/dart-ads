/// Pure notification protocol layer for the Beckhoff ADS device-notification
/// commands: the [AdsTransmissionMode] enum, the [AdsNotification] value type,
/// the FILETIME<->DateTime helpers, the AddDeviceNotification (0x06) /
/// DeleteDeviceNotification (0x07) payload builders and response decoders, and
/// the doubly-nested 0x08 [parseNotificationStream].
///
/// This file is the single source of truth for every notification wire layout.
/// Every layout is transcribed byte-for-byte from the vendored Beckhoff C++
/// (`third_party/ADS`): the 40-byte `AdsAddDeviceNotificationRequest`
/// (`AmsHeader.h:92`), the `result u32 + handle u32` Add response, the
/// `handle u32` / `result u32` Delete pair, and the stamp-nested 0x08 stream
/// from `NotificationDispatcher::Run` (`NotificationDispatcher.cpp:56`).
///
/// Pure: imports only `dart:typed_data` plus the local, pure protocol helpers.
/// No `dart:async` / `dart:io`, so the whole layer is unit- and golden-testable
/// with no socket.
library;

import 'dart:typed_data';

import 'exceptions.dart';
import 'range_check.dart';

// ---------------------------------------------------------------------------
// Transmission mode
// ---------------------------------------------------------------------------

/// ADS notification transmission modes (`ADSTRANSMODE` in `AdsDef.h:322`).
///
/// Each member carries its wire [code] — the `nTransMode` u32 of the
/// AddDeviceNotification request. The default for `subscribe()` is
/// [serverOnChange].
enum AdsTransmissionMode {
  /// `ADSTRANS_NOTRANS` — no transmission.
  noTrans(0),

  /// `ADSTRANS_CLIENTCYCLE` — cyclic, client-driven.
  clientCycle(1),

  /// `ADSTRANS_CLIENTONCHA` — on change, client-driven.
  clientOnChange(2),

  /// `ADSTRANS_SERVERCYCLE` — cyclic, server-driven.
  serverCycle(3),

  /// `ADSTRANS_SERVERONCHA` — on change, server-driven (the default).
  serverOnChange(4),

  /// `ADSTRANS_SERVERCYCLE2` — cyclic, server-driven (variant 2).
  serverCycle2(5),

  /// `ADSTRANS_SERVERONCHA2` — on change, server-driven (variant 2).
  serverOnChange2(6),

  /// `ADSTRANS_CLIENT1REQ` — single client request.
  client1Req(10);

  const AdsTransmissionMode(this.code);

  /// The `ADSTRANSMODE` u32 wire value for this mode.
  final int code;
}

// ---------------------------------------------------------------------------
// Notification value type
// ---------------------------------------------------------------------------

/// A single delivered device-notification sample.
///
/// One on-wire sample maps to one [AdsNotification] (`AdsNotification.h:31`):
/// the [timestamp] is taken from the enclosing stamp (shared across all samples
/// in that stamp), while [handle] and [data] are per sample. The [data] bytes
/// are a defensive copy that never aliases the source frame buffer.
class AdsNotification {
  /// Creates a notification sample from its demux [handle], stamp [timestamp],
  /// and payload [data].
  const AdsNotification({
    required this.handle,
    required this.timestamp,
    required this.data,
  });

  /// The PLC-assigned notification handle — the demux key.
  final int handle;

  /// The stamp timestamp (UTC), converted from the wire FILETIME.
  final DateTime timestamp;

  /// The sample payload bytes.
  final Uint8List data;

  @override
  String toString() =>
      'AdsNotification(handle: $handle, timestamp: $timestamp, '
      'data: ${data.length} bytes)';
}

// ---------------------------------------------------------------------------
// FILETIME <-> DateTime
// ---------------------------------------------------------------------------

/// The number of 100-nanosecond ticks between 1601-01-01 00:00:00 UTC (the
/// FILETIME epoch) and 1970-01-01 00:00:00 UTC (the Unix epoch).
///
/// Verified by computation: `11644473600 s * 10^7 = 116444736000000000`.
const int _filetimeEpochOffset = 116444736000000000;

/// Converts a FILETIME (unsigned 100ns ticks since 1601-01-01 UTC) to a UTC
/// [DateTime].
///
/// FILETIME resolution is 100ns (0.1 µs) but `DateTime` on the native VM is
/// microsecond-precision, so the sub-microsecond 100ns digit is **truncated**
/// (`~/ 10`). Round-tripping is lossless only when the FILETIME is a whole
/// number of microseconds (a multiple of 10).
DateTime filetimeToDateTime(int filetime) {
  final micros = (filetime - _filetimeEpochOffset) ~/ 10;
  return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
}

/// Converts a [DateTime] to a FILETIME (100ns ticks since 1601-01-01 UTC).
///
/// The result is always a multiple of 10 (microsecond granularity × 10).
int dateTimeToFiletime(DateTime dt) =>
    dt.toUtc().microsecondsSinceEpoch * 10 + _filetimeEpochOffset;

// ---------------------------------------------------------------------------
// Payload builders
// ---------------------------------------------------------------------------

/// Builds the AddDeviceNotification (0x06) request payload — exactly 40 bytes.
///
/// Field order is transcribed from `struct AdsAddDeviceNotificationRequest`
/// (`AmsHeader.h:92`): `indexGroup u32, indexOffset u32, cbLength u32,
/// nTransMode u32, nMaxDelay u32, nCycleTime u32`, followed by 16 reserved
/// zero bytes. Omitting the reserved bytes is the classic off-by-16 bug (a real
/// PLC and the mock both size-check), so they are always present.
///
/// [maxDelay100ns] and [cycleTime100ns] are in 100ns units
/// (`Duration.inMicroseconds * 10`). Every u32 field is range-checked via
/// [checkUint], failing fast rather than silently truncating on the wire.
Uint8List buildAddNotificationPayload({
  required int indexGroup,
  required int indexOffset,
  required int length,
  required int transMode,
  required int maxDelay100ns,
  required int cycleTime100ns,
}) {
  final payload = Uint8List(40); // 24 fields + 16 reserved
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, checkUint(indexGroup, 32, 'indexGroup'), Endian.little);
  bd.setUint32(4, checkUint(indexOffset, 32, 'indexOffset'), Endian.little);
  bd.setUint32(8, checkUint(length, 32, 'length'), Endian.little);
  bd.setUint32(12, checkUint(transMode, 32, 'transMode'), Endian.little);
  bd.setUint32(16, checkUint(maxDelay100ns, 32, 'maxDelay'), Endian.little);
  bd.setUint32(20, checkUint(cycleTime100ns, 32, 'cycleTime'), Endian.little);
  // bytes 24..39 remain zero (reserved)
  return payload;
}

/// Builds the DeleteDeviceNotification (0x07) request payload — 4 bytes: the
/// notification [handle] as a little-endian u32.
Uint8List buildDeleteNotificationPayload({required int handle}) {
  final payload = Uint8List(4);
  ByteData.sublistView(payload)
      .setUint32(0, checkUint(handle, 32, 'handle'), Endian.little);
  return payload;
}

// ---------------------------------------------------------------------------
// Response decoders
// ---------------------------------------------------------------------------

/// Decodes the AddDeviceNotification (0x06) response: `result u32` followed by
/// the `notificationHandle u32`.
///
/// On a success (`result == 0`) payload the full 8 bytes are required and the
/// handle is read at offset 4. On a non-zero result the payload may carry only
/// the 4-byte result (handle absent) — mirroring the `commands.dart`
/// "check result before reading data" guard (threat T-3-02); the returned
/// `handle` is then `0`.
({int result, int handle}) decodeAddNotificationResponse(Uint8List payload) {
  _require(payload, 4, 'AddDeviceNotification response');
  final bd = ByteData.sublistView(payload);
  final result = bd.getUint32(0, Endian.little);
  if (result != 0) {
    return (result: result, handle: 0);
  }
  _require(payload, 8, 'AddDeviceNotification success response');
  return (result: result, handle: bd.getUint32(4, Endian.little));
}

/// Decodes the DeleteDeviceNotification (0x07) response (4 bytes): `result u32`.
int decodeDeleteNotificationResponse(Uint8List payload) {
  _require(payload, 4, 'DeleteDeviceNotification response');
  return ByteData.sublistView(payload).getUint32(0, Endian.little);
}

// ---------------------------------------------------------------------------
// Nested 0x08 stream parser
// ---------------------------------------------------------------------------

/// Parses an unsolicited DeviceNotification (0x08) stream payload into a flat
/// list of [AdsNotification] samples.
///
/// Wire layout (transcribed from `NotificationDispatcher::Run`,
/// `NotificationDispatcher.cpp:56`), all fields little-endian:
///
/// ```
/// length u32            // == payload.length - 4 (self-describing; validated)
/// stamps u32
/// per stamp (x stamps):
///   timestamp  u64      // FILETIME, 100ns ticks since 1601-01-01 UTC
///   sampleCount u32
///   per sample (x sampleCount):
///     handle u32        // demux key
///     size   u32        // data byte count
///     data[size]
/// ```
///
/// The C++ leading `fullLength` u32 is NOT on the wire (it is a ring-buffer
/// artefact), so the Dart payload begins at `length`. One wire sample maps to
/// one [AdsNotification]; every sample in a stamp shares that stamp's timestamp.
///
/// This is the untrusted-input boundary (threats T-5-03 / T-5-04): every field
/// read is bounds-checked against the remaining buffer BEFORE dereference, so a
/// truncated / oversized / lying-count frame throws [MalformedFrameException]
/// and never reads out of bounds. Each sample's data is a defensive copy that
/// does not alias the input buffer.
List<AdsNotification> parseNotificationStream(Uint8List payload) {
  if (payload.length < 8) {
    throw MalformedFrameException(
      'notification stream requires at least 8 bytes, got ${payload.length}',
      length: payload.length,
    );
  }
  final bd = ByteData.sublistView(payload);
  final length = bd.getUint32(0, Endian.little);
  if (length + 4 != payload.length) {
    throw MalformedFrameException(
      'notification length $length + 4 != payload ${payload.length}',
      length: length,
    );
  }
  final stamps = bd.getUint32(4, Endian.little);
  final out = <AdsNotification>[];
  var off = 8;
  for (var s = 0; s < stamps; s++) {
    if (off + 12 > payload.length) {
      throw MalformedFrameException('stamp header overrun', offset: off);
    }
    final timestamp = filetimeToDateTime(bd.getUint64(off, Endian.little));
    final sampleCount = bd.getUint32(off + 8, Endian.little);
    off += 12;
    for (var i = 0; i < sampleCount; i++) {
      if (off + 8 > payload.length) {
        throw MalformedFrameException('sample header overrun', offset: off);
      }
      final handle = bd.getUint32(off, Endian.little);
      final size = bd.getUint32(off + 4, Endian.little);
      off += 8;
      if (off + size > payload.length) {
        throw MalformedFrameException('sample data overrun', offset: off);
      }
      // Defensive copy so the returned data does not alias the source buffer.
      final data = Uint8List.fromList(payload.sublist(off, off + size));
      off += size;
      out.add(AdsNotification(handle: handle, timestamp: timestamp, data: data));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Throws [MalformedFrameException] if [payload] is shorter than [min] bytes.
void _require(Uint8List payload, int min, String what) {
  if (payload.length < min) {
    throw MalformedFrameException(
      '$what requires at least $min bytes, got ${payload.length}',
      length: payload.length,
    );
  }
}
