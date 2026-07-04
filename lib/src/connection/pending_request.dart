/// The [PendingRequest] record — one in-flight request awaiting its response.
///
/// This type is package-internal: it is intentionally NOT re-exported from the
/// public `dart_ads.dart` barrel. It pairs the [Completer] that resolves a
/// caller's `request()` Future with the per-request timeout [Timer] and the
/// [expectedCommandId] used to reject a response whose command does not match
/// the request. The raw [Completer] is never handed out beyond the owning
/// `AmsConnection`; only the connection completes it, and only ever after
/// removing this entry from its pending map (the map-remove-wins invariant).
///
/// Pure: imports only `dart:async` and `dart:typed_data`. No `dart:io`.
library;

import 'dart:async';
import 'dart:typed_data';

/// Internal bookkeeping for a single outstanding request.
///
/// Held in `AmsConnection`'s `Map<int, PendingRequest>` keyed by invoke-ID.
/// Exactly one of {response arrival, timeout, disconnect fan-out} removes the
/// entry from that map and completes [completer]; the losers observe a `null`
/// removal and do nothing, so [completer] is never completed twice.
class PendingRequest {
  /// Creates a pending-request record binding a [completer] to its timeout
  /// [timer] and the [expectedCommandId] the correlated response must carry.
  ///
  /// The optional [onResponseSync] hook lets a request act on its correlated
  /// response SYNCHRONOUSLY — inside the same `_onFrame` turn, before the
  /// caller's Future completes. This is the seam that closes the notification
  /// first-listen race: `addNotification` registers its demux controller in the
  /// hook so a 0x08 frame sharing the Add-response's inbound chunk finds the
  /// handle already mapped (an `await`-continuation would run one microtask too
  /// late, after that same-chunk 0x08 was already dispatched and dropped).
  PendingRequest(
    this.completer,
    this.timer,
    this.expectedCommandId, [
    this.onResponseSync,
  ]);

  /// Resolves (or errors) the caller's `request()` Future exactly once.
  ///
  /// Carries both the AMS-header `errorCode` and the response payload so the
  /// client can throw at both error levels (AMS header AND payload result);
  /// error completions carry no record.
  final Completer<({int errorCode, Uint8List payload})> completer;

  /// The per-request timeout timer; cancelled the moment the response arrives.
  final Timer timer;

  /// The ADS command-ID this request was sent with; a response whose command
  /// differs is a protocol violation and is rejected rather than delivered.
  final int expectedCommandId;

  /// Optional synchronous side-effect run on the correlated response BEFORE
  /// [completer] completes, receiving the AMS-header `errorCode` and the raw
  /// response payload. Invoked defensively (a throwing hook must never break
  /// correlation). See the constructor doc for the race it closes.
  final void Function(int errorCode, Uint8List payload)? onResponseSync;
}
