# Phase 7: Symbol Access, Browse & Typed Values - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (grey-area recommendations auto-accepted per standing user directive)

<domain>
## Phase Boundary

Users access PLC variables by name, browse the symbol table, and exchange typed Dart values — the HMI's primary access pattern. Delivers: handle-by-name lifecycle (0xF003 resolve / 0xF005 read-write-by-handle / 0xF006 release with auto-release), symbol browse (0xF00C/0xF00F upload-info + 0xF00B blob with variable-length AdsSymbolEntry parsing), typed scalar conversion (BOOL, BYTE/USINT, WORD/UINT, INT, DWORD/UDINT, DINT, REAL, LREAL, STRING, WSTRING) with raw Uint8List escape hatch, handle invalidation on 1808/1809 errors, mock symbol-table support. No SYM_DT_UPLOAD type-system expansion (DTYPE-01 v2), no AdsSymbol<T> wrapper (DTYPE-02 v2).

Requirements: SYM-01, SYM-02, SYM-03, SYM-04.

</domain>

<decisions>
## Implementation Decisions

### Handle-by-Name (SYM-01)
- `AdsClient.getHandleByName(String name)` → handle (ReadWrite 0xF003, write=name bytes + NUL, read=u32 handle); `readByHandle`/`writeByHandle` (Read/Write on 0xF005 with indexOffset=handle); `releaseHandle(handle)` (Write 0xF006, u32 handle payload)
- Convenience `readByName`/`writeByName`: resolve → op → release when not using a retained handle; plus an `AdsHandle` helper object (create/read/write/release, auto-release via `close()`) mirroring AdsLib's RAII AdsHandle — session-scoped, never persisted
- Handle staleness: ADS errors 0x710 (symbol not found), 0x711 (version mismatch)/1808/1809-class errors surface as AdsException; the AdsHandle helper marks itself invalid on such errors (no silent reuse)

### Browse (SYM-02)
- `AdsClient.uploadSymbolInfo()` (Read 0xF00C or 0xF00F upload-info → counts/lengths) + `browseSymbols()` (Read 0xF00B blob → List<AdsSymbolInfo>)
- AdsSymbolEntry variable-length record parsing in protocol/ (pure): entryLength u32, iGroup, iOffs, size, dataTypeId, flags, then length-prefixed name/type/comment strings (exact layout pinned by researcher from vendored AdsDef.h / AdsDevice usage) — advance by entryLength (never by computed field sizes) for forward-compat
- `AdsSymbolInfo` value type: name, typeName, comment, indexGroup, indexOffset, size, dataTypeId, flags

### Typed Values (SYM-03/04)
- `AdsValueCodec` (or plain functions) in protocol/ (pure): encode/decode for BOOL(1), BYTE/USINT(1), SINT(1), WORD/UINT(2), INT(2), DWORD/UDINT(4), DINT(4), REAL(4 f32), LREAL(8 f64), STRING (fixed-length Latin-1, NUL-terminated/padded), WSTRING (UTF-16LE, NUL-terminated) — all little-endian
- Typed convenience on AdsClient: `readValue<T>`/`writeValue<T>` style OR type-explicit methods (readInt16/readReal...) — pick the shape most consistent with the codebase; raw Uint8List always available (SYM-04 escape hatch = existing read/readByHandle)
- No STRUCT/ARRAY decoding (needs SYM_DT_UPLOAD → v2)

### Mock Support
- Mock gains a small fixed symbol table (e.g. MAIN.counter DINT@0x4020:0, MAIN.flag BOOL, MAIN.text STRING(80), MAIN.temp LREAL): GET_SYMHANDLE_BYNAME allocates handle bound to the symbol's (group, offset); RELEASE frees; READ/WRITE_SYMVAL_BYHANDLE routes to the store; SYM_UPLOADINFO2 + SYM_UPLOAD serve a byte-accurate symbol blob built from the same table
- Unknown name → 0x710 error; released/invalid handle use → 0x710-class error; handle-count observable for leak assertions (reuse or extend the 0xE7700002 pattern)

### C++ Test Parity
- No dedicated AdsLibTest symbol scenarios exist (AdsLib exposes GetHandle via AdsDevice, exercised implicitly) — note in test header for the Phase 9 audit; our own coverage exceeds the C++ suite here

### Claude's Discretion
- File layout (protocol/symbols.dart, protocol/value_codec.dart), exact API naming, AdsHandle shape
- Golden fixtures: at least handle req/res + a 2-symbol upload blob golden

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- ReadWrite/Read/Write plumbing + payload builders; mock store + magic groups + handle-table pattern (notifications); dump_golden; AdsException table incl. 0x710/0x711; sum commands for future batch reads

### Established Patterns
- protocol/ purity; golden parity per codec; -n regex; --fatal-infos; verify ordering; two-layer error model; snapshot-before-await (Phase 6 lesson)

### Integration Points
- Phase 8 CLI browse/read/write/pull/push consume browseSymbols + by-name + typed codec + sum commands
- v2 DTYPE-01/02 build on the dataTypeId field preserved in AdsSymbolInfo

</code_context>

<specifics>
## Specific Ideas

- Browse must parse a MULTI-symbol blob with entryLength-based advancement (variable-length records — the research HIGH-complexity flag)
- Handle leak proof: N getHandle/release cycles → mock handle count returns to baseline
- STRING codec: fixed-length buffer, content NUL-terminated, decode stops at first NUL; WSTRING UTF-16LE

</specifics>

<deferred>
## Deferred Ideas

- SYM_DT_UPLOAD (0xF00E) STRUCT/ARRAY/enum decoding → v2 (DTYPE-01)
- AdsSymbol<T> bound wrapper → v2 (DTYPE-02)
- In-session symbol cache keyed on SYM_VERSION → v2+

</deferred>
