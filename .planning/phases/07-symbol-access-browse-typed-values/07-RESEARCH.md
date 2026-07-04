# Phase 7: Symbol Access, Browse & Typed Values - Research

**Researched:** 2026-07-04
**Domain:** Beckhoff ADS symbol protocol (handle lifecycle, SYM_UPLOAD blob parsing, IEC 61131 typed value codec) — Dart client + C++ mock
**Confidence:** HIGH (all wire shapes pinned byte-exact from vendored `third_party/ADS`; only the ADST_* numeric enum is CITED rather than present in the vendored headers)

## Summary

Every wire shape this phase needs is present and byte-exact in the vendored Beckhoff AdsLib. The HIGH-complexity item — the variable-length `AdsSymbolEntry` record — is fully specified by `AdsLib/standalone/AdsDef.h` (the struct, `#pragma pack(push, 1)`) and `AdsLib/SymbolAccess.cpp` (the reference parser `SymbolEntry::Parse` + the browse driver `FetchSymbolEntries`). The header is a fixed **30 bytes** (six u32 + three u16, packed 1), followed by three **NUL-terminated** strings (name, type, comment). Records are advanced by `entryLength`, never by summed field sizes — the reference does exactly this and so must the Dart parser (forward-compat with padded/extended entries).

Handle ops are equally pinned: `AdsDevice::GetHandle`/`DeleteSymbolHandle` (`AdsDevice.cpp`) and the by-handle read/write in `AdsTool/main.cpp`. One material discrepancy with the locked CONTEXT decision surfaced: **vendored AdsLib sends the symbol name WITHOUT a NUL terminator** on 0xF003 (`writeLen = symbolName.size()`), whereas CONTEXT says "name bytes + NUL". Both are accepted by real TwinCAT; the mock must tolerate a trailing NUL. See Assumptions Log A1.

Browse uses the **8-byte** `SYM_UPLOADINFO` (0xF00C) response `{nSymbols u32, nSymSize u32}`, then reads `nSymSize` bytes from `SYM_UPLOAD` (0xF00B). AdsLib does not use `UPLOADINFO2` (0xF00F) at all — recommend 0xF00C for exact parity. The typed codec is a pure little-endian scalar map; the ADST_* IDs are stored on `AdsSymbolInfo` for v2 but the codec is driven by the caller's requested type/size, not by trusting `dataTypeId`.

**Primary recommendation:** Port `SymbolEntry::Parse` line-for-line into `protocol/symbols.dart` (advance by `entryLength`, strings are `nameLength`/`typeLength`/`commentLength` bytes each followed by one NUL); use 0xF00C (8-byte) + 0xF00B; 0xF003 read=4 (u32 LE handle), 0xF005 indexOffset=handle, 0xF006 Write iOffs=0 payload=4-byte handle LE.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
**Handle-by-Name (SYM-01)**
- `AdsClient.getHandleByName(String name)` → handle (ReadWrite 0xF003, write=name bytes + NUL, read=u32 handle); `readByHandle`/`writeByHandle` (Read/Write on 0xF005 with indexOffset=handle); `releaseHandle(handle)` (Write 0xF006, u32 handle payload)
- Convenience `readByName`/`writeByName`: resolve → op → release when not using a retained handle; plus an `AdsHandle` helper object (create/read/write/release, auto-release via `close()`) mirroring AdsLib's RAII AdsHandle — session-scoped, never persisted
- Handle staleness: ADS errors 0x710 (symbol not found), 0x711 (version mismatch)/1808/1809-class errors surface as AdsException; the AdsHandle helper marks itself invalid on such errors (no silent reuse)

**Browse (SYM-02)**
- `AdsClient.uploadSymbolInfo()` (Read 0xF00C or 0xF00F upload-info → counts/lengths) + `browseSymbols()` (Read 0xF00B blob → List<AdsSymbolInfo>)
- AdsSymbolEntry variable-length record parsing in protocol/ (pure): entryLength u32, iGroup, iOffs, size, dataTypeId, flags, then length-prefixed name/type/comment strings — advance by entryLength (never by computed field sizes) for forward-compat
- `AdsSymbolInfo` value type: name, typeName, comment, indexGroup, indexOffset, size, dataTypeId, flags

**Typed Values (SYM-03/04)**
- `AdsValueCodec` (or plain functions) in protocol/ (pure): encode/decode for BOOL(1), BYTE/USINT(1), SINT(1), WORD/UINT(2), INT(2), DWORD/UDINT(4), DINT(4), REAL(4 f32), LREAL(8 f64), STRING (fixed-length Latin-1, NUL-terminated/padded), WSTRING (UTF-16LE, NUL-terminated) — all little-endian
- Typed convenience on AdsClient: `readValue<T>`/`writeValue<T>` style OR type-explicit methods; raw Uint8List always available (SYM-04 escape hatch = existing read/readByHandle)
- No STRUCT/ARRAY decoding (needs SYM_DT_UPLOAD → v2)

**Mock Support**
- Mock gains a small fixed symbol table (e.g. MAIN.counter DINT@0x4020:0, MAIN.flag BOOL, MAIN.text STRING(80), MAIN.temp LREAL): GET_SYMHANDLE_BYNAME allocates handle bound to the symbol's (group, offset); RELEASE frees; READ/WRITE_SYMVAL_BYHANDLE routes to the store; SYM_UPLOADINFO2 + SYM_UPLOAD serve a byte-accurate symbol blob built from the same table
- Unknown name → 0x710 error; released/invalid handle use → 0x710-class error; handle-count observable for leak assertions (reuse or extend the 0xE7700002 pattern)

**C++ Test Parity**
- No dedicated AdsLibTest symbol scenarios exist — note in test header for the Phase 9 audit; our own coverage exceeds the C++ suite here

### Claude's Discretion
- File layout (protocol/symbols.dart, protocol/value_codec.dart), exact API naming, AdsHandle shape
- Golden fixtures: at least handle req/res + a 2-symbol upload blob golden

### Deferred Ideas (OUT OF SCOPE)
- SYM_DT_UPLOAD (0xF00E) STRUCT/ARRAY/enum decoding → v2 (DTYPE-01)
- AdsSymbol<T> bound wrapper → v2 (DTYPE-02)
- In-session symbol cache keyed on SYM_VERSION → v2+
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SYM-01 | Handle-by-name lifecycle (resolve/read/write/release, auto-release) | 0xF003/0xF005/0xF006 shapes pinned from `AdsDevice.cpp` + `AdsTool/main.cpp` (below) |
| SYM-02 | Symbol browse (upload-info + variable-length blob parse) | `AdsSymbolEntry` byte layout + `SymbolEntry::Parse` reference ported below |
| SYM-03 | Typed scalar conversion (BOOL…WSTRING, LE) | Value codec table + STRING/WSTRING conventions below |
| SYM-04 | Raw Uint8List escape hatch | Existing `read`/`readByHandle` return raw bytes — no new work, just don't force typing |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Handle resolve/release lifecycle | AdsClient (session) | protocol/ (payload builders) | Handles are connection-scoped state; the pure layer only shapes bytes |
| SYM_UPLOAD blob → List<AdsSymbolInfo> | protocol/symbols.dart (pure) | AdsClient (issues the two reads) | Parsing is a pure byte→struct transform; testable without a socket |
| Typed value encode/decode | protocol/value_codec.dart (pure) | AdsClient (typed convenience methods) | Codec is stateless LE byte math; belongs beside commands.dart |
| Symbol table + handle allocation | mock_server.cpp (C++) | — | Server-side authority; mirrors the notification handle-table pattern |
| Error mapping (0x710/0x711) | protocol/ads_error.dart (exists) | AdsClient (throw AdsException) | Table already carries both codes |

## Standard Stack

No new external packages. This phase is pure Dart SDK + existing project code + the C++ mock.

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `dart:typed_data` | SDK | `Uint8List`/`ByteData` LE encode/decode | Already the project's wire primitive [VERIFIED: commands.dart uses `ByteData.sublistView` + `Endian.little`] |
| `dart:convert` | SDK | `latin1` codec for STRING | STRING is single-byte codepage; `latin1` is 1:1 byte↔char [ASSUMED — see A2] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Existing `commands.dart` builders | in-repo | `buildReadPayload`/`buildWritePayload`/`buildReadWritePayload` | Reuse verbatim for 0xF003/0xF005/0xF006/0xF00B/0xF00C [VERIFIED: lib/src/protocol/commands.dart:157-214] |
| Existing `ads_error.dart` table | in-repo | 0x710/0x711 already mapped | Throw path for staleness [VERIFIED: ads_error.dart:91-93] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 0xF00C (8-byte UPLOADINFO) | 0xF00F (UPLOADINFO2) | UPLOADINFO2 returns a larger struct with datatype/extra counts; **AdsLib never uses it** — 0xF00C is the parity path and sufficient (we don't do SYM_DT_UPLOAD). Use 0xF00C. |
| WSTRING via manual u16 loop | `dart:typed_data` `Uint16List` view | Manual loop is clearer for NUL-termination stop; either works |

**Installation:** none. (No `## Package Legitimacy Audit` — this phase installs no external packages.)

## AdsSymbolEntry — Byte-Exact Layout (HIGH-complexity item)

**Source:** `third_party/ADS/AdsLib/standalone/AdsDef.h:459-469` under `#pragma pack(push, 1)` (line 282) / `pack(pop)` (line 479). [VERIFIED: vendored AdsDef.h]

Header is a fixed **30 bytes**, all little-endian:

| Offset | Field | Type | Bytes | Notes |
|--------|-------|------|-------|-------|
| 0 | `entryLength` | u32 | 4 | length of the COMPLETE entry (header + 3 strings + any padding) — advance cursor by this |
| 4 | `iGroup` | u32 | 4 | indexGroup of symbol |
| 8 | `iOffs` | u32 | 4 | indexOffset of symbol |
| 12 | `size` | u32 | 4 | size in bytes (0 = bit) |
| 16 | `dataType` | u32 | 4 | ADST_* id → maps to `AdsSymbolInfo.dataTypeId` |
| 20 | `flags` | **u32** | 4 | ADSSYMBOLFLAG_* — **4 bytes, NOT u16** (CONTEXT focus-question guessed u16?/u32 → it is u32) |
| 24 | `nameLength` | u16 | 2 | NUL terminator NOT counted |
| 26 | `typeLength` | u16 | 2 | NUL terminator NOT counted |
| 28 | `commentLength` | u16 | 2 | NUL terminator NOT counted |
| **30** | — | — | — | end of header |

Then, immediately after the 30-byte header:
```
name    : nameLength    bytes, then 1 NUL byte (0x00)
typeName: typeLength    bytes, then 1 NUL byte (0x00)
comment : commentLength bytes, then 1 NUL byte (0x00)
[optional padding up to entryLength]
```

**Reference parser** `SymbolEntry::Parse` (`SymbolAccess.cpp:17-76`) — the exact advancement to port:
```
lengthLimit = entryLength - sizeof(header)   // = entryLength - 30
data += 30
name    = read nameLength bytes;    data += nameLength + 1     // +1 skips NUL
typeName= read typeLength bytes;    data += typeLength + 1
comment = read commentLength bytes  // (comment's trailing NUL/padding absorbed by entryLength)
```

**Browse driver** `FetchSymbolEntries` (`SymbolAccess.cpp:104-147`) — the outer loop:
```
read 0xF00C (8 bytes) -> {nSymbols u32, nSymSize u32}
read 0xF00B (nSymSize bytes) -> blob
cursor = 0; repeat nSymbols times:
    entry = Parse(blob + cursor, remaining)
    cursor += entry.entryLength        // <-- ADVANCE BY entryLength, never summed sizes
```

**Dart parser contract:**
- Validate `remaining >= 30` before reading a header; validate `entryLength <= remaining` and `entryLength >= 30`.
- Strings decode as Latin-1 (single-byte). Read exactly `nameLength`/`typeLength`/`commentLength` bytes (do NOT scan for NUL — the length fields are authoritative; the NUL is just a separator you skip).
- Advance the cursor by `entryLength`. Stop after `nSymbols` records OR when the cursor reaches the blob end.
- Field name note: struct calls it `dataType`; expose it as `AdsSymbolInfo.dataTypeId` per CONTEXT.

## Handle Ops — Exact Wire Shapes

**Source:** `AdsDevice.cpp:44-86` + `AdsTool/main.cpp:745-838`. [VERIFIED: vendored]

### Resolve — 0xF003 SYM_HNDBYNAME (ReadWrite / 0x09)
`AdsDevice.cpp:69-86`:
```
ReadWriteReqEx2(indexGroup=0xF003, indexOffset=0,
                readLength=4  (-> &handle),
                writeLength=symbolName.size(),  writeData=symbolName.c_str())
handle = letoh(handle)   // little-endian u32
```
- Read side returns **exactly 4 bytes** = u32 handle, little-endian.
- Write side = the name bytes. **Vendored AdsLib sends `symbolName.size()` bytes — i.e. NO NUL terminator** (`.size()` excludes the NUL; `.c_str()` is just the buffer pointer). CONTEXT's locked decision says "name bytes + NUL". Real TwinCAT accepts both; pyads sends WITH a trailing NUL. **Recommendation:** client sends name + NUL per the locked decision (real-PLC-safe, matches pyads); the **mock must strip a single trailing NUL before table lookup** so both encodings resolve. See Assumptions Log A1.

### Read by handle — 0xF005 SYM_VALBYHND (Read / 0x02)
`AdsTool/main.cpp:786-788`:
```
ReadReqEx2(indexGroup=0xF005, indexOffset=*handle, length=size, -> buffer)
```
- **indexOffset = the handle value** (not 0). length = the symbol's byte size.

### Write by handle — 0xF005 SYM_VALBYHND (Write / 0x03)
`AdsTool/main.cpp:750 & 835`:
```
WriteReqEx(indexGroup=0xF005, indexOffset=*handle, length=data.len, data)
```

### Release — 0xF006 SYM_RELEASEHND (Write / 0x03)
`AdsDevice.cpp:45-48`:
```
WriteReqEx(indexGroup=0xF006, indexOffset=0, length=4, data=&handle)
```
- **indexOffset = 0**; the 4-byte handle is the DATA payload (u32 little-endian). (Focus-question confirmed: handle-as-data, iOffs=0.)

## Typed Value Codec (SYM-03)

All scalars little-endian. Encode/decode is stateless. Drive selection by the **caller's requested type** (typed methods) or the symbol's declared `size`, not by blindly trusting `dataTypeId`.

| IEC type | Aliases | Bytes | Dart repr | ByteData op |
|----------|---------|-------|-----------|-------------|
| BOOL | — | 1 | `bool` | byte != 0 (encode: 1/0) |
| BYTE / USINT | — | 1 | `int` 0..255 | getUint8 |
| SINT | — | 1 | `int` -128..127 | getInt8 |
| WORD / UINT | — | 2 | `int` | getUint16 LE |
| INT | — | 2 | `int` | getInt16 LE |
| DWORD / UDINT | — | 4 | `int` | getUint32 LE |
| DINT | — | 4 | `int` | getInt32 LE |
| REAL | — | 4 | `double` | getFloat32 LE |
| LREAL | — | 8 | `double` | getFloat64 LE |
| STRING | STRING(n) | n (fixed) | `String` | Latin-1, NUL-terminated/padded (below) |
| WSTRING | WSTRING(n) | 2*(n+?) | `String` | UTF-16LE, NUL-terminated (below) |

### ADST_* data type IDs
Not present in the vendored headers (AdsLib doesn't need them). Canonical Beckhoff `AdsDataType` enum [CITED: Beckhoff TwinCAT / pyads `ads.py` constants — cross-verified across pyads + Beckhoff InfoSys]:

| Name | Value | IEC |
|------|-------|-----|
| ADST_VOID | 0 | — |
| ADST_INT16 | 2 | INT |
| ADST_INT32 | 3 | DINT |
| ADST_REAL32 | 4 | REAL |
| ADST_REAL64 | 5 | LREAL |
| ADST_INT8 | 16 | SINT |
| ADST_UINT8 | 17 | BYTE/USINT |
| ADST_UINT16 | 18 | WORD/UINT |
| ADST_UINT32 | 19 | DWORD/UDINT |
| ADST_INT64 | 20 | LINT |
| ADST_UINT64 | 21 | ULINT/LWORD |
| ADST_STRING | 30 | STRING |
| ADST_WSTRING | 31 | WSTRING |
| ADST_REAL80 | 32 | — |
| ADST_BIT | 33 | BOOL |
| ADST_BIGTYPE | 65 | STRUCT/ARRAY (v2) |

Store `dataTypeId` on `AdsSymbolInfo` (v2 DTYPE-01 consumes it); do not gate this phase's codec on it. Mark inline as `[CITED]` — these are stable but not confirmed in the vendored tree.

### STRING / WSTRING conventions
- **STRING:** fixed-length buffer = the declared size (TwinCAT `STRING(80)` allocates 81 bytes on the PLC; the symbol `size` field reports the on-wire byte count — use `size` verbatim). **Encode:** write bytes, pad remainder with NUL (0x00). **Decode:** stop at first NUL, ignore the rest. Single-byte codepage → `latin1` (1:1). Note: TwinCAT STRING is technically the controller's codepage (often Windows-1252); for ASCII/Latin-1 content the two agree. Flag non-ASCII as a known edge (A2).
- **WSTRING:** UTF-16 **little-endian** code units. **Decode:** read u16 code units, stop at the first `0x0000` unit. **Encode:** UTF-16LE units + a `0x0000` terminator, padded to buffer. Use `String.codeUnits`/`Uint16List` view for surrogate-safe handling; for BMP-only test fixtures a simple loop suffices.

## Mock Symbol Table Design

Mirror the existing per-connection **notification handle-table** pattern (`mock_server.cpp:605-615`: `store[{group,offset}]`, `nextHandle=1`, per-connection reset). [VERIFIED: mock_server.cpp]

**Recommended structure:**
- A fixed compile-time symbol list, each: `{name, iGroup, iOffs, size, dataTypeId, typeName, comment}`. Suggested set from CONTEXT: `MAIN.counter` DINT@0x4020:0x0 (size 4, ADST_INT32), `MAIN.flag` BOOL (size 1, ADST_BIT), `MAIN.text` STRING(80) (size 81, ADST_STRING), `MAIN.temp` LREAL (size 8, ADST_REAL64).
- **Value store** already keyed by `{group, offset}` — back the symbols with entries at their `{iGroup, iOffs}` (e.g. `store[{0x4020,0}]`). READ/WRITE by handle resolves the handle → `{group,offset}` → same store.
- **0xF003 (ReadWrite):** parse write payload as name; **strip one trailing NUL if present**; look up symbol; on miss return **0x710** (ADSERR_DEVICE_SYMBOLNOTFOUND). On hit allocate `symHandle = nextSymHandle++`, record `symHandle -> {group,offset}` in a per-connection map, return 4-byte handle LE.
- **0xF005 read/write:** indexOffset = handle → look up map; unknown/released handle → **0x710-class** error (use 0x710 for parity with "not active/known"; 0x1809 `ADSERR_DEVICE_NOTFOUND`/`SYMBOLNOTACTIVE` also valid — pick one and assert on it). Route to the value store.
- **0xF006 write:** indexOffset=0, data=4-byte handle → erase from the map.
- **0xF00C (UPLOADINFO Read):** return 8 bytes `{nSymbols, nSymSize}` where `nSymSize` = total bytes of the blob built below.
- **0xF00B (UPLOAD Read):** build the blob by serializing each symbol as a byte-exact `AdsSymbolEntry` (30-byte header, then name+NUL, type+NUL, comment+NUL; set `entryLength` = 30 + sum + 3). Optionally 4-byte-align `entryLength` to exercise the parser's "advance by entryLength, skip padding" path — a deliberate padded golden proves the parser doesn't rely on summed sizes.
- **Handle-count observability:** extend the existing `kNotifyCountGroup` (0xE7700002) pattern (`mock_server.cpp:143,721`) with a symbol-handle-count magic group so a Read returns the live sym-handle count as u32 → the leak-proof assertion (baseline 0 → N cycles → back to 0).

## Architecture Patterns

### Data flow
```
browseSymbols():
  AdsClient --Read 0xF00C--> mock --{nSymbols,nSymSize}-->
  AdsClient --Read 0xF00B(nSymSize)--> mock --blob-->
  parseSymbolBlob(blob, nSymbols)  [pure] --> List<AdsSymbolInfo>

getHandleByName(name):
  AdsClient --ReadWrite 0xF003 (name[+NUL])--> mock --> u32 handle
  readByHandle(h,size): --Read 0xF005 iOffs=h len=size--> raw bytes -> codec
  writeByHandle(h,bytes): codec -> --Write 0xF005 iOffs=h-->
  releaseHandle(h): --Write 0xF006 iOffs=0 data=h-->
```

### Recommended Project Structure
```
lib/src/protocol/
├── symbols.dart       # AdsSymbolInfo + parseSymbolBlob (pure)
├── value_codec.dart   # encode/decode scalar + STRING/WSTRING (pure)
lib/src/                # AdsClient gains handle + browse + typed methods
test_harness/mock_server.cpp   # symbol table + dispatch for 0xF003/5/6/B/C
```

### Anti-Patterns to Avoid
- **Advancing the blob cursor by summed field sizes** instead of `entryLength` — breaks on padded/extended entries. Always use `entryLength`.
- **Scanning strings for NUL to determine length** — the length fields are authoritative; the NUL is a skip-1 separator.
- **Trusting `dataTypeId` to pick the codec** — drive by caller's requested type/declared size; `dataTypeId` is stored for v2 only.
- **Persisting handles across reconnects** — session-scoped only (CONTEXT).
- **Re-reading a handle after a 0x710/0x711** — AdsHandle helper marks itself invalid.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| LE scalar pack/unpack | manual bit shifts | `ByteData` get/setInt*/Float* + `Endian.little` | Matches existing commands.dart; float bit-exactness |
| Request framing | new payload builder | existing `buildRead/Write/ReadWritePayload` | Already tested + golden-covered |
| Error text/lookup | new map | `ads_error.dart` (0x710/0x711 present) | Single source of truth |
| Symbol blob parse | ad-hoc | port `SymbolEntry::Parse` semantics exactly | Reference is the ground truth for parity |

**Key insight:** The entire wire contract already exists in vendored C++ — porting `SymbolEntry::Parse` / `FetchSymbolEntries` / `GetHandle` semantics 1:1 is safer than re-deriving from docs.

## Runtime State Inventory

Not a rename/refactor phase — **N/A**. (Greenfield feature addition; no stored state migration.)

## Common Pitfalls

### Pitfall 1: Off-by-one on the string NUL separators
**What goes wrong:** Reading `nameLength+1` as the name (includes NUL) or forgetting to skip the NUL, corrupting the type/comment offsets.
**How to avoid:** Read exactly `nameLength` bytes, then advance cursor by `nameLength + 1`. Mirror the reference exactly.
**Warning signs:** typeName starts with a stray char or is shifted by one.

### Pitfall 2: `flags` sized as u16
**What goes wrong:** Treating `flags` as 2 bytes shifts `nameLength`/`typeLength`/`commentLength` by 2 → total header desync.
**How to avoid:** `flags` is **u32** (AdsDef.h:465). Header is exactly 30 bytes.

### Pitfall 3: Name-terminator mismatch client↔mock
**What goes wrong:** Client sends `name+NUL`, mock looks up `name\0` in a table keyed on `name` → false 0x710.
**How to avoid:** Mock strips one trailing NUL before lookup. Add a test asserting both `name` and `name\0` resolve. (A1)

### Pitfall 4: Handle used as indexOffset vs. as data
**What goes wrong:** Sending release with handle as indexOffset (like 0xF005) instead of as the 4-byte data payload with iOffs=0.
**How to avoid:** 0xF006 → iOffs=0, data=handle. 0xF005 → iOffs=handle. They differ.

### Pitfall 5: STRING size off-by-one
**What goes wrong:** Using declared `STRING(80)` char count (80) instead of the symbol `size` (81 incl. NUL slot).
**How to avoid:** Use the symbol entry's `size` field verbatim for the buffer length.

## Code Examples

### Parse one symbol entry (Dart, ported from SymbolAccess.cpp)
```dart
// Source: third_party/ADS/AdsLib/SymbolAccess.cpp:17-76 (SymbolEntry::Parse)
AdsSymbolInfo _parseEntry(Uint8List blob, int off) {
  final bd = ByteData.sublistView(blob, off);
  final entryLength   = bd.getUint32(0, Endian.little);
  final iGroup        = bd.getUint32(4, Endian.little);
  final iOffs         = bd.getUint32(8, Endian.little);
  final size          = bd.getUint32(12, Endian.little);
  final dataTypeId    = bd.getUint32(16, Endian.little);
  final flags         = bd.getUint32(20, Endian.little);
  final nameLength    = bd.getUint16(24, Endian.little);
  final typeLength    = bd.getUint16(26, Endian.little);
  final commentLength = bd.getUint16(28, Endian.little);
  var p = off + 30;
  final name    = latin1.decode(blob.sublist(p, p + nameLength));    p += nameLength + 1;
  final type    = latin1.decode(blob.sublist(p, p + typeLength));    p += typeLength + 1;
  final comment = latin1.decode(blob.sublist(p, p + commentLength));
  return AdsSymbolInfo(name, type, comment, iGroup, iOffs, size, dataTypeId, flags,
                       entryLength /* caller advances cursor by this */);
}
```

### STRING decode
```dart
String decodeString(Uint8List buf) {           // fixed-length, NUL-terminated
  final nul = buf.indexOf(0);
  return latin1.decode(nul < 0 ? buf : buf.sublist(0, nul));
}
```

### WSTRING decode
```dart
String decodeWString(Uint8List buf) {           // UTF-16LE, NUL(0x0000)-terminated
  final u = Uint16List.sublistView(buf);
  final units = <int>[];
  for (final c in u) { if (c == 0) break; units.add(c); }
  return String.fromCharCodes(units);
}
```

## State of the Art

| Old Approach | Current Approach | When | Impact |
|--------------|------------------|------|--------|
| SYM_UPLOADINFO 0xF00C (8-byte) | SYM_UPLOADINFO2 0xF00F (extended) | TC3 | AdsLib still uses 0xF00C; 0xF00F only needed for SYM_DT_UPLOAD (v2) — stay on 0xF00C |

**Deprecated/outdated:** none relevant to this scope.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Client sends name + trailing NUL on 0xF003 (per CONTEXT) though vendored AdsLib sends NO NUL; mock tolerates both | Handle Ops | Low — mock strips NUL; both real PLC + AdsLib accept. But if mock is NOT made tolerant, false 0x710. |
| A2 | STRING decodes as Latin-1; TwinCAT STRING is actually the controller codepage (often Windows-1252) | Codec | Low for ASCII test data; non-ASCII bytes 0x80-0x9F could differ. Fixtures use ASCII. |
| A3 | ADST_* numeric IDs (INT16=2, REAL64=5, BIT=33, etc.) per pyads/Beckhoff — not in vendored headers | Codec table | Low — stored only, not used to drive this phase's codec; v2 consumes it |
| A4 | Invalid/released handle → 0x710 in mock (0x1809 SYMBOLNOTACTIVE also defensible) | Mock | None functional — pick one and assert consistently |

## Open Questions (RESOLVED)

1. **Invalid-handle error code: 0x710 vs 0x1809?** — **RESOLVED (planning, 2026-07-04):** mock returns **0x710** for BOTH unknown-name and invalid/released-handle (A4 frozen); AdsHandle invalidates on 0x710/0x711. Locked into Plans 03/05/06.
   - Known: real TwinCAT returns a device error on unknown handle; 0x710 (SYMBOLNOTFOUND) and 0x1809 (SYMBOLNOTACTIVE, in ads_error.dart:136) are both plausible.
   - Recommendation: mock returns 0x710 for both unknown-name and invalid-handle (simplest, both in table); document choice; AdsHandle invalidates on either.

## Environment Availability

Skipped — pure Dart + in-repo C++ mock, no new external tools/services. (Existing toolchain: Dart SDK, CMake/C++ mock already used in Phases 1-6.)

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` via `dart_test.yaml` (existing) [VERIFIED: /Users/jonb/Projects/dart-ads/dart_test.yaml] |
| Config file | `dart_test.yaml` |
| Quick run | `dart test -n '<name-regex>'` |
| Full suite | `dart test` |

### Phase Requirements → Test Map
| Req | Behavior | Type | Command | File Exists? |
|-----|----------|------|---------|-------------|
| SYM-02 | Multi-symbol blob parse (2+ entries, advance by entryLength incl. padded entry) | unit | `dart test test/unit/symbols_parse_test.dart` | ❌ Wave 0 |
| SYM-02 | Golden: 2-symbol upload blob byte-parity | unit | `dart test -n 'symbol upload golden'` | ❌ Wave 0 |
| SYM-01 | Handle req/res golden (0xF003 + 4-byte handle) | unit | `dart test -n 'handle golden'` | ❌ Wave 0 |
| SYM-01 | Handle leak proof: N resolve/release → count back to baseline | integration | `dart test test/integration/handle_lifecycle_test.dart` | ❌ Wave 0 |
| SYM-01 | Auto-release via AdsHandle.close(); staleness marks invalid on 0x710/0x711 | integration | same file | ❌ Wave 0 |
| SYM-03 | Typed round-trips BOOL/BYTE/INT/UINT/DINT/UDINT/REAL/LREAL/STRING/WSTRING | unit | `dart test test/unit/value_codec_test.dart` | ❌ Wave 0 |
| SYM-04 | Raw Uint8List escape hatch returns unparsed bytes | unit | value_codec/read test | ❌ Wave 0 |

### Sampling Rate
- Per task commit: `dart test -n '<relevant>'`
- Per wave merge: `dart test`
- Phase gate: full suite green + golden parity before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `test/unit/symbols_parse_test.dart` — SYM-02 blob parse (incl. deliberately padded entry)
- [ ] `test/unit/value_codec_test.dart` — SYM-03/04 round-trips + STRING/WSTRING edge cases
- [ ] `test/integration/handle_lifecycle_test.dart` — SYM-01 leak proof + staleness
- [ ] Golden fixtures via `dump_golden.cpp`: handle req/res + 2-symbol upload blob (extend existing golden pipeline)
- [ ] Mock symbol table + 0xF003/5/6/B/C dispatch + sym-handle-count magic group

## Security Domain

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V5 Input Validation | yes | Bounds-check every blob read: `remaining >= 30`, `entryLength in [30, remaining]`, string lengths within `entryLength` — mirror `SymbolAccess.cpp` guards (throw ADSERR_DEVICE_INVALIDDATA equiv). Untrusted PLC/mock bytes must never over-read. |
| V6 Cryptography | no | — |
| V2/V3/V4 | no | Transport/auth handled by ADS/AMS layer (prior phases) |

### Known Threat Patterns
| Pattern | STRIDE | Mitigation |
|---------|--------|------------|
| Malformed symbol blob (entryLength < 30, or > remaining) → buffer over-read | Tampering/DoS | Explicit bounds checks before every read; throw on violation (parser is pure, no memory unsafety in Dart, but must not throw RangeError uncaught — wrap as protocol error) |
| Oversized `nSymSize` causing huge allocation | DoS | Sanity-cap the upload read length; the read length comes from 0xF00C which the mock controls; for real PLCs a reasonable ceiling is defensive |

## Sources

### Primary (HIGH confidence)
- `third_party/ADS/AdsLib/standalone/AdsDef.h` — AdsSymbolEntry struct (459-469), pack(1) (282/479), ADSIGRP_SYM_* (47-66), ADSSYMBOLFLAG_* (442-448)
- `third_party/ADS/AdsLib/SymbolAccess.cpp` — SymbolEntry::Parse (17-76), FetchSymbolEntries + AdsSymbolUploadInfo{nSymbols,nSymSize} (104-147)
- `third_party/ADS/AdsLib/AdsDevice.cpp` — GetHandle 0xF003 (69-86), DeleteSymbolHandle 0xF006 (45-48)
- `third_party/ADS/AdsTool/main.cpp` — VALBYHND read/write 0xF005 (750, 786-788, 835)
- `lib/src/protocol/commands.dart` — payload builders (156-214); `lib/src/protocol/ads_error.dart` — 0x710/0x711 (91-93)
- `test_harness/mock_server.cpp` — handle-table + magic-group pattern (143, 605-615, 683-721)

### Secondary (MEDIUM confidence)
- pyads / Beckhoff InfoSys — ADST_* numeric enum (not in vendored tree)

## Metadata

**Confidence breakdown:**
- AdsSymbolEntry layout / browse: HIGH — byte-exact from vendored struct + reference parser
- Handle ops: HIGH — vendored AdsDevice/AdsTool (one CONTEXT discrepancy flagged, A1)
- Typed codec: HIGH for LE scalars; MEDIUM for ADST_* IDs (CITED, A3) and STRING codepage (A2)
- Mock design: HIGH — reuses proven notification handle-table pattern

**Research date:** 2026-07-04
**Valid until:** stable (vendored source is pinned) — ~90 days
