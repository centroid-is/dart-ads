/// An in-memory [AdsTransport] for unit tests — no sockets, no I/O.
///
/// This is the fakeable seam that unlocks TRANS-04: it lets the connection layer
/// (Plan 02-03) be exercised for correlation, timeout, and disconnect fan-out
/// with zero live sockets. Outbound bytes are captured in [written] so tests can
/// assert invoke-ID stamping and frame content; inbound bytes are driven with
/// [feed]; and a disconnect (clean or errored) is driven with
/// [simulateDisconnect].
library;

import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// An in-memory [AdsTransport] test double.
///
/// Ergonomics (beyond the four interface members) are test-only drivers:
/// [written] records outbound frames, [feed] pushes server→client bytes, and
/// [simulateDisconnect] triggers the inbound stream's `onDone`/`onError` so the
/// connection layer's fan-out can be tested deterministically.
class FakeTransport implements AdsTransport {
  /// Single-subscription controller backing [inbound]; [feed] and
  /// [simulateDisconnect] drive it.
  final StreamController<Uint8List> _inbound = StreamController<Uint8List>();

  /// Every outbound chunk passed to [add], copied so later mutation of the
  /// caller's buffer cannot corrupt the recorded frame. Tests assert against
  /// this to verify invoke-ID stamping and outbound framing.
  final List<Uint8List> written = <Uint8List>[];

  @override
  Future<void> connect(String host, int port) async {
    // No socket to open; completing is enough to satisfy the interface.
  }

  @override
  void add(List<int> bytes) => written.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> close() => _inbound.close();

  /// Test driver: delivers [serverBytes] to the [inbound] subscriber as if the
  /// peer sent them (server→client). Bytes arrive in call order.
  void feed(Uint8List serverBytes) => _inbound.add(serverBytes);

  /// Test driver: simulates the peer dropping the connection.
  ///
  /// With no argument, closes the inbound stream (clean FIN → `onDone`). With an
  /// [error], delivers it via the inbound stream (RST/reset → `onError`). This
  /// is how the connection layer's disconnect fan-out is triggered without a
  /// live socket.
  void simulateDisconnect([Object? error]) {
    if (error == null) {
      _inbound.close();
    } else {
      _inbound.addError(error);
    }
  }
}
