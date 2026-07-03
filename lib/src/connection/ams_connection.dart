/// The [AmsConnection] (L4) — the correctness core of the ADS transport stack.
///
/// It owns the monotonic invoke-ID counter and the invoke-ID→[PendingRequest]
/// correlation map, stamps and sends outbound frames through an injected
/// [AdsTransport], feeds inbound bytes into the Phase-1 frame reassembler,
/// correlates each response to its request Future, enforces a per-request
/// timeout, routes cmd 0x08 notification frames to the demux path, and performs
/// a single-shot disconnect fan-out.
///
/// NOTE: this file is the RED skeleton (Task 1). The public API surface is
/// complete so the behaviour tests compile, but the method bodies are not yet
/// implemented — correlation/timeout/demux land in Task 2 and the disconnect
/// fan-out + `close()` land in Task 3.
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/ams_net_id.dart';
import '../transport/transport.dart';

/// A single multiplexed AMS/TCP connection to one ADS peer.
///
/// Construct with an [AdsTransport] plus the fixed [source]/[target] AMS
/// addresses, then [connect]. Issue [request]s (each returns a `Future` that
/// resolves to the raw response payload); observe liveness via [isConnected]
/// and [done]; tear down with [close].
class AmsConnection {
  /// Creates a connection over [transport] addressed [source]→[target].
  ///
  /// [defaultTimeout] is the per-request timeout applied when a `request` does
  /// not pass its own `timeout` override.
  AmsConnection(
    AdsTransport transport, {
    required AmsAddr source,
    required AmsAddr target,
    Duration defaultTimeout = const Duration(seconds: 5),
  });

  /// Whether the connection is currently usable (connected and not yet closed).
  bool get isConnected => _connected && !_closed;

  /// Completes when the connection is fully torn down (clean close or error).
  Future<void> get done => _doneCompleter.future;

  /// Count of inbound responses that matched no pending request (late/unknown).
  int droppedResponses = 0;

  /// Count of inbound device-notification (cmd 0x08) frames routed to demux.
  int notificationFrames = 0;

  bool _connected = false;
  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();

  /// Opens the underlying transport to [host]:[port] and wires the inbound
  /// byte stream into the frame reassembler.
  Future<void> connect(String host, int port) async {
    _connected = true;
    throw UnimplementedError('inbound wiring lands in Task 2');
  }

  /// Sends [payload] under [commandId] and returns a Future resolving to the
  /// correlated raw response payload (bytes after the 38-byte header prefix).
  Future<Uint8List> request(
    int commandId,
    Uint8List payload, {
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  /// Gracefully tears the connection down, erroring every pending request.
  Future<void> close() async {
    _closed = true;
    throw UnimplementedError('disconnect fan-out lands in Task 3');
  }
}
