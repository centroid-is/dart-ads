/// The [FrameAssembler] — a pure, synchronous, stateful AMS/TCP frame
/// reassembler.
///
/// Pure: imports only `dart:typed_data` plus sibling protocol types. It pulls
/// in no async or socket SDK libraries anywhere in this file (or the rest of
/// the `protocol/` subtree), so the reassembly logic is fully unit-testable
/// with no sockets. The live socket that feeds this assembler arrives in a
/// later phase; the reassembly logic is proven against realistic segmentation
/// from day one.
library;

import 'dart:typed_data';

import 'ams_tcp_header.dart';
import 'exceptions.dart';

/// Reassembles an arbitrarily-segmented TCP byte stream into complete AMS
/// frames.
///
/// A complete on-wire frame is `[6-byte AMS/TCP wrapper][32-byte AMS header]
/// [ADS payload]`. The AMS/TCP wrapper carries a `length` u32 at offset 2
/// (little-endian) that counts every byte *after* the 6-byte wrapper — i.e.
/// `length = 32 + payload`. So the total size of one frame on the wire is
/// `6 + length` (see [AmsTcpHeader]).
///
/// TCP gives no message boundaries: a single logical frame may arrive split
/// across many `add` calls (fragmentation), or several frames may arrive
/// coalesced into one `add` call. [add] buffers bytes across calls (this class
/// is stateful) and emits each complete frame exactly once, in order.
///
/// ## Max-frame guard (DoS mitigation)
///
/// A hostile or corrupt peer can send a wrapper whose `length` field claims a
/// huge frame, tricking a naive reader into allocating gigabytes before any
/// payload arrives. [add] rejects any frame whose parsed `length` exceeds
/// [maxFrameBytes] by throwing [MalformedFrameException] *before* allocating the
/// frame buffer (RESEARCH Pitfall 4). The default guard is 4 MiB.
class FrameAssembler {
  /// Creates a frame assembler with an optional [maxFrameBytes] guard.
  ///
  /// [maxFrameBytes] is the largest permitted value of a frame's AMS/TCP
  /// `length` field (the bytes following the 6-byte wrapper). It defaults to
  /// 4 MiB per the locked protocol decision and must be positive.
  FrameAssembler({this.maxFrameBytes = 4 * 1024 * 1024})
      : assert(maxFrameBytes > 0, 'maxFrameBytes must be positive');

  /// The largest permitted AMS/TCP `length` field, in bytes. A frame whose
  /// length exceeds this is rejected before allocation.
  final int maxFrameBytes;

  /// Accumulated bytes received so far that have not yet been emitted as part
  /// of a complete frame. Always holds only the unparsed remainder.
  Uint8List _buffer = Uint8List(0);

  /// Whether any buffered bytes are currently retained (a partial frame is
  /// awaiting the rest of its bytes).
  bool get hasBufferedBytes => _buffer.isNotEmpty;

  /// The number of buffered bytes currently awaiting completion.
  int get bufferedLength => _buffer.length;

  /// Appends [chunk] to the internal buffer, then emits every complete frame
  /// now available.
  ///
  /// Returns the frames that became complete on this call, in wire order (may
  /// be empty when only a partial frame is buffered). Any trailing partial
  /// frame is retained internally for a future [add].
  ///
  /// Throws [MalformedFrameException] — *before* allocating the frame buffer —
  /// if a frame's AMS/TCP `length` field exceeds [maxFrameBytes].
  List<Uint8List> add(Uint8List chunk) {
    _buffer = _concat(_buffer, chunk);

    final frames = <Uint8List>[];
    var offset = 0;

    while (true) {
      final available = _buffer.length - offset;

      // Need the whole 6-byte wrapper before we can read the length field.
      if (available < AmsTcpHeader.byteLength) break;

      // Read the AMS/TCP length u32 directly from the buffer. No frame buffer
      // is allocated at this point, so the guard below runs before allocation.
      final length = ByteData.sublistView(_buffer)
          .getUint32(offset + 2, Endian.little);

      // Max-frame guard (DoS mitigation): reject a hostile length BEFORE
      // allocating a frame buffer of that size.
      if (length > maxFrameBytes) {
        throw MalformedFrameException(
          'AMS/TCP frame length exceeds max-frame guard '
          '($length > $maxFrameBytes bytes)',
          length: length,
          offset: offset,
        );
      }

      final total = AmsTcpHeader.byteLength + length;

      // Not all of this frame has arrived yet — wait for more bytes. We never
      // index past what is buffered, so a truncated frame simply waits.
      if (available < total) break;

      // Slice out exactly one complete frame as an independent copy so the
      // caller owns it and it does not alias future buffer state.
      frames.add(Uint8List.sublistView(_buffer, offset, offset + total)
          .sublist(0));
      offset += total;
    }

    // Retain only the unparsed remainder, releasing the consumed prefix.
    if (offset > 0) {
      _buffer =
          offset == _buffer.length ? Uint8List(0) : _buffer.sublist(offset);
    }

    return frames;
  }

  /// Concatenates two byte buffers into a freshly-owned [Uint8List].
  ///
  /// The result never aliases [b] (the caller's chunk), so a caller is free to
  /// reuse or mutate the buffer it passed to [add] afterwards.
  static Uint8List _concat(Uint8List a, Uint8List b) {
    if (a.isEmpty) return Uint8List.fromList(b);
    if (b.isEmpty) return a;
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }
}
