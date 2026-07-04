/// The real `dart:io` implementation of [AdsTransport].
///
/// This is the first (and only, in this plan) file in `lib/` that imports
/// `dart:io`. A `dart:io` `Socket` already IS a `Stream<Uint8List>` AND an
/// `IOSink`, so this adapter is thin: it holds a nullable socket, wires TCP
/// no-delay for low-latency small frames, and tears down with `flush()` then
/// `destroy()` (never a bare `close()`, which only half-closes the write side).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// An [AdsTransport] backed by a real TCP `dart:io` `Socket`.
///
/// Construct, then [connect]; the [inbound] stream and [add] are only valid
/// after a successful [connect]. Not reusable across reconnects: once [close]d,
/// a fresh instance should be created (reconnect policy is a v2 concern).
class SocketTransport implements AdsTransport {
  /// The live socket, or `null` before [connect] / after [close].
  Socket? _socket;

  /// Set by [close]; guards against a dial that completes AFTERWARDS.
  ///
  /// `AmsRouter.connect` races the dial against its `connectTimeout` and, on
  /// expiry, tears the connection (and this transport) down while
  /// `Socket.connect` may still be pending. When that abandoned dial finally
  /// completes, the socket must be destroyed immediately — otherwise the fd
  /// would leak with no handle left to close it.
  bool _closed = false;

  @override
  Future<void> connect(String host, int port) async {
    final socket = await Socket.connect(host, port);
    if (_closed) {
      // close() ran while the dial was in flight (e.g. a dial-timeout
      // rollback): release the late socket instead of leaking it.
      socket.destroy();
      throw StateError('SocketTransport closed before connect() completed');
    }
    // Disable Nagle: ADS frames are small and latency-sensitive, so we want
    // each write on the wire immediately rather than coalesced.
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
  }

  @override
  Stream<Uint8List> get inbound {
    final socket = _socket;
    if (socket == null) {
      throw StateError('inbound accessed before connect()');
    }
    // A Socket IS a single-subscription Stream<Uint8List>.
    return socket;
  }

  @override
  void add(List<int> bytes) {
    final socket = _socket;
    if (socket == null) {
      throw StateError('add() called before connect()');
    }
    socket.add(bytes);
  }

  @override
  String? get localAddress {
    // dart:io `Socket.address` is the LOCAL InternetAddress obtained via
    // getsockname; `.remoteAddress` (deliberately NOT used) is the peer. `.address`
    // is the dotted-decimal string. Null before connect / after close.
    return _socket?.address.address;
  }

  @override
  Future<void> close() async {
    _closed = true; // a dial still in flight will self-destroy on completion
    final socket = _socket;
    if (socket == null) return;
    _socket = null;
    // Flush buffered writes first; the peer may already be gone, in which case
    // flush throws — tolerated, we tear down regardless (T-2-01).
    try {
      await socket.flush();
    } catch (_) {
      // Peer gone / write half already broken; proceed to destroy.
    }
    // destroy() releases BOTH directions immediately. A bare close() would only
    // half-close (send FIN) and leave the write side dangling.
    socket.destroy();
  }
}
