@Tags(['unit'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ads/src/transport/fake_transport.dart';
import 'package:test/test.dart';

/// Behavioural coverage for [FakeTransport], the in-memory transport double that
/// unlocks TRANS-04 (correlation/lifecycle logic is unit-testable with no live
/// socket). Reaching into `src/` is acceptable here: this is a same-package unit
/// test of an intentionally test-only double that the curated public barrel does
/// not export.
void main() {
  group('FakeTransport', () {
    test('add() records the exact bytes into written', () {
      final transport = FakeTransport();
      final frame = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

      transport.add(frame);

      expect(transport.written, hasLength(1));
      expect(transport.written.single, equals(frame));
    });

    test('add() copies so later caller mutation cannot corrupt the record', () {
      final transport = FakeTransport();
      final buffer = Uint8List.fromList([1, 2, 3]);

      transport.add(buffer);
      buffer[0] = 99; // mutate the caller's buffer after recording

      expect(transport.written.single, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('feed() delivers bytes to an inbound subscriber, in order', () async {
      final transport = FakeTransport();
      final received = <Uint8List>[];
      final done = Completer<void>();

      transport.inbound.listen(received.add, onDone: done.complete);

      transport.feed(Uint8List.fromList([1, 2]));
      transport.feed(Uint8List.fromList([3, 4]));
      await transport.close();
      await done.future;

      expect(received, hasLength(2));
      expect(received[0], equals(Uint8List.fromList([1, 2])));
      expect(received[1], equals(Uint8List.fromList([3, 4])));
    });

    test('simulateDisconnect() with no arg triggers inbound onDone', () async {
      final transport = FakeTransport();
      final done = Completer<void>();
      var errored = false;

      transport.inbound.listen(
        (_) {},
        onError: (Object _) => errored = true,
        onDone: done.complete,
      );

      transport.simulateDisconnect();

      await done.future; // completes only if onDone fired
      expect(errored, isFalse);
    });

    test('simulateDisconnect(error) delivers that error via onError', () async {
      final transport = FakeTransport();
      final caught = Completer<Object>();
      final boom = StateError('peer reset');

      transport.inbound.listen(
        (_) {},
        onError: caught.complete,
        cancelOnError: true,
      );

      transport.simulateDisconnect(boom);

      expect(await caught.future, same(boom));
    });
  });
}
