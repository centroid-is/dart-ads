---
phase: 07-symbol-access-browse-typed-values
reviewed: 2026-07-04T17:02:20Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - lib/src/protocol/symbols.dart
  - lib/src/protocol/value_codec.dart
  - lib/src/client/ads_client.dart
  - lib/src/client/ads_handle.dart
  - test_harness/mock_server.cpp
findings:
  critical: 1
  warning: 3
  info: 6
  total: 10
status: issues_found
---

# Phase 7: Code Review Report

**Reviewed:** 2026-07-04T17:02:20Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed the Phase-7 symbol-access surface: `parseSymbolBlob`, the pure value
codec, the `AdsClient` handle-lifecycle/browse/typed methods, the `AdsHandle`
RAII wrapper, and the C++ mock's symbol handling. Supporting test files
(`symbols_parse_test.dart`, `value_codec_test.dart`, `symbols_client_test.dart`,
`handle_lifecycle_test.dart`) were read as context.

**What holds up under attack:**

- `parseSymbolBlob` hostile-input hardening is sound. I traced the
  no-room-for-NUL edge (entryLength == 30 + nameLength exactly): after
  `p += nameLength + 1`, `p` exceeds `entryEnd`, so `entryEnd - p` goes
  negative and the next `_requireField` throws even for a 0-length typeName —
  subtraction-safe as claimed. `entryLength` is range-checked `[30, remaining]`
  before use, `cursor` can never exceed `blob.length`, a lying `nSymbols`
  (too big) hits the early break, and a truncated header throws
  `MalformedFrameException` before any slice. No over-read path found.
- The mock's 0xF005 handle resolution is bounds-correct: READ caps `length`
  at `kMaxFrameBytes` before allocation; WRITE validates `length` in
  overflow-free subtraction form before `body + 12 + length`; the 0xF003
  NUL-strip indexes `body[16 + nameLen - 1]` only after `writeLength <=
  bodyLen - 16` has been established; unknown/released handles return 0x710
  instead of falling through to the store (T-7-04 honored).
- The 0x4025 relocation is complete for all **live** wire traffic: every test
  that reads the seed uses `0x4025` (`ads_client_test`, `ads_parity_test`,
  `router_transport_modes_test`), and the mock seeds `{0x4025, 0x123}`. The
  residue that remains is in golden fixtures/comments — see WR-03.
- Float paths are bit-exact by construction (`setFloat32`/`setFloat64`,
  explicit `Endian.little`); signed ranges are guarded by `_checkInt` before
  the silently-truncating `ByteData` setters; STRING decode stops at first NUL
  and correctly returns the whole buffer when no NUL exists; WSTRING decode
  handles odd byte counts via `~/ 2` without over-reading.

**What does not hold up:** the typed read path hands device-controlled buffers
to fixed-size decoders with no length check, breaking the phase's own
"never RangeError on hostile input" invariant (CR-01).

## Critical Issues

### CR-01: Typed reads decode device-controlled buffers without length validation — hostile/short reply escapes as RangeError

**File:** `lib/src/protocol/value_codec.dart:64,75,85,100,112,128,140,156,167` and `lib/src/client/ads_client.dart:310-397`
**Issue:** Every fixed-size decoder (`decodeBool`, `decodeByte`, `decodeSint`,
`decodeWord`, `decodeInt`, `decodeDword`, `decodeDint`, `decodeReal`,
`decodeLreal`) indexes/reads the buffer with no length guard. The buffer they
receive is **device-controlled**: `decodeReadResponse` validates only that the
declared `readLength` matches the bytes present — the device chooses
`readLength`. A device that answers `readDintByName` with `result=0,
readLength=2, 2 bytes` is internally consistent, passes both error levels, and
then `decodeDint` throws a raw `RangeError` from `ByteData.getInt32`
(`decodeBool` on an empty reply throws an index `RangeError`). This violates
the codebase's explicit exception-family contract (hostile bytes →
`MalformedFrameException`, never `RangeError` — see `symbols.dart` T-7-02 and
the threat notes in `ads_client.dart`), and the intent is provable:
`getHandleByName` (ads_client.dart:159-165) guards the *identical* short-reply
case for its own 4-byte decode, but the nine typed read methods added in this
same phase do not. Callers correctly catching the documented
`AdsException`/`MalformedFrameException` families will crash on a hostile or
buggy peer. The mock always echoes the requested length, so 295/295 green
proves nothing here.
**Fix:** Validate the returned length at the client boundary (mirroring the
`getHandleByName` guard), e.g. in `readByName`-based typed reads:
```dart
Future<int> readDintByName(String name, {Duration? timeout}) async {
  final data = await readByName(name, 4, timeout: timeout);
  if (data.length < 4) {
    throw MalformedFrameException(
      'typed read of "$name" returned ${data.length} bytes, expected 4',
      length: 4, offset: 0);
  }
  return codec.decodeDint(data);
}
```
Alternatively (and additionally, since the codec is a public-ish seam), add a
`_require(buf, n)` guard inside each fixed-size decoder that throws
`ArgumentError` — but the client-boundary check is the one that preserves the
exception-family contract for wire input.

## Warnings

### WR-01: `AdsHandle.close()` marks itself closed before the release succeeds — a failed release permanently strands the device handle

**File:** `lib/src/client/ads_handle.dart:85-90`
**Issue:** `close()` sets `_closed = true` and *then* awaits
`_client.releaseHandle(...)`. If the release fails (timeout, transient
connection error, non-zero result), the exception propagates to the caller,
but the wrapper is already irreversibly `_closed`: a retry `close()` is a
silent no-op (`if (_closed) return;`), so the device handle is leaked with no
recovery path through the wrapper — the exact leak class T-7-01 exists to
prevent. This also contrasts with the client's own `_releaseQuietly`
discipline where release failure is an accepted, handled outcome.
**Fix:** Only latch `_closed` on success, with a re-entrancy guard for
concurrent closes:
```dart
bool _closing = false;
Future<void> close({Duration? timeout}) async {
  if (_closed || _closing) return;
  if (!_valid) { _closed = true; return; }
  _closing = true;
  try {
    await _client.releaseHandle(handle, timeout: timeout);
    _closed = true;
  } finally {
    _closing = false;
  }
}
```
(Or document that a throwing `close()` leaks and callers must fall back to
`client.releaseHandle(h.handle)` — but the code should not silently absorb the
retry either way.)

### WR-02: `releaseHandle` silently truncates the handle to u32 — an out-of-range handle releases a *different* handle

**File:** `lib/src/client/ads_client.dart:193-202`
**Issue:** `ByteData.setUint32` in Dart truncates to the low 32 bits without
error. `releaseHandle(0x1_0000_0001)` therefore sends a release for handle
`1` — a valid, possibly-live *other* handle — instead of failing. This is
inconsistent with the rest of the wire layer: `readByHandle`/`writeByHandle`
route the same handle through `buildReadPayload`/`buildWritePayload`, whose
`checkUint(indexOffset, 32, ...)` throws `ArgumentError` on the same input.
So the three lifecycle methods disagree on out-of-range handles, and the one
that disagrees can destroy an unrelated resource.
**Fix:**
```dart
Future<void> releaseHandle(int handle, {Duration? timeout}) {
  final data = Uint8List(4);
  ByteData.sublistView(data)
      .setUint32(0, checkUint(handle, 32, 'handle'), Endian.little);
  ...
}
```
(`checkUint` from `range_check.dart`, as used by the payload builders.)

### WR-03: 0x4025 relocation incomplete at the fixture/tooling layer — goldens and generator still bake 0xF005 as a scratch group

**File:** `test/golden/read_req.hex:1`, `test/golden/write_req.hex:1`, `test_harness/dump_golden.cpp:251,267,277`, `test_harness/mock_server.cpp:719-721`, `test/unit/golden_parity_test.dart:113,125,242`
**Issue:** The live seed and every integration test moved to `0x4025`, but the
committed golden request fixtures still encode `group 0xF005, offset 0x123` —
which under Phase-7 semantics is a SYM_VALBYHND access with handle `0x123`
(the mock would now answer it 0x710, and a real PLC would treat it as a
handle read). `dump_golden.cpp` will *regenerate* these 0xF005 fixtures,
re-baking the collision, and `golden_parity_test.dart` pins the Dart encoders
to the same stale group. Worse, the mock's seed comment
(mock_server.cpp:719-720, "Seed one fixture matching the read_req golden key")
is now factually false — the seed is at `{0x4025, 0x123}` while the read_req
golden key is still `{0xF005, 0x123}`. Byte-parity is unaffected today (the
goldens are compared, never replayed), but the first person to replay a golden
against the mock, or to extend dump_golden, inherits a semantic trap the
relocation was supposed to eliminate.
**Fix:** Regenerate the read/write request goldens at `0x4025` via an updated
`dump_golden.cpp`, update the `golden_parity_test.dart` constants in the same
commit, and correct the mock's seed comment to reference the new key
explicitly.

## Info

### IN-01: Dead negative-value checks on unsigned wire fields

**File:** `lib/src/protocol/symbols.dart:193`, `lib/src/client/ads_client.dart:282`
**Issue:** `_requireField`'s `len < 0` (len is a `getUint16` result) and
`browseSymbols`' `size < 0` (a `getUint32` result) are unreachable — both
accessors are non-negative by construction.
**Fix:** Drop the dead halves or comment them as deliberate defense-in-depth
so future readers do not infer signed inputs are possible.

### IN-02: The SYM-04 "raw passthrough" unit test asserts nothing

**File:** `test/unit/value_codec_test.dart:134-142`
**Issue:** The test compares a freshly built `Uint8List` against an identical
literal — it exercises no library code and would pass if the entire raw path
were deleted. It manufactures apparent coverage for SYM-04.
**Fix:** Either delete it or make it real: round-trip raw bytes through
`readByHandle`/`writeByHandle` via `FakeTransport` and assert byte identity.

### IN-03: Mock 0xF005 ignores the symbol's declared size on read and write

**File:** `test_harness/mock_server.cpp:880-897,1015-1030`
**Issue:** A read-by-handle of more bytes than the symbol's `size` returns
zero-padding (real PLC: error), and a write-by-handle larger than `size`
grows the store entry unbounded up to the frame cap (real PLC: 0x705
ADSERR_DEVICE_INVALIDSIZE). Integration tests exercising size-mismatch
behavior against this mock will pass where a real device fails.
**Fix:** Clamp/validate against the matched symbol's `size` and answer 0x705
on mismatch, matching device semantics.

### IN-04: `encodeWString` accepts an odd `sizeBytes` and emits an invalid odd-length WSTRING buffer

**File:** `lib/src/protocol/value_codec.dart:214-231`
**Issue:** A caller passing an odd `sizeBytes` (e.g. a wrong symbol size) gets
an odd-length buffer written to the PLC; a valid WSTRING buffer is always
even (as `decodeWString`'s own comment states).
**Fix:** `if (sizeBytes.isOdd) throw ArgumentError.value(sizeBytes, 'sizeBytes', 'WSTRING buffer size must be even');`

### IN-05: Mock 0xF006 answers success for a malformed release payload

**File:** `test_harness/mock_server.cpp:1036-1049`
**Issue:** A SYM_RELEASEHND write with `length < 4` (no handle bytes) still
returns `result = 0` while releasing nothing. Every other malformed frame in
the mock follows the "no response" discipline; this one silently reports
success, which could mask a client-side encoding regression in a future test.
**Fix:** `break;` (no response) when `length < 4 || !getU32(...)`, matching
the established malformed-frame handling.

### IN-06: `AdsHandle` close-during-in-flight-op interleaving is unguarded and undocumented

**File:** `lib/src/client/ads_handle.dart:59-90`
**Issue:** `close()` does not wait for an in-flight `read()`/`write()`;
`_ensureUsable` was already passed, so the op proceeds against a handle whose
release is now pipelined behind it. On the ordered single connection this is
benign (the op completes first), and a lost race merely surfaces 0x710 and
sets `_valid = false` post-close — but none of this is stated, and
`_maybeInvalidate` mutating state after close is surprising.
**Fix:** Document the ordering guarantee in the `close()` doc comment (and
optionally make `_maybeInvalidate` a no-op once `_closed`).

---

_Reviewed: 2026-07-04T17:02:20Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
