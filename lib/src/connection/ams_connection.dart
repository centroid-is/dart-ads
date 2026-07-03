/// The [AmsConnection] (L4) — the correctness core of the ADS transport stack.
///
/// It owns the monotonic invoke-ID counter and the invoke-ID→[PendingRequest]
/// correlation map, stamps and sends outbound frames through an injected
/// [AdsTransport], feeds inbound bytes into the Phase-1 [FrameAssembler],
/// correlates each response to its request Future, enforces a per-request
/// timeout, routes cmd 0x08 notification frames to the demux path, and (in
/// Task 3) performs a single-shot disconnect fan-out.
///
/// The single hard invariant is **map-remove-wins**: `_pending.remove(id)` is
/// the only way to claim a request, so exactly one of {response, timeout,
/// disconnect fan-out} completes each [Completer] on Dart's single event loop —
/// no locks, no double-complete.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../protocol/ams_header.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/ams_tcp_header.dart';
import '../protocol/constants.dart';
import '../protocol/exceptions.dart';
import '../protocol/frame_assembler.dart';
import '../transport/transport.dart';
import 'exceptions.dart';
import 'pending_request.dart';

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
  })  : _transport = transport,
        _source = source,
        _target = target,
        _defaultTimeout = defaultTimeout;

  final AdsTransport _transport;
  final AmsAddr _source;
  final AmsAddr _target;
  final Duration _defaultTimeout;

  /// Invoke-ID → in-flight request. `remove` is the sole completion claim.
  final Map<int, PendingRequest> _pending = <int, PendingRequest>{};

  /// Notification-handle → demux controller. Empty in Phase 2 (Phase 5 attaches
  /// real Streams); the disconnect fan-out already closes each with error.
  final Map<int, StreamController<Uint8List>> _demuxControllers =
      <int, StreamController<Uint8List>>{};

  /// The Phase-1 reassembler turning inbound TCP chunks into whole frames.
  late final FrameAssembler _assembler;

  /// The inbound subscription, cancelled on teardown.
  StreamSubscription<Uint8List>? _subscription;

  /// Monotonic u32 invoke-ID counter; starts at 1, wraps to 1 (0 is reserved
  /// for notifications).
  int _nextInvokeId = 1;

  bool _connected = false;
  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();

  /// Whether the connection is currently usable (connected and not yet closed).
  bool get isConnected => _connected && !_closed;

  /// Completes when the connection is fully torn down (clean close or error).
  Future<void> get done => _doneCompleter.future;

  /// Count of inbound responses that matched no pending request (late/unknown).
  int droppedResponses = 0;

  /// Count of inbound device-notification (cmd 0x08) frames routed to demux.
  int notificationFrames = 0;

  /// Opens the underlying transport to [host]:[port] and wires the inbound
  /// byte stream into the frame reassembler.
  ///
  /// Inbound chunks are pushed through a [FrameAssembler]; each complete frame
  /// is routed to [_onFrame]. A [MalformedFrameException] poisons the assembler
  /// (the stream is corrupt by definition), so it tears the connection down.
  /// The stream's `onError`/`onDone` are the disconnect signals fanned out in
  /// [_failClose].
  Future<void> connect(String host, int port) async {
    await _transport.connect(host, port);
    _assembler = FrameAssembler();
    _connected = true;
    _subscription = _transport.inbound.listen(
      (chunk) {
        try {
          for (final frame in _assembler.add(chunk)) {
            _onFrame(frame);
          }
        } on MalformedFrameException catch (e) {
          _failClose(e);
        }
      },
      onError: (Object e) => _failClose(e),
      onDone: () =>
          _failClose(const AdsConnectionException('peer closed connection')),
      cancelOnError: false,
    );
  }

  /// Sends [payload] under [commandId] and returns a Future resolving to the
  /// correlated raw response payload (bytes after the 38-byte header prefix).
  ///
  /// A per-request [timeout] (or the connection [_defaultTimeout]) removes and
  /// errors the pending entry with [AdsTimeoutException] on expiry. The write is
  /// fire-and-forget, so two `request` calls without an `await` between them
  /// pipeline naturally.
  Future<Uint8List> request(
    int commandId,
    Uint8List payload, {
    Duration? timeout,
  }) {
    if (!isConnected) {
      throw const AdsConnectionException('not connected');
    }
    final id = _allocInvokeId();
    // Build (and range-check) the frame BEFORE registering any pending state:
    // encode throws a synchronous ArgumentError for out-of-range fields (e.g.
    // a commandId outside u16), and a throw here must leave nothing behind —
    // no orphaned completer whose armed Timer would later fire an unhandled
    // async error (CR-01).
    final frame = _buildFrame(commandId, id, payload);
    final completer = Completer<Uint8List>();
    final timer = Timer(timeout ?? _defaultTimeout, () {
      // remove-wins: null if the response already claimed this request.
      final pending = _pending.remove(id);
      pending?.completer.completeError(AdsTimeoutException(id, commandId));
    });
    _pending[id] = PendingRequest(completer, timer, commandId);
    try {
      _transport.add(frame);
    } catch (_) {
      // Defense against a transport whose add() throws synchronously: undo the
      // registration so the sync throw leaves no armed timer behind.
      _pending.remove(id);
      timer.cancel();
      rethrow;
    }
    return completer.future;
  }

  /// Gracefully tears the connection down, erroring every pending request.
  ///
  /// Idempotent: routes through the single-shot [_failClose], then awaits
  /// [done]. Calling it after a disconnect is a no-op.
  Future<void> close() async {
    _failClose(const AdsConnectionException('closed by client'));
    await done;
  }

  /// Allocates the next monotonic u32 invoke-ID, wrapping `0xFFFFFFFF → 1` and
  /// never yielding 0 (0 is reserved for notification frames).
  ///
  /// IDs still in flight when the counter wraps back onto them are skipped
  /// (WR-01): overwriting a live [_pending] entry would leave the older timer
  /// armed on the same ID, and its `remove` would claim the NEW request's
  /// entry — permanently hanging the new caller's Future. The skip loop is
  /// bounded by the sanity guard: it can only fail to terminate if every one
  /// of the ~4 billion IDs is simultaneously pending, which the guard rejects
  /// up front.
  int _allocInvokeId() {
    if (_pending.length >= 0xFFFFFFFE) {
      throw StateError(
        'no free invoke-IDs: ${_pending.length} requests already in flight',
      );
    }
    var id = _nextInvokeId;
    while (_pending.containsKey(id)) {
      id = id == 0xFFFFFFFF ? 1 : id + 1;
    }
    _nextInvokeId = id == 0xFFFFFFFF ? 1 : id + 1;
    return id;
  }

  /// Test seam: overrides the ID the allocator tries next, so wrap-around
  /// collision behaviour (WR-01) is testable without issuing 2^32 requests.
  @visibleForTesting
  set debugNextInvokeId(int value) => _nextInvokeId = value;

  /// Builds the on-wire frame: 6-byte AMS/TCP wrapper + 32-byte AMS header +
  /// [payload], stamping [invokeId] and [commandId] via the real Phase-1
  /// encoders (range-checked, little-endian).
  Uint8List _buildFrame(int commandId, int invokeId, Uint8List payload) {
    final ams = AmsHeader(
      targetNetId: _target.netId,
      targetPort: _target.port,
      sourceNetId: _source.netId,
      sourcePort: _source.port,
      commandId: commandId,
      stateFlags: AmsStateFlags.request,
      dataLength: payload.length,
      errorCode: 0,
      invokeId: invokeId,
    ).encode();
    final tcp =
        AmsTcpHeader(length: AmsHeader.byteLength + payload.length).encode();
    final total =
        AmsTcpHeader.byteLength + AmsHeader.byteLength + payload.length;
    final out = Uint8List(total)
      ..setRange(0, AmsTcpHeader.byteLength, tcp)
      ..setRange(AmsTcpHeader.byteLength,
          AmsTcpHeader.byteLength + AmsHeader.byteLength, ams)
      ..setRange(
          AmsTcpHeader.byteLength + AmsHeader.byteLength, total, payload);
    return out;
  }

  /// Routes one complete inbound frame.
  ///
  /// Demux-before-lookup: a cmd 0x08 device-notification frame is counted and
  /// returned WITHOUT touching the pending map or [droppedResponses] (Phase 5
  /// hangs real notification Streams off this hook). Otherwise the invoke-ID is
  /// claimed via `_pending.remove`; an unmatched response (late/unknown) is
  /// counted as dropped and never throws; a valid-invokeId / wrong-command frame
  /// completes-with-error rather than crossing responses.
  void _onFrame(Uint8List frame) {
    final header =
        AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);

    // Demux branch BEFORE the invoke-ID lookup (PROTO-04).
    if (header.commandId == AdsCommandId.deviceNotification) {
      notificationFrames++;
      return;
    }

    final pending = _pending.remove(header.invokeId);
    if (pending == null) {
      // Late/unknown response is EXPECTED after a timeout — count, never throw.
      droppedResponses++;
      return;
    }
    pending.timer.cancel();

    if (header.commandId != pending.expectedCommandId) {
      droppedResponses++;
      pending.completer.completeError(
        const AdsConnectionException('protocol: command mismatch'),
      );
      return;
    }

    pending.completer.complete(
      Uint8List.sublistView(
        frame,
        AmsTcpHeader.byteLength + AmsHeader.byteLength,
      ),
    );
  }

  /// Single-shot disconnect fan-out (TRANS-03).
  ///
  /// Ordering: set `_closed` first (fail-fast for re-entrancy) → snapshot+clear
  /// the pending map BEFORE erroring (so `completeError` callbacks can't mutate
  /// the map being drained, and a stray timeout can't fire mid-fan-out) → error
  /// every pending with [AdsConnectionException] → error+close every
  /// notification controller → close the transport → complete [done]. The
  /// `_closed` guard makes a following `onError`+`onDone` (or a `close()`)
  /// idempotent — no double-complete, no hung Futures.
  void _failClose(Object cause) {
    if (_closed) return;
    _closed = true;
    _subscription?.cancel();

    final error = _asConnectionException(cause);

    final pending = List.of(_pending.values);
    _pending.clear();
    for (final p in pending) {
      p.timer.cancel();
      p.completer.completeError(error);
    }

    for (final controller in _demuxControllers.values) {
      controller.addError(error);
      controller.close();
    }
    _demuxControllers.clear();

    _transport.close();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  /// Normalises a disconnect [cause] into an [AdsConnectionException]: passes an
  /// existing one through (preserving its message) and wraps any other error as
  /// the [AdsConnectionException.cause].
  AdsConnectionException _asConnectionException(Object cause) =>
      cause is AdsConnectionException
          ? cause
          : AdsConnectionException('connection lost', cause: cause);
}
