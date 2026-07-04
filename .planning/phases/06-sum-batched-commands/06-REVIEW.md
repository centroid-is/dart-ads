---
phase: 06-sum-batched-commands
reviewed: 2026-07-04T15:58:09Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - lib/src/protocol/sum_commands.dart
  - lib/src/client/ads_client.dart
  - test_harness/mock_server.cpp
findings:
  critical: 0
  warning: 2
  info: 5
  total: 7
status: clean
---

# Phase 6: Code Review Report

**Reviewed:** 2026-07-04T15:58:09Z
**Depth:** standard
**Files Reviewed:** 3 (plus supporting context: `range_check.dart`, `commands.dart`, `constants.dart`, `exceptions.dart`, sum unit/golden/integration tests, `dump_golden.cpp`)
**Status:** issues_found

## Summary

Adversarial review of the Phase 6 sum (batched) command surface: the pure codec (`sum_commands.dart`), the three `AdsClient` sum methods, and the C++ mock's SUMUP sub-handler. Priority areas from the review brief were each traced end-to-end:

- **Decoder bounds/overflow safety:** `_requireHeader` / `_requireBlock` cursor arithmetic is sound for all non-negative lengths; cursor never exceeds `data.length` (verified invariant: cursor only advances after a passed bounds check). One gap found: a negative request `length` bypasses `_requireBlock` and escapes as a raw `RangeError` (WR-02, confirmed empirically).
- **Σlen overflow (Dart side):** Dart VM ints are 64-bit, so `N*4 + Σlen` cannot wrap in the builder; a sum exceeding u32 is caught fail-fast by `checkUint(readLength, 32)` inside `buildReadWritePayload` before any bytes hit the wire. No silent truncation path exists (IN-02 notes the error-attribution quality issue).
- **C++ sum handler loop bounds:** `hdrBytes = uint64(N) * stride` overflow-free promotion verified; header reads bounded by `bodyLen` and (transitively) by the `hdrBytes <= writeLength` gate; `wcursor <= writeLength` invariant holds at every `writeLength - wcursor` subtraction (no underflow); exact-consumption checks (`hdrBytes == writeLength` for 0xF080, `wcursor == writeLength` otherwise) are present and correct; response assembly is capped against `kMaxFrameBytes` both per-item and on the final `sumData.size()`. No memory-safety defect found.
- **checkUint coverage:** All 10 u32 fields across the three builders are validated by inspection (indexGroup/indexOffset/length; indexGroup/indexOffset/data.length; indexGroup/indexOffset/readLength/writeData.length). The unit test claiming this coverage tests only 1 of 10 (IN-01).
- **0-bytes-on-failure convention consistency:** Verified byte-consistent across `decodeSumReadResponse` (failed item: cursor unchanged), the mock's 0xF080 path (failed item: nothing appended to `dataRegion`), `dump_golden.cpp`'s `sum_read_res` fixture (errs `[0,0x703,0]`, data 4+8 bytes), and the golden parity + integration tests. The Phase-9 audit flag is present in all three places.
- **Two-layer throw model:** No leak in either direction. `_command` throws on AMS `errorCode` before decode; `_throwOnResult` throws on the outer `result` before the sum decode runs; per-item words only ever land in `SumResult.errorCode`. `valueOrThrow` on a successful `SumResult<void>` was probe-tested (`null as void` succeeds — the WRITE success path cannot throw).

All 47 sum-related unit/golden tests pass; `dart analyze` is clean on both Dart files. No Critical findings. Two Warnings and five Info items follow.

## Narrative Findings (AI reviewer)

## Warnings

### WR-01: Caller-mutable `items` list is re-read after the `await` — mid-flight mutation silently corrupts decode alignment

**File:** `lib/src/client/ads_client.dart:142-208` (all three of `sumRead`, `sumWrite`, `sumReadWrite`)
**Issue:** Each sum method uses the caller-supplied `items` list twice: once to build the request (before the wire round-trip) and again — after the `await` — to drive the response decode (`decodeSumReadResponse(decoded.data, items)` at line 157; `items.length` at lines 182 and 207). If the caller mutates the list while the request is in flight (a plain `List`, nothing prevents it), the decode runs against different lengths/cardinality than what was sent. For `sumRead` this can be **silent data corruption**, not an exception: e.g. send `[len 4, len 4]`, caller swaps item 1 for a `len 2` item during the await → the decoder slices 2 bytes at cursor 4 and returns wrong bytes attributed to the wrong item, with the 2 trailing bytes silently ignored. For `sumWrite`/`sumReadWrite` a shrunken list returns fewer results than items actually sent, with no error. The library's whole contract is byte-exactness; the decode inputs should be pinned at send time.
**Fix:**
```dart
Future<List<SumResult<Uint8List>>> sumRead(
  List<SumReadRequest> items, {
  Duration? timeout,
}) async {
  if (items.isEmpty) return <SumResult<Uint8List>>[];
  final snapshot = List<SumReadRequest>.unmodifiable(items); // pin at send time
  final (inner, readLength) = buildSumReadPayload(snapshot);
  ...
  return decodeSumReadResponse(decoded.data, snapshot);
}
```
Same pattern for `sumWrite`/`sumReadWrite` (or capture `final n = items.length;` before the await and pass `n` to the decoder).

### WR-02: `_requireBlock` guard is bypassed by a negative length — raw `RangeError` escapes instead of `MalformedFrameException`

**File:** `lib/src/protocol/sum_commands.dart:368` (guard), `:285-291` (reachable via `decodeSumReadResponse`)
**Issue:** `_requireBlock` documents itself as "checked (subtraction-safe) BEFORE any slice (T-6-01)", but the check `if (len > data.length - cursor)` is false for any negative `len`, so control proceeds to `data.sublist(cursor, cursor + len)` with `end < start`. Confirmed empirically: `decodeSumReadResponse` with a `SumReadRequest(length: -4)` throws `RangeError (end): Invalid value: Not in inclusive range 4..8: 0` — outside the codec's documented exception family (`MalformedFrameException` for framing, `AdsException` for protocol). In the client path this is currently unreachable because `buildSumReadPayload` runs `checkUint(it.length, 32, ...)` first, but `decodeSumReadResponse` is a standalone pure function (used directly by tests, and by any future call site) whose only length inputs come from the caller — the guard's own contract should hold without relying on a distant precondition. `decodeSumReadWriteResponse` is not affected (its lengths come from `getUint32`, always non-negative).
**Fix:**
```dart
void _requireBlock(Uint8List data, int cursor, int len, String what, int item) {
  if (len < 0 || len > data.length - cursor) {
    throw MalformedFrameException(
      '$what item $item declares $len data bytes but only '
      '${data.length - cursor} remain',
      length: len,
      offset: cursor,
    );
  }
}
```

## Info

### IN-01: Unit test 'builders apply checkUint to every u32 field' covers 1 of 10 fields

**File:** `test/unit/protocol/sum_commands_test.dart:111-119`
**Issue:** The test name asserts full checkUint coverage but only exercises `indexGroup` on `buildSumReadPayload`. The other nine fields (including all of `buildSumWritePayload` and `buildSumReadWritePayload`) are unpinned — a future regression removing `checkUint` from, say, `readLength` in the READWRITE builder would pass this suite while silently truncating on the wire (the exact failure mode `range_check.dart` exists to prevent). The production code is currently correct by inspection; this is false coverage confidence.
**Fix:** Add one out-of-range case per builder per field class, e.g. `SumReadWriteRequest(readLength: -1, ...)`, `SumWriteRequest(indexOffset: 0x100000000, ...)`, etc.

### IN-02: Σlen > u32 surfaces as a confusingly-attributed `ArgumentError`; oversized-but-valid batches hit a mock timeout instead of a typed error

**File:** `lib/src/protocol/sum_commands.dart:175, 243`; `lib/src/client/ads_client.dart:147-153`
**Issue:** Two adjacent quality gaps in the same seam. (1) When `N*4 + Σlen` exceeds u32, the failure is correct and fail-fast but fires inside `buildReadWritePayload` as `ArgumentError('readLength', ...)` — the caller passed per-item lengths, not a `readLength`, so the attribution is indirect. (2) A batch whose computed `readLength` fits u32 but exceeds 4 MiB is sent, and the mock (by its documented T-6-02 hostile-input discipline, `mock_server.cpp:847`) drops it silently → the client waits out the full timeout (or hangs if `timeout` is null) rather than getting an actionable error.
**Fix:** Consider validating the computed `readLength` in the sum builders themselves (`checkUint(total, 32, 'sum batch readLength')`) with an item-count-aware message; optionally document the practical batch-size ceiling on the three client methods.

### IN-03: Public `SumResult` constructor permits `errorCode: 0` with `value: null` — `valueOrThrow` then throws a raw `TypeError`

**File:** `lib/src/protocol/sum_commands.dart:126-142` (exported via `lib/dart_ads.dart:66-67`)
**Issue:** `SumResult` is on the public barrel surface with an unrestricted const constructor. `const SumResult<Uint8List>(errorCode: 0)` is representable but internally inconsistent (success with no value); `valueOrThrow` then throws `_TypeError: type 'Null' is not a subtype of type 'Uint8List' in type cast` (confirmed empirically) instead of anything meaningful. Library decoders never construct this state, but consumers can.
**Fix:** Either document that `value` is required when `errorCode == 0` for non-void `T`, or make the failure intentional: `T get valueOrThrow { if (!isSuccess) throw AdsException.fromCode(errorCode); final v = value; if (v == null) throw StateError('SumResult success with no value'); return v; }`.

### IN-04: Mock per-item error sentinel with inner `indexOffset == 0` produces a self-contradictory response

**File:** `test_harness/mock_server.cpp:913-917`
**Issue:** In the SUMUP READ path, a batch item with `ig == kErrResultGroup` emits `putU32(errRegion, magic ? io : 0u)` and zero data bytes. If a future test author uses the sentinel with `io == 0` ("inject error 0"), the item's error word is 0 (success) while it contributes no data — the Dart decoder will then treat it as successful and slice the *next* item's bytes for it (or throw `MalformedFrameException` at the end): a confusing desync originating in the fixture, not the code under test. Test-harness-only, degenerate input.
**Fix:** One-line guard or comment at the sentinel site, e.g. treat `io == 0` as a hard `ok = false` (no response) or document "offset must be a non-zero ADS error code" next to `kErrResultGroup`.

### IN-05: Sum decoders silently ignore trailing bytes after the last consumed block

**File:** `lib/src/protocol/sum_commands.dart:270-339`
**Issue:** All three decoders stop consuming at the last item and ignore any surplus bytes in `data`. This is consistent with the existing `_decodeResultAndData` leniency (readLength < available is accepted), so it is a deliberate family behavior — but for SUMUP_READ specifically, where the data region's expected size is fully computable from `items` + error words, an exact-consumption check would detect mock/PLC convention divergence (the exact risk the Phase-9 parity audit flag exists for) at the decode site instead of via downstream wrong-data symptoms.
**Fix:** Optional strictness, e.g. after the loop in `decodeSumReadResponse`: `if (cursor != data.length) throw MalformedFrameException('SUMUP_READ response has ${data.length - cursor} unconsumed trailing bytes', offset: cursor);` — decide deliberately and align with the Phase 9 audit either way.

---

_Reviewed: 2026-07-04T15:58:09Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_


## Resolutions (iteration 2, orchestrator-applied)

- WR-01: fixed in `snapshot` commit — all three sum methods snapshot `items` via `List.unmodifiable` before the wire call; decoders consume the snapshot.
- WR-02: fixed in same commit — `_requireBlock` rejects negative `len` (`len < 0 ||`), preserving the MalformedFrameException contract.
- Verification: analyze --fatal-infos clean, format clean, 208 unit tests green.
- Info findings IN-01..IN-05 remain open by scope.
