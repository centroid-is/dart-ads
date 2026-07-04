---
phase: 07-symbol-access-browse-typed-values
verified: 2026-07-04T00:00:00Z
status: passed
score: 4/4 must-haves verified
overrides_applied: 0
---

# Phase 7: Symbol Access, Browse & Typed Values — Verification Report

**Phase Goal:** Users can access PLC variables by name, browse the symbol table, and exchange typed Dart values — the HMI's primary access pattern.
**Verified:** 2026-07-04
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Resolve symbol handle by name, read/write by handle, release with automatic release | VERIFIED | `AdsClient.getHandleByName` (0xF003 ReadWrite, name+NUL, 4-byte LE u32); `readByHandle`/`writeByHandle` (0xF005, indexOffset=handle); `releaseHandle` (0xF006, indexOffset=0, handle as 4-byte data payload). `AdsHandle` RAII wrapper auto-releases in `close()` and throws `StateError` on use after invalidation. Integration test `handle_lifecycle_test.dart`: 9 tests including leak proof (25 resolve/release cycles return mock count to baseline) and staleness (0x710 → invalid → StateError). |
| 2 | Browse the symbol table with parsed variable-length entries (name, type, size, iGroup, iOffset) | VERIFIED | `parseSymbolBlob` (30-byte pack(1) header, six u32 + three u16, Latin-1 strings, cursor advances by entryLength). `AdsClient.browseSymbols` issues 0xF00C then 0xF00B, nSymSize sanity-capped at 16 MiB. Mock serves 4-symbol table with one deliberately padded entry (MAIN.counter entryLength 62→64). Integration test `symbols_test.dart` asserts all 4 entries field-by-field including the padded entry. Golden fixture `sym_upload_blob.hex` pins the wire contract. |
| 3 | PLC scalar types (BOOL..LREAL, STRING, WSTRING) convert to/from Dart values | VERIFIED | `value_codec.dart`: encode/decode for BOOL(1), BYTE/USINT(1u), SINT(1i), WORD/UINT(2u), INT(2i), DWORD/UDINT(4u), DINT(4i), REAL(f32), LREAL(f64), STRING(Latin-1, NUL-padded, overflow→ArgumentError), WSTRING(UTF-16LE, 0x0000-terminated, overflow→ArgumentError). All use `ByteData` with explicit `Endian.little`. Client exposes typed `*ByName` convenience methods delegating to codec. 18/18 unit tests pass; integration typed round-trips (DINT/BOOL/STRING/LREAL) pass. |
| 4 | Raw Uint8List escape hatch | VERIFIED | `readByHandle` returns `Uint8List` directly (documented as SYM-04 in method doc). `value_codec.dart` library doc: "escape hatch is simply not calling a codec at all — the existing Read/Write paths already return and accept raw `Uint8List` bytes." Integration test `symbols_test.dart`: "raw readByHandle returns unparsed LREAL bytes (SYM-04)" passes. Note: REQUIREMENTS.md checkbox `[ ]` and traceability `Pending` for SYM-04 were not updated to reflect completion — documentation housekeeping only, not a functional gap. |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/src/protocol/symbols.dart` | AdsSymbolInfo + parseSymbolBlob (pure) | VERIFIED | 202 lines, full implementation; bounds-checked with MalformedFrameException; advances by entryLength; not barrel-exported as raw parser |
| `lib/src/protocol/value_codec.dart` | Pure LE scalar + STRING/WSTRING encode/decode | VERIFIED | 247 lines; all 9 scalar types + STRING/WSTRING; explicit Endian.little on every accessor; overflow throws ArgumentError |
| `lib/src/client/ads_handle.dart` | RAII AdsHandle (create/read/write/release/close) | VERIFIED | Full implementation; staleness invalidation on 0x710/0x711; idempotent close; StateError on reuse |
| `lib/src/client/ads_client.dart` | Handle lifecycle + browse + typed methods | VERIFIED | getHandleByName, readByHandle, writeByHandle, releaseHandle, readByName, writeByName, uploadSymbolInfo, browseSymbols, full set of *ByName typed methods |
| `lib/dart_ads.dart` | Barrel exports AdsHandle, AdsSymbolInfo, SymbolUploadInfo | VERIFIED | Lines 121, 130-131: `show AdsClient, SymbolUploadInfo`; `show AdsHandle`; `show AdsSymbolInfo` |
| `test/unit/symbols_parse_test.dart` | SYM-02 parser unit tests incl. padded + hostile | VERIFIED | ~10 tests: clean 2-symbol, padded-entry advancement, hostile blobs (entryLength 0/29/past-remaining, nameLength overrun) |
| `test/unit/value_codec_test.dart` | SYM-03/04 round-trip + overflow + raw | VERIFIED | 18 tests passing; all scalar types, STRING/WSTRING overflow, raw-passthrough |
| `test/unit/client/symbols_client_test.dart` | FakeTransport unit tests for all 5 groups | VERIFIED | Tests getHandleByName name+NUL, indexOffset=handle, handle-as-data with indexOffset=0, browse round-trip, nSymSize rejection, staleness |
| `test/unit/symbols_golden_test.dart` | Byte-for-byte parity on padded blob | VERIFIED | Loads sym_upload_blob.hex, runs parseSymbolBlob(blob, 2), asserts exact AdsSymbolInfo fields for both entries |
| `test/integration/handle_lifecycle_test.dart` | SYM-01 leak proof + auto-release + staleness | VERIFIED | 9 tests; uses kSymHandleCountGroup=0xE7700005; 25-cycle leak proof; AdsHandle.close() idempotent; 0x710 → invalid → StateError |
| `test/integration/symbols_test.dart` | SYM-02 browse + SYM-03 typed + SYM-04 raw | VERIFIED | 5 tests; all 4-symbol fields asserted; DINT/BOOL/STRING/LREAL round-trips; raw readByHandle passthrough |
| `test/golden/sym_handle_req.hex` | 0xF003 handle request fixture | VERIFIED | Present |
| `test/golden/sym_handle_res.hex` | 0xF003 handle response fixture | VERIFIED | Present |
| `test/golden/sym_uploadinfo_res.hex` | 0xF00C uploadinfo response fixture | VERIFIED | Present |
| `test/golden/sym_upload_blob.hex` | 2-symbol padded upload blob fixture | VERIFIED | Present |
| `test_harness/mock_server.cpp` | Symbol dispatch 0xF003/5/6/B/C + count group | VERIFIED | All 5 groups dispatched; kSymHandleCountGroup=0xE7700005; NUL-tolerant name lookup; 0x710 on unknown name and invalid handle; padded entry (MAIN.counter entryLength 62→64); scratch group relocated 0xF005→0x4025 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `ads_client.dart` | `symbols.dart` | `browseSymbols → parseSymbolBlob` | WIRED | Line 305: `return parseSymbolBlob(blob, info.symbolCount)` |
| `ads_client.dart` | `value_codec.dart` | typed `*ByName` methods | WIRED | `import '../protocol/value_codec.dart' as codec;` used in encodeBool/decodeBool, encodeDint/decodeDint etc. |
| `ads_client.dart` | `ads_handle.dart` | AdsHandle delegates to client | WIRED | `ads_handle.dart` imports and holds `AdsClient`; `create` calls `client.getHandleByName` |
| `symbols_golden_test.dart` | `sym_upload_blob.hex` | loadGolden + parseSymbolBlob | WIRED | Hex fixture loaded, sliced, fed to parseSymbolBlob |
| `handle_lifecycle_test.dart` | mock 0xE7700005 | Read baseline → cycles → baseline | WIRED | `const kSymHandleCountGroup = 0xE7700005` used in leak-proof assertion |
| `dart_ads.dart` | `symbols.dart`, `ads_handle.dart`, `ads_client.dart` | show clauses | WIRED | AdsSymbolInfo, AdsHandle, SymbolUploadInfo all exported |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `browseSymbols` | `blob` (Uint8List) | `read(0xF00B, nSymSize)` → mock/PLC | Yes — mock's `buildSymbolUploadBlob()` serializes live symbol table | FLOWING |
| `getHandleByName` | handle (u32) | `readWrite(0xF003)` → mock allocates `nextSymHandle++` | Yes — per-connection handle counter | FLOWING |
| `readByHandle` | bytes (Uint8List) | `read(0xF005, indexOffset=handle)` → mock value store | Yes — store seeded at {iGroup,iOffs} per symbol | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite (unit + integration, excl. slow) | `dart test -x slow` | 302/302 passed in ~2 seconds | PASS |
| Static analysis on all phase 7 files | `dart analyze --fatal-infos` on symbols.dart, value_codec.dart, ads_client.dart, ads_handle.dart, dart_ads.dart | No issues found | PASS |

### Probe Execution

No probes declared in PLAN files. Step skipped.

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| SYM-01 | 07-03, 07-04, 07-05, 07-06 | Resolve symbol handle by name, read/write by handle, release, automatic release | SATISFIED | getHandleByName/readByHandle/writeByHandle/releaseHandle/readByName/writeByName/AdsHandle; integration tests pass |
| SYM-02 | 07-01, 07-03, 07-04, 07-05, 07-06 | Browse PLC symbol table (upload-info + blob), parsing variable-length entries | SATISFIED | parseSymbolBlob + browseSymbols + golden fixtures + integration tests; padded-entry advancement proven |
| SYM-03 | 07-02, 07-05, 07-06 | BOOL..LREAL, STRING, WSTRING convert to/from Dart values | SATISFIED | value_codec.dart all 9 scalars + STRING/WSTRING; typed *ByName methods; 18 unit + integration typed round-trips |
| SYM-04 | 07-02, 07-05, 07-06 | Raw Uint8List escape hatch | SATISFIED (code); REQUIREMENTS.md checkbox not updated | readByHandle returns Uint8List; documented in value_codec.dart; integration test "raw readByHandle returns unparsed LREAL bytes (SYM-04)" passes. REQUIREMENTS.md `[ ]` checkbox and traceability `Pending` are stale — housekeeping only |

### Anti-Patterns Found

No `TBD`, `FIXME`, or `XXX` markers found in any phase-7 files. No stub return patterns (`return null`, `return []`, `return {}`) in production code. No empty handlers.

### Human Verification Required

None. All success criteria are verifiable programmatically and confirmed by the 302/302 test run.

### Gaps Summary

No gaps. All 4 phase success criteria are implemented, wired, and verified by a clean 302/302 test run and zero static-analysis issues.

**One housekeeping note (non-blocking):** `REQUIREMENTS.md` line 63 has `[ ] **SYM-04**` (unchecked) and the traceability table at line 165 shows `Pending`. The implementation is complete and tested; only the documentation checkbox and status column need updating to `[x]` / `Complete`.

---
_Verified: 2026-07-04_
_Verifier: Claude (gsd-verifier)_
