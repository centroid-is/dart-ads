/// The [AdsHandle] (SYM-01): a session-scoped, RAII-style wrapper around a
/// resolved ADS symbol handle.
///
/// A raw handle (from [AdsClient.getHandleByName]) is a bare `int` the caller
/// must remember to release. [AdsHandle] owns that lifecycle: [create] resolves
/// it, [read] / [write] delegate to the client, and [close] releases it exactly
/// once (idempotent).
///
/// ## Staleness (T-7-05)
/// A device symbol table can be reloaded underneath a live handle. If an
/// operation fails with `0x0710` (ADSERR_DEVICE_SYMBOLNOTFOUND) or `0x0711`
/// (ADSERR_DEVICE_SYMBOLVERSIONINVALID) the handle is marked invalid; any later
/// [read] / [write] throws [StateError] rather than silently reusing a handle
/// that may now point at a different symbol. Callers must resolve a fresh
/// [AdsHandle] after invalidation.
///
/// ## Not persistable
/// A handle is only meaningful for the connection/session that resolved it.
/// Never serialize or reuse an [AdsHandle] across sessions.
library;

import 'dart:typed_data';

import '../protocol/ads_error.dart';
import 'ads_client.dart';

/// A session-scoped, auto-releasing wrapper around a resolved ADS symbol handle.
class AdsHandle {
  AdsHandle._(this._client, this.name, this.handle);

  /// Resolves [name] on [client] and returns a live [AdsHandle].
  static Future<AdsHandle> create(
    AdsClient client,
    String name, {
    Duration? timeout,
  }) async {
    final handle = await client.getHandleByName(name, timeout: timeout);
    return AdsHandle._(client, name, handle);
  }

  final AdsClient _client;

  /// The fully-qualified symbol name this handle was resolved from.
  final String name;

  /// The raw u32 device handle.
  final int handle;

  var _valid = true;
  var _closed = false;

  /// Whether this handle is still usable — resolved, not closed, and not
  /// invalidated by a stale-handle error.
  bool get isValid => _valid && !_closed;

  /// Reads [size] bytes for this symbol. Throws [StateError] if the handle is
  /// closed or was invalidated; a stale-handle device error (`0x710`/`0x711`)
  /// invalidates the handle before rethrowing.
  Future<Uint8List> read(int size, {Duration? timeout}) async {
    _ensureUsable();
    try {
      return await _client.readByHandle(handle, size, timeout: timeout);
    } on AdsException catch (e) {
      _maybeInvalidate(e);
      rethrow;
    }
  }

  /// Writes [data] for this symbol. Throws [StateError] if the handle is closed
  /// or was invalidated; a stale-handle device error invalidates the handle
  /// before rethrowing.
  Future<void> write(Uint8List data, {Duration? timeout}) async {
    _ensureUsable();
    try {
      await _client.writeByHandle(handle, data, timeout: timeout);
    } on AdsException catch (e) {
      _maybeInvalidate(e);
      rethrow;
    }
  }

  /// Releases the handle exactly once. Idempotent — a second [close] is a no-op.
  /// An already-invalidated handle is not released on the wire (the device
  /// handle is already gone), it is simply marked closed.
  Future<void> close({Duration? timeout}) async {
    if (_closed) return;
    _closed = true;
    if (!_valid) return;
    await _client.releaseHandle(handle, timeout: timeout);
  }

  void _ensureUsable() {
    if (_closed) {
      throw StateError('AdsHandle for "$name" is closed');
    }
    if (!_valid) {
      throw StateError(
        'AdsHandle for "$name" was invalidated by a stale-handle error '
        '(0x710/0x711); resolve a fresh handle before reusing it',
      );
    }
  }

  void _maybeInvalidate(AdsException e) {
    if (e.code == 0x0710 || e.code == 0x0711) {
      _valid = false;
    }
  }
}
