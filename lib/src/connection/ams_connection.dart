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

import '../protocol/ads_error.dart';
import '../protocol/ams_header.dart';
import '../protocol/ams_net_id.dart';
import '../protocol/ams_tcp_header.dart';
import '../protocol/constants.dart';
import '../protocol/exceptions.dart';
import '../protocol/frame_assembler.dart';
import '../protocol/notifications.dart';
import '../transport/transport.dart';
import 'exceptions.dart';
import 'pending_request.dart';

/// A single multiplexed AMS/TCP connection to one ADS peer.
///
/// Construct with an [AdsTransport] plus the fixed [source]/[target] AMS
/// addresses, then [connect]. Issue [request]s (each returns a `Future` that
/// resolves to a record of the AMS `errorCode` and the raw response payload);
/// observe liveness via [isConnected]
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

  /// Notification-handle → demux controller. Populated by [addNotification]
  /// (synchronously, in the Add-response correlation hook) and drained by the
  /// cmd 0x08 dispatch; the disconnect fan-out error-closes each and clears it.
  final Map<int, StreamController<AdsNotification>> _demuxControllers =
      <int, StreamController<AdsNotification>>{};

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

  /// Count of cmd 0x08 frames whose payload failed to parse (hostile / truncated
  /// / lying-count). The 0x08 branch contains its own errors: a malformed frame
  /// bumps this counter and is dropped, but the connection survives so one bad
  /// notification cannot kill other live subscriptions (threat T-5-02).
  int droppedNotifications = 0;

  /// Opens the underlying transport to [host]:[port] and wires the inbound
  /// byte stream into the frame reassembler.
  ///
  /// Inbound chunks are pushed through a [FrameAssembler]; each complete frame
  /// is routed to [_onFrame]. A [MalformedFrameException] poisons the assembler
  /// (the stream is corrupt by definition), so it tears the connection down.
  /// The stream's `onError`/`onDone` are the disconnect signals fanned out in
  /// [_failClose].
  ///
  /// Throws a [StateError] if called more than once or after [close]: the
  /// connection is single-use (reconnect policy is a v2 concern), and the
  /// guard must run BEFORE the transport is touched so a rejected call can
  /// never open (and then leak) a socket.
  Future<void> connect(String host, int port) async {
    if (_connected || _closed) {
      throw StateError(
        'AmsConnection is single-use: '
        'already ${_closed ? 'closed' : 'connected'}',
      );
    }
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

  /// Sends [payload] under [commandId] and returns a Future resolving to a
  /// record of the correlated AMS-header `errorCode` and the raw response
  /// payload (bytes after the 38-byte header prefix).
  ///
  /// The connection surfaces the raw AMS `errorCode` WITHOUT interpreting it:
  /// the ADS error table lives in `protocol/` and mapping is the client's job
  /// (ERR-01 throws at both the AMS-header level and the payload-result level).
  /// This layer stays transport-pure — it never imports the error table.
  ///
  /// A per-request [timeout] (or the connection [_defaultTimeout]) removes and
  /// errors the pending entry with [AdsTimeoutException] on expiry. The write is
  /// fire-and-forget, so two `request` calls without an `await` between them
  /// pipeline naturally.
  ///
  /// [onResponseSync] runs synchronously the instant the response is correlated
  /// (before the returned Future completes and before any later frame in the
  /// same inbound chunk is dispatched); [addNotification] uses it to register a
  /// demux controller ahead of a same-chunk 0x08 frame.
  Future<({int errorCode, Uint8List payload})> request(
    int commandId,
    Uint8List payload, {
    Duration? timeout,
    void Function(int errorCode, Uint8List payload)? onResponseSync,
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
    final completer = Completer<({int errorCode, Uint8List payload})>();
    final timer = Timer(timeout ?? _defaultTimeout, () {
      // remove-wins: null if the response already claimed this request.
      final pending = _pending.remove(id);
      pending?.completer.completeError(AdsTimeoutException(id, commandId));
    });
    _pending[id] = PendingRequest(completer, timer, commandId, onResponseSync);
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

  /// Sends an AddDeviceNotification (cmd 0x06) [payload], registers [ctrl] under
  /// the returned handle, and resolves to that handle.
  ///
  /// TRUE SYNCHRONOUS REGISTRATION (closes the first-listen race, threat
  /// T-5-11): the controller is mapped in the [request] `onResponseSync` hook —
  /// which fires inside `_onFrame`, in the same synchronous turn the Add-response
  /// is correlated, BEFORE this Future completes. Because inbound TCP chunks are
  /// dispatched frame-by-frame in one drain, a 0x08 frame for this handle that
  /// shares the Add-response's chunk is parsed AFTER the hook has already mapped
  /// the handle, so its first sample is delivered rather than dropped. A
  /// post-`await` registration would instead run one microtask too late (after
  /// that same-chunk 0x08 was already dispatched) — hence the hook, not the
  /// obvious `await`-then-register.
  ///
  /// A non-zero AMS-header `errorCode` or a non-zero decoded `result` throws an
  /// [AdsException] to the caller; in those cases the hook registered nothing
  /// (it early-returns before the map write), so no dangling controller is left.
  Future<int> addNotification(
    Uint8List payload,
    StreamController<AdsNotification> ctrl, {
    Duration? timeout,
  }) async {
    final resp = await request(
      AdsCommandId.addDeviceNotification,
      payload,
      timeout: timeout,
      onResponseSync: (errorCode, respPayload) {
        // Only a fully-successful response registers the controller. Any error
        // path leaves the map untouched; the await-side below throws for it.
        if (errorCode != 0) {
          return;
        }
        final decoded = decodeAddNotificationResponse(respPayload);
        if (decoded.result != 0) {
          return;
        }
        _demuxControllers[decoded.handle] = ctrl;
      },
    );
    if (resp.errorCode != 0) {
      throw AdsException.fromCode(resp.errorCode);
    }
    final decoded = decodeAddNotificationResponse(resp.payload);
    if (decoded.result != 0) {
      throw AdsException.fromCode(decoded.result);
    }
    return decoded.handle;
  }

  /// Sends a DeleteDeviceNotification (cmd 0x07) [payload], removes [handle]
  /// from the demux map, closes its controller, and surfaces a server refusal.
  ///
  /// LOCAL INVALIDATION IS UNCONDITIONAL (WR-01): the demux entry is removed
  /// and its controller closed in a `finally`, so EVERY outcome — success,
  /// server refusal, per-request timeout, dead connection — leaves no zombie
  /// routing target behind. Local cleanup is safe regardless of the server's
  /// verdict: a stale handle is never Deleted against a reconnected session
  /// (threat T-5-10; on disconnect `_failClose` has already invalidated and
  /// cleared every handle), and a refused Delete still means this client will
  /// never route samples for the handle again.
  ///
  /// A non-zero AMS-header `errorCode` or a non-zero decoded ADS `result`
  /// (e.g. `0x752 ADSERR_CLIENT_REMOVEHASH`) throws [AdsException] — a server
  /// that refuses the Delete keeps its handle alive, and a direct caller must
  /// see that. `AdsClient._deleteQuietly` swallows this BY POLICY on the
  /// cancel path (cancel never throws, threat T-5-12); the policy is sound
  /// only because this layer tells the truth.
  Future<void> deleteNotification(
    int handle,
    Uint8List payload, {
    Duration? timeout,
  }) async {
    // IDENTITY-GUARDED removal (CR-01): capture the controller this Delete
    // concerns BEFORE the round-trip. [addNotification] maps its controller
    // SYNCHRONOUSLY (in the onResponseSync hook, inside _onFrame), but this
    // method's removal runs in an await continuation — one microtask AFTER the
    // whole inbound chunk has drained. If the server recycles [handle] for a
    // pipelined Add whose response shares the Delete-response's TCP chunk, the
    // new controller is already mapped by the time this continuation runs; an
    // unguarded `remove(handle)` would remove and close the NEW subscription's
    // controller (silent data loss). Removing only when the mapped controller
    // is still `identical` to the captured one makes the stale continuation a
    // no-op for the recycled handle.
    final victim = _demuxControllers[handle];
    ({int errorCode, Uint8List payload}) resp;
    try {
      resp = await request(
        AdsCommandId.deleteDeviceNotification,
        payload,
        timeout: timeout,
      );
    } finally {
      if (identical(_demuxControllers[handle], victim)) {
        _demuxControllers.remove(handle);
      }
      // Fire-and-forget the close: a single-subscription controller with no
      // live listener only completes its close() future once listened, so
      // awaiting it here could hang. The stream is done regardless; the caller
      // does not need to observe teardown completion.
      unawaited(victim?.close() ?? Future<void>.value());
    }
    if (resp.errorCode != 0) {
      throw AdsException.fromCode(resp.errorCode);
    }
    final result = decodeDeleteNotificationResponse(resp.payload);
    if (result != 0) {
      throw AdsException.fromCode(result);
    }
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

    // Demux branch BEFORE the invoke-ID lookup (PROTO-04). Parse the nested
    // 0x08 stream and route each sample to its handle's controller (an
    // unregistered handle is silently ignored, C++ parity).
    //
    // This branch CONTAINS ITS OWN ERRORS BY DESIGN (threat T-5-02): the parse
    // runs in a local try/catch that swallows any [MalformedFrameException] and
    // bumps [droppedNotifications]. It must never rethrow — a hostile 0x08 frame
    // reaching the `connect()` listener's `on MalformedFrameException` catch
    // would `_failClose` the whole connection, letting one bad notification kill
    // every other live subscription. A truly corrupt byte STREAM still poisons
    // the assembler upstream and closes; only per-frame notification parse
    // failures are contained here.
    if (header.commandId == AdsCommandId.deviceNotification) {
      notificationFrames++;
      final notificationPayload = Uint8List.sublistView(
        frame,
        AmsTcpHeader.byteLength + AmsHeader.byteLength,
      );
      try {
        for (final n in parseNotificationStream(notificationPayload)) {
          _demuxControllers[n.handle]?.add(n);
        }
      } catch (_) {
        droppedNotifications++;
      }
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

    // Surface the raw AMS-header errorCode alongside the payload; the client
    // (not this transport core) maps it to an AdsException.
    final responsePayload = Uint8List.sublistView(
      frame,
      AmsTcpHeader.byteLength + AmsHeader.byteLength,
    );

    // Synchronous response hook runs BEFORE completion: addNotification uses it
    // to register its demux controller in this same _onFrame turn, so a 0x08
    // frame later in the same inbound chunk finds the handle already mapped.
    // A throwing hook must never break correlation, so it is wrapped defensively
    // (the caller's Future still completes below).
    try {
      pending.onResponseSync?.call(header.errorCode, responsePayload);
    } catch (_) {
      // Swallow: the hook is a best-effort side-effect, not part of the
      // response contract. The await-side of addNotification re-decodes and
      // throws for real error conditions.
    }

    pending.completer.complete(
      (errorCode: header.errorCode, payload: responsePayload),
    );
  }

  /// Single-shot disconnect fan-out (TRANS-03).
  ///
  /// Ordering: set `_closed` first (fail-fast for re-entrancy) → snapshot+clear
  /// the pending map BEFORE erroring (so `completeError` callbacks can't mutate
  /// the map being drained, and a stray timeout can't fire mid-fan-out) → error
  /// every pending with [AdsConnectionException] → error+close every
  /// notification controller → close the transport → complete [done] once the
  /// transport teardown actually finishes (WR-03: `done`'s contract is "fully
  /// torn down", so it must not complete while the socket is still mid-flush).
  /// The `_closed` guard makes a following `onError`+`onDone` (or a `close()`)
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

    // Chain [done] off the transport teardown rather than completing it
    // eagerly: SocketTransport.close() awaits flush() before destroy(), and
    // `await conn.close()` must not return while the fd is still open.
    // _failClose itself stays synchronous and single-shot.
    _transport.close().whenComplete(() {
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    });
  }

  /// Normalises a disconnect [cause] into an [AdsConnectionException]: passes an
  /// existing one through (preserving its message) and wraps any other error as
  /// the [AdsConnectionException.cause].
  AdsConnectionException _asConnectionException(Object cause) =>
      cause is AdsConnectionException
          ? cause
          : AdsConnectionException('connection lost', cause: cause);
}
