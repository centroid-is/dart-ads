/// The ADS-agnostic transport seam.
///
/// This file defines the single narrow byte-pipe interface that the connection
/// layer ([AmsConnection], Plan 02-03) is constructed against. It is the first
/// abstraction in the package that touches `dart:async` — the `protocol/`
/// subtree stays pure; I/O enters at the transport layer and above.
///
/// The interface is deliberately minimal (exactly four members): open a TCP
/// connection, push outbound bytes, expose inbound bytes as a stream, and close.
/// It knows nothing about ADS framing, invoke-IDs, or correlation — those live
/// one layer up. Keeping it this small makes `SocketTransport` (real `dart:io`
/// socket) and `FakeTransport` (in-memory test double) trivially symmetric so
/// the correlation logic can be unit-tested without a live socket (TRANS-04).
library;

import 'dart:async';
import 'dart:typed_data';

/// A bidirectional byte pipe to a single ADS peer.
///
/// Implementations move raw bytes only; they do not interpret AMS/TCP framing.
/// Two implementations exist: `SocketTransport` (a `dart:io` `Socket`) for real
/// connections, and `FakeTransport` (an in-memory `StreamController`) for unit
/// tests.
///
/// Connection-state exposure (`isConnected` / `done`) is intentionally NOT part
/// of this interface — that surface belongs to the `AmsConnection` that owns the
/// correlation map and disconnect fan-out, not to the dumb byte pipe.
abstract interface class AdsTransport {
  /// Opens a TCP connection to [host] on [port].
  ///
  /// Completes once the connection is established. Throws (e.g. a
  /// `SocketException`) if the peer refuses or is unreachable. Must be called —
  /// and must complete — before [inbound] or [add] are used.
  Future<void> connect(String host, int port);

  /// Queues [bytes] for transmission to the peer.
  ///
  /// Non-blocking and buffered: the write is enqueued on the underlying sink and
  /// flushed by the event loop. Only valid after [connect] has completed.
  void add(List<int> bytes);

  /// The inbound byte stream from the peer.
  ///
  /// Single-subscription: listen exactly once. Chunks arrive as raw
  /// [Uint8List]s in arrival order with no framing applied — the caller feeds
  /// them into a frame reassembler. The stream's `onDone`/`onError` are the
  /// disconnect signal the connection layer fans out on. Only valid after
  /// [connect] has completed.
  Stream<Uint8List> get inbound;

  /// Closes the connection, releasing both directions immediately.
  ///
  /// Implementations flush any buffered outbound bytes, then destroy the
  /// underlying socket so neither the read nor the write half is left dangling.
  /// Idempotent: calling [close] on an already-closed transport is a no-op.
  Future<void> close();
}
