---
phase: 07-symbol-access-browse-typed-values
plan: 05
subsystem: client
tags: [symbols, handles, browse, typed-values, ads-client]
requirements_completed: [SYM-01, SYM-02, SYM-03, SYM-04]
requires:
  - "lib/src/protocol/symbols.dart (parseSymbolBlob, AdsSymbolInfo)"
  - "lib/src/protocol/value_codec.dart (scalar + STRING/WSTRING codecs)"
  - "lib/src/protocol/commands.dart (build*Payload + decode*Response)"
  - "lib/src/protocol/constants.dart (AdsIndexGroup 0xF003/F005/F006/F00B/F00C)"
provides:
  - "AdsClient handle lifecycle: getHandleByName / readByHandle / writeByHandle / releaseHandle / readByName / writeByName"
  - "AdsClient.browseSymbols + uploadSymbolInfo"
  - "AdsClient typed convenience *ByName methods over value_codec"
  - "AdsHandle RAII helper (create/read/write/close, staleness invalidation)"
  - "Barrel exports: AdsHandle, AdsSymbolInfo, SymbolUploadInfo"
affects:
  - "lib/src/client/ads_client.dart"
  - "lib/dart_ads.dart"
tech-stack:
  added: []
  patterns:
    - "Thin async client wrappers over pure Wave-1 builders/codecs (mirrors sum* methods)"
    - "try/finally handle release (no leak on op failure)"
    - "RAII handle wrapper with staleness invalidation on 0x710/0x711"
    - "Device-controlled length sanity-capped before allocation (T-7-02b)"
key-files:
  created:
    - "lib/src/client/ads_handle.dart"
    - "test/unit/client/symbols_client_test.dart"
  modified:
    - "lib/src/client/ads_client.dart"
    - "lib/dart_ads.dart"
decisions:
  - "Typed API shape: type-explicit *ByName methods (readDintByName, writeRealByName, ...) covering the full scalar map + STRING/WSTRING, rather than a single readValue with a type token — most consistent with the existing explicit-method surface."
  - "STRING/WSTRING typed methods take the symbol's declared buffer size explicitly (STRING(80) == 81 bytes)."
  - "nSymSize sanity ceiling set to 16 MiB — dwarfs any realistic symbol table, caps hostile lengths."
  - "AdsHandle.close() on an already-invalidated handle skips the wire release (the device handle is already gone) but still marks itself closed."
metrics:
  duration: 12min
  completed: 2026-07-04
  tasks: 3
  files: 4
---

# Phase 07 Plan 05: Symbol Access Client Surface Summary

Handle-by-name lifecycle + RAII `AdsHandle`, symbol browse, and typed convenience methods added to `AdsClient` as thin wrappers over the pure Wave-1 symbol parser and value codec, with new public types exported from the barrel and a full FakeTransport unit suite.

## What Was Built

**Task 1 — Handle lifecycle + AdsHandle (SYM-01)**
- `getHandleByName(name)` — ReadWrite 0xF003 with the name encoded Latin-1 + a trailing NUL (decision A1), readLength 4, decoding the little-endian u32 handle.
- `readByHandle(handle, size)` / `writeByHandle(handle, data)` — Read/Write 0xF005 with `indexOffset == handle`.
- `releaseHandle(handle)` — Write 0xF006 with `indexOffset == 0` and the 4-byte handle as the DATA payload (per vendored AdsLib, not the reverse).
- `readByName` / `writeByName` — resolve → op → release in a `try/finally` (best-effort quiet release) so no handle leaks on op failure (T-7-01).
- `lib/src/client/ads_handle.dart`: `AdsHandle` RAII helper. `create` resolves; `read`/`write` delegate to the client and invalidate the handle on a `0x0710`/`0x0711` device error before rethrowing; `close()` releases once (idempotent); a later op on an invalidated/closed handle throws `StateError` (no silent reuse, T-7-05).

**Task 2 — Browse + typed convenience (SYM-02/03/04)**
- `uploadSymbolInfo()` — Read 0xF00C → `SymbolUploadInfo` record `{symbolCount, symbolSize}`.
- `browseSymbols()` — uploadSymbolInfo then Read 0xF00B of `nSymSize` bytes → `parseSymbolBlob` → ordered `List<AdsSymbolInfo>`. `nSymSize` is sanity-capped at 16 MiB before allocating (T-7-02b); an empty table short-circuits to `const []`.
- Typed `*ByName` convenience methods delegating to `value_codec`: BOOL, BYTE, SINT, WORD, INT, DWORD, DINT, REAL, LREAL, plus STRING/WSTRING (size-parameterised). The raw `Uint8List` read/write paths remain unchanged (SYM-04).

**Task 3 — Barrel + tests**
- Barrel exports (`show`): `AdsHandle`, `AdsSymbolInfo`, `SymbolUploadInfo`. `parseSymbolBlob` and the codec functions stay package-private, following the existing show-clause discipline.
- `test/unit/client/symbols_client_test.dart`: 11 FakeTransport tests asserting name+NUL on 0xF003, indexOffset==handle on 0xF005, handle-as-data with indexOffset==0 on 0xF006, browse round-trip into ordered `AdsSymbolInfo`, the nSymSize rejection, typed read/write encode/decode, and AdsHandle close/idempotency/staleness.

## Deviations from Plan

None — plan executed as written. No auto-fixes required; no authentication gates encountered.

## Threat Model Coverage

- **T-7-01 (handle leak):** `readByName`/`writeByName` release in `try/finally`; `AdsHandle.close()` idempotent. Covered by tests.
- **T-7-05 (stale-handle reuse):** `AdsHandle` invalidates on 0x710/0x711; reuse throws `StateError`. Covered by test.
- **T-7-02b (nSymSize DoS):** `browseSymbols` sanity-caps `nSymSize` at 16 MiB before allocating. Covered by test.

## Verification

- `dart analyze --fatal-infos lib/src/client/ads_client.dart lib/src/client/ads_handle.dart lib/dart_ads.dart` → No issues found.
- `dart test test/unit/client/symbols_client_test.dart` → 11/11 passed.
- Full unit suite (`dart test -t unit`) → 249 passed (no regressions).
- `dart format` → clean.

## TDD Gate Compliance

RED → GREEN gates satisfied: `test(07-05)` commit (ed4569a) added the failing suite before any implementation; `feat(07-05)` commits (ad51b7d, 50a2258, d890238) turned it green. No REFACTOR commit needed.

## Self-Check: PASSED
