---
phase: 03-core-ads-commands-error-mapping
reviewed: 2026-07-04T10:58:27Z
depth: standard
files_reviewed: 12
files_reviewed_list:
  - lib/src/client/ads_client.dart
  - lib/src/client/ads_types.dart
  - lib/src/protocol/ads_error.dart
  - lib/src/protocol/constants.dart
  - lib/src/connection/ams_connection.dart
  - lib/src/connection/pending_request.dart
  - lib/dart_ads.dart
  - test/unit/ads_client_test.dart
  - test/unit/ads_error_test.dart
  - test/integration/ads_client_test.dart
  - test/integration/ads_parity_test.dart
  - test_harness/mock_server.cpp
findings:
  critical: 0
  warning: 3
  info: 6
  total: 9
status: issues_found
---

# Phase 3: Code Review Report

**Reviewed:** 2026-07-04T10:58:27Z
**Depth:** standard
**Files Reviewed:** 12 (6 in-scope source files plus 6 required-reading context files)
**Status:** issues_found

## Summary

Adversarial review of the Phase-3 AdsClient command veneer, the ADS error table, the `request()` record seam, and the C++ mock's data-store/stateful additions. The core error-mapping contract was traced end-to-end and **holds**:

- **Both-levels ordering verified.** `AdsClient._command` (ads_client.dart:190-193) checks the AMS-header `errorCode` before any decoder runs, so an empty error payload cannot trip the decoders' length guards; the payload `result` is checked post-decode via `_throwOnResult`. The unit test at test/unit/ads_client_test.dart:264-287 genuinely proves the ordering (empty payload + non-zero errorCode would throw `MalformedFrameException` if decode ran first).
- **Unknown codes are tolerant.** `adsErrorName`/`adsErrorText`/`AdsException.fromCode` never throw; `AdsState.fromCode` falls back to `unknown(-1)` with the raw value preserved in `AdsStateInfo.rawAdsState`.
- **Error-table transcription verified against the vendored header.** Every code in `_adsErrorTable` was cross-checked against `third_party/ADS/AdsLib/standalone/AdsDef.h` (ERR_GLOBAL 0x0000, ERR_ROUTER 0x0500, ERR_ADSERRS 0x0700, client offsets 0x40-0x49 then 0x50-0x55). All 60+ codes are numerically correct, including the intentional 0x0749→0x0750 gap. (Texts are normalized, not verbatim — see IN-02.)
- **The `request()` record seam is fully migrated.** Every caller of `AmsConnection.request` was located (grep across lib/ and test/): the only production caller is `AdsClient._command`, which checks `errorCode`. All test callers (`ams_connection_test.dart`, `ams_connection_live_test.dart`, `socket_transport_test.dart`, `ads_parity_test.dart`) destructure the record correctly; the unit suite even asserts `errorCode == 0` on success. No caller silently drops the record fields.
- **Payload building verified.** Read (12 B), Write (12+n), ReadWrite (16+n, readLength@8 / writeLength@12 matching upstream `AoEReadWriteReqHeader`), WriteControl (adsState u16@0, deviceState u16@2, length u32@4) all match the reference layouts and are range-checked through `checkUint`.
- **Mock data-store lifetime is correct.** `store`, `curAdsState`, `curDeviceState` are declared inside the per-accept block (mock_server.cpp:424-429), so state is connection-scoped and freed on disconnect; the seed fixture and RUN(5) seeding match what the tests assert. `getU16`/`getU32` bounds checks are correct on 64-bit builds. The selftest path is untouched: `wrapResponse`'s `amsError` parameter defaults to 0 and the errorCode patch is skipped, leaving the golden byte-identical. `kAmsErrorCodeOffset = 24` was independently re-derived from the AMS header layout (16 addr + 2 cmd + 2 flags + 4 len) — correct.

No blockers found. Three warnings (a latent 32-bit overread in the mock's length checks that contradicts the file's own safety claim, a vacuous parity-test assertion, and drift-prone wire-layout duplication) and six info items follow.

## Warnings

### WR-01: WRITE / READ_WRITE bounds checks overflow on 32-bit `size_t`, contradicting the file's own safety claim

**File:** `test_harness/mock_server.cpp:559` and `test_harness/mock_server.cpp:581`
**Issue:** The kMaxFrameBytes comment (lines 113-115) claims the cap "keeps `sizeof(AmsTcpHeader) + length` well inside size_t on 32-bit builds" — but that only covers `tcp.length()`. The per-command payload length fields are NOT capped before being used in an addition:

```cpp
12u + static_cast<size_t>(length) > bodyLen        // WRITE, line 559
16u + static_cast<size_t>(writeLength) > bodyLen   // READ_WRITE, line 581
```

On a build where `size_t` is 32 bits, a hostile `length` of e.g. `0xFFFFFFF4` wraps the sum to a small value, the `> bodyLen` rejection is bypassed, and the subsequent `std::vector<uint8_t>(body + 12, body + 12 + length)` overreads the heap by up to ~4 GiB. `READ` is protected by its explicit `length > kMaxFrameBytes` check (line 532); WRITE and READ_WRITE have no equivalent. Current CI (64-bit macOS/Linux) is unaffected, hence Warning rather than Blocker — but the code's own comment asserts 32-bit safety it does not have.
**Fix:** Rewrite the checks in subtraction form, which cannot overflow:
```cpp
// WRITE:
if (... || bodyLen < 12 || static_cast<size_t>(length) > bodyLen - 12) { break; }
// READ_WRITE:
if (... || bodyLen < 16 || static_cast<size_t>(writeLength) > bodyLen - 16) { break; }
```
(or add `length > kMaxFrameBytes` / `writeLength > kMaxFrameBytes` guards before the additions, matching READ).

### WR-02: Parity port `testAdsReadReqEx2` write-then-read loop is vacuous — its assertions cannot fail even if Write is broken

**File:** `test/integration/ads_parity_test.dart:110-130` (root cause: `test_harness/mock_server.cpp:535-541`)
**Issue:** The test writes `[0, 0, 0, 0]` to `(0x4020, 0)` and then asserts ten reads return zeros. But the mock's READ handler zero-fills for a missing key:

```cpp
std::vector<uint8_t> data(length, 0);
const auto it = store.find({ group, offset });
if (it != store.end()) { /* copy */ }
```

A read of a key that was never written returns exactly the same `[0,0,0,0]` with `result 0`. So this port asserts nothing about the Write path or the store — if `client.write` silently sent garbage or the mock dropped the WRITE entirely, every iteration would still pass. The C++ original (main.cpp L333) also writes 0, but against a stateful PLC where prior state could differ; against this zero-filling mock the adaptation loses all discriminating power. (The other loops — `testAdsWriteReqEx`, `testAdsReadWriteReqEx2`, `testAdsReadReqEx2LargeBuffer` — use non-zero flipping/patterned values and are genuinely discriminating.)
**Fix:** Keep the C++-mirroring zero write, but add one non-zero sentinel round before the loop, e.g.:
```dart
final sentinel = Uint8List.fromList(const [0x5A, 0xA5, 0x5A, 0xA5]);
await client.write(indexGroup: group, indexOffset: offset, data: sentinel, ...);
expect(await client.read(...), equals(sentinel)); // proves the store is live
await client.write(indexGroup: group, indexOffset: offset, data: zero, ...);
// existing zero-read loop now proves the OVERWRITE, not the zero-fill default
```
Alternatively, make the mock answer a READ of a missing key with `ADSERR_DEVICE_SRVNOTSUPP` instead of zero-fill (closer to real PLC behavior, and it would also make the invalid-group case injectable without the magic group).

### WR-03: ADS payload wire layout duplicated between `AdsClient` methods and the `commands.dart` encoders — two sources of truth that can drift

**File:** `lib/src/client/ads_client.dart:73-77, 92-97, 114-121, 154-159` (duplicating `lib/src/protocol/commands.dart:174-178, 197-202, 237-242, 263-270`)
**Issue:** Each `AdsClient` method re-implements, byte for byte, the same payload construction that already exists in the Phase-1 request encoders (e.g. `AdsClient.read` lines 73-77 is literally identical to the body of `encodeReadRequest` lines 174-178, minus the frame wrap). The encoders build full frames so they cannot be reused directly, which is exactly why the offset/length knowledge now lives in two places: a future layout fix (or a new field) applied to one copy and not the other produces a silent wire divergence. The client copies are covered only indirectly (via the C++ mock round-trips), not by the golden byte fixtures that pin the encoder copies.
**Fix:** Extract package-private ADS-payload builders in `commands.dart` and consume them from both sides:
```dart
Uint8List buildReadPayload(int indexGroup, int indexOffset, int length) { ... }
// encodeReadRequest(...) => _frame(payload: buildReadPayload(...))
// AdsClient.read(...)    => _command(AdsCommandId.read, buildReadPayload(...), timeout)
```

## Info

### IN-01: mock_server.cpp file-header documentation is stale after the Phase-3 additions

**File:** `test_harness/mock_server.cpp:13-16, 48-50`
**Issue:** The header still says "Command table (intentionally minimal for Phase 1): ReadDeviceInfo (0x01)" and "Single-connection, single-request-per-accept is sufficient for the Phase-1 build", but the file now implements six commands, a stateful data store, and the two magic error groups. Misleading for the Phase-9 parity audit.
**Fix:** Update the command-table block to list all six commands + the magic groups.

### IN-02: Error table is documented as "transcribed VERBATIM" but several texts are normalized relative to AdsDef.h

**File:** `lib/src/protocol/ads_error.dart:6-7` (entries at lines 200, 201, 79, 88, 192)
**Issue:** The header comment claims verbatim transcription, but e.g. `ADSERR_CLIENT_PORTNOTOPEN`/`ADSERR_CLIENT_NOAMSADDR` carry `ads dll` in AdsDef.h (lines 268-269) vs `'ads port not opened'`/`'no ams address'` here; `SYNCTIMEOUT` drops the upstream firewall URL; `INVALIDCONTEXT`'s "InWindows" and `SYNTAX`'s "comand" typo were silently fixed. The codes are all correct and the normalized texts are better — but the "VERBATIM" claim is false and could trip a mechanical Phase-9 verbatim audit.
**Fix:** Change the doc to "transcribed (with minor text normalization) from AdsDef.h" or annotate the normalized entries.

### IN-03: `writeControl(adsState: AdsState.unknown)` surfaces as a cryptic ArgumentError

**File:** `lib/src/client/ads_client.dart:156`
**Issue:** `AdsState.unknown.code` is `-1`, so `checkUint(adsState.code, 16, 'adsState')` throws `ArgumentError: ... must fit in u16 (0..65535): -1` — technically fail-fast, but the message gives no hint that `AdsState.unknown` is not sendable.
**Fix:** Guard explicitly: `if (adsState == AdsState.unknown) throw ArgumentError.value(adsState, 'adsState', 'AdsState.unknown is a decode-only sentinel and cannot be sent');`

### IN-04: Magic error fixture edge cases are unhandled/undocumented (offset 0; non-Read command shapes)

**File:** `test_harness/mock_server.cpp:505-517`
**Issue:** (a) A request to `kErrAmsGroup` with `indexOffset == 0` yields `amsError = 0`, i.e. a normal success response — the fixture silently injects *no* error, and a mis-written test asserting `throwsA` would fail confusingly. (b) The magic branch always answers with the Read-shaped payload (`result u32 + readLength u32`) while echoing the request's `cmdId`; this happens to work for Write/WriteControl only because the Dart `_require` guard is a minimum-length check that tolerates 4 trailing bytes. Both behaviors are load-bearing but undocumented.
**Fix:** Document "offset must be non-zero" at the fixture comment block (lines 95-107), or have the mock treat offset 0 to a magic group as malformed (no response).

### IN-05: Mock per-connection store has no aggregate memory cap

**File:** `test_harness/mock_server.cpp:424, 562-563, 585-586`
**Issue:** Each stored value is capped at ~4 MiB by the frame cap, but the number of distinct `(group, offset)` keys per connection is unbounded — a client looping writes to distinct keys grows `store` without limit for the connection's lifetime. Loopback-only test harness, connection-scoped lifetime, so risk is low.
**Fix:** Optional: cap `store.size()` (e.g. 4096 entries) and answer overflow with `ADSERR_DEVICE_NOMEMORY`.

### IN-06: Read lengths within ~40 bytes of the 4 MiB cap poison the connection instead of failing cleanly

**File:** `test_harness/mock_server.cpp:532` interacting with `lib/src/protocol/frame_assembler.dart:57,112`
**Issue:** The mock accepts READ `length` up to exactly `kMaxFrameBytes` (4 MiB) and responds with an AMS/TCP `length` of `32 + 8 + length`. The Dart `FrameAssembler` rejects any AMS/TCP length above 4 MiB, so a read with `length` in `(4 MiB − 40, 4 MiB]` gets a response the client's assembler treats as malformed — tearing down the whole connection (`_failClose`) rather than surfacing a per-request error. Symmetrically, an inbound WRITE whose frame exceeds the mock's cap is silently dropped and the client just times out. Boundary-only; no current test crosses it.
**Fix:** Cap the mock's accepted READ `length` (and READ_WRITE `readLength`) at `kMaxFrameBytes - 64` so every response it emits is guaranteed to fit the client's assembler cap.

---

_Reviewed: 2026-07-04T10:58:27Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
