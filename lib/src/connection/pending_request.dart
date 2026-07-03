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
  PendingRequest(this.completer, this.timer, this.expectedCommandId);

  /// Resolves (or errors) the caller's `request()` Future exactly once.
  final Completer<Uint8List> completer;

  /// The per-request timeout timer; cancelled the moment the response arrives.
  final Timer timer;

  /// The ADS command-ID this request was sent with; a response whose command
  /// differs is a protocol violation and is rejected rather than delivered.
  final int expectedCommandId;
}
