# Phase 6: Sum (Batched) Commands - Research

**Researched:** 2026-07-04
**Domain:** ADS SUMUP batched protocol (0xF080/0xF081/0xF082) wire layouts, mock dispatch, Dart codec shapes
**Confidence:** HIGH (wire layouts pinned from the vendored Beckhoff `AdsDef.h`; all other domains are established codebase patterns)

## Summary

The single genuinely-open question — the byte-exact wire layout of the three sum variants — is
**resolved from primary source**. The vendored `third_party/ADS/AdsLib/standalone/AdsDef.h`
carries Beckhoff's authoritative doc-comments for each SUMUP index group (lines 68-115). These
comments pin request/response packing and the `IOffs = list size` convention. The vendored tree
defines the constants but never *uses* them (grep for `SUMUP`/`F080`/`F081`/`F082` returns only
`AdsDef.h`), so the header comments — not adstool call sites — are the authority. They are
consistent with pyads/ads-client behaviour (training knowledge, MEDIUM) but we do not need that
cross-check because the primary source is unambiguous.

**Critical ambiguity RESOLVED:** For SUMUP_READ (0xF080) the response is
**`N × u32 error codes` (err-only region) followed by concatenated data at the REQUESTED
lengths** — NOT interleaved `err+len`. Proof: `AdsDef.h:70-72` — "`R: if IOffs != 0 then {list
of results} and {list of data}`". Per-item data length is already known from each item's request
`Length`, so no per-item length appears in the read response. Only SUMUP_READWRITE (0xF082)
carries per-item returned lengths, because its read lengths are variable — `AdsDef.h:86`:
"`R: {list of results, RLength} followed by {list of data}`".

**Primary recommendation:** Implement three pure builders/decoders in `protocol/sum_commands.dart`
following the existing `buildReadWritePayload` single-source-of-truth pattern, add a sum sub-branch
inside the mock's existing `READ_WRITE` case keyed on the outer `indexGroup`, and emit one
multi-item golden per group from `dump_golden.cpp`. The SUM-04 alignment test is the load-bearing
verification.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Sum request packing / response decoding | `protocol/` (pure) | — | Wire layout must live in one pure place, golden-pinned; no I/O |
| Per-item result assembly (`SumResult`) | `protocol/` decoder | `client/` | Decoder produces per-item err+value; client maps to public type |
| Outer ReadWrite transport + AMS/result throws | `client/` (`AdsClient`) | `connection/` | Reuses `_command` (AMS throw) + `_throwOnResult` (outer result throw) |
| Batch semantics (empty-batch short-circuit, no-throw partial) | `client/` | — | Public-API policy, not wire concern |
| Per-item store loop + partial-failure fixture | mock (`test_harness/`) | — | Test double replays store semantics per item |

## Standard Stack

No external packages. This phase is pure Dart (`dart:typed_data`) plus the existing C++ test
harness. **Package Legitimacy Audit: N/A** (no dependencies installed).

### Core (existing, reused)
| Component | Purpose | Why Standard |
|-----------|---------|--------------|
| `buildReadWritePayload` (`commands.dart:206`) | Wraps the sum write-buffer as a ReadWrite (0x09) payload | The three sum groups are ADS ReadWrite calls; sum builders produce the inner write-buffer, this wraps it |
| `_command` / `_throwOnResult` (`ads_client.dart:280,295`) | AMS-error throw site + outer ADS-result throw site | The two-layer throw model the CONTEXT.md decisions require (outer throws, inner-per-item does not) |
| `decodeReadWriteResponse` result/readLength framing | Outer envelope validation | Sum decoders slice the *inner* buffer after outer validation |
| mock `store` + magic error groups (`mock_server.cpp:604,124`) | Per-item read/write-back + injectable per-item errors | Reuse per item for the partial-failure fixture |
| `dump_golden.cpp writeHex` (`:120`) | Byte-authoritative fixtures | Emit one multi-item golden per sum group |

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SUM-01 | SUMUP_READ (0xF080) batched read | Layout pinned §Wire Layouts A; decoder = err-region + requested-length data |
| SUM-02 | SUMUP_WRITE (0xF081) batched write | Layout pinned §Wire Layouts B; response = N × u32 results only |
| SUM-03 | SUMUP_READWRITE (0xF082) batched read-write | Layout pinned §Wire Layouts C; response uses RETURNED per-item lengths |
| SUM-04 | Partial failure surfaces per-item, never throws batch | Two-layer model §Specifics; mock per-item magic-error fixture; alignment test §Validation |
</phase_requirements>

## Wire Layouts (byte-exact, little-endian) — PINNED from `AdsDef.h`

All three are ADS ReadWrite (0x09) to the SUMUP index group. **`indexOffset` (IOffs) = the item
count N** for all three (`AdsDef.h` "IOffs list size"). Fields are u32 LE unless noted. `N` = number
of items. Below, the "inner write-buffer" is the `writeData` argument to `buildReadWritePayload`; the
"inner read-buffer" is `ReadWriteResponse.data` after the outer decode.

### A. SUMUP_READ — 0xF080  [VERIFIED: AdsDef.h:68-74]

Outer ReadWrite call:
- `indexGroup = 0xF080`, `indexOffset = N`
- `writeData` (inner write-buffer) = **N × 12 bytes**, per item: `indexGroup u32, indexOffset u32, length u32`
- `readLength` = **`N*4 + Σ length_i`**  (N result words + sum of requested data lengths)

Response (inner read-buffer, `ReadWriteResponse.data`):
- **`N × u32` error codes** (item order), THEN
- **concatenated data blocks**, block *i* is exactly `length_i` bytes (the requested length), in item order.
- Total = `N*4 + Σ length_i` (matches requested `readLength`).
- Decoder slices data using the **requested** `length_i` from the request items — the response
  carries no per-item length. (Header: "`R: if IOffs != 0 then {list of results} and {list of data}`";
  if IOffs == 0 the response is data-only with no result region — we always send IOffs = N, so we
  always get the result region.)

### B. SUMUP_WRITE — 0xF081  [VERIFIED: AdsDef.h:76-81]

Outer ReadWrite call:
- `indexGroup = 0xF081`, `indexOffset = N`
- `writeData` = **N × 12B headers** (`indexGroup u32, indexOffset u32, length u32`) **followed by**
  concatenated write payloads (`Σ length_i` bytes, item order). Total write = `N*12 + Σ length_i`.
- `readLength` = **`N*4`**  (one result word per item — nothing else comes back)

Response:
- **`N × u32` error codes** only. Total = `N*4`.

### C. SUMUP_READWRITE — 0xF082  [VERIFIED: AdsDef.h:83-88]

Outer ReadWrite call:
- `indexGroup = 0xF082`, `indexOffset = N`
- `writeData` = **N × 16B headers** (`indexGroup u32, indexOffset u32, readLength u32, writeLength
  u32`) **followed by** concatenated write payloads (`Σ writeLength_i` bytes, item order).
  Total write = `N*16 + Σ writeLength_i`.
- `readLength` = **`N*8 + Σ readLength_i`**  (per item: 4-byte result + 4-byte length header, plus
  the requested read data)

Response (inner read-buffer):
- **`N × (result u32, returnedLength u32)`** headers (item order), THEN
- **concatenated data blocks**, block *i* is `returnedLength_i` bytes (the RETURNED length, which may
  be ≤ the requested `readLength_i`), in item order.
- Decoder MUST slice using the **returned** length from the response header, NOT the requested
  length. This is the one variant where request and response lengths can differ.

### Layout summary table

| Variant | Group | writeData per item | Extra write | readLength formula | Response region 1 | Response region 2 |
|---------|-------|--------------------|-------------|--------------------|--------------------|--------------------|
| READ | 0xF080 | 12B (ig,io,len) | — | `N*4 + Σlen` | N × err u32 | data @ **requested** len |
| WRITE | 0xF081 | 12B (ig,io,len) | + Σ write data | `N*4` | N × err u32 | — |
| READWRITE | 0xF082 | 16B (ig,io,rLen,wLen) | + Σ write data | `N*8 + ΣrLen` | N × (err u32, retLen u32) | data @ **returned** retLen |

## Architecture Patterns

### System Architecture Diagram

```
List<SumReadRequest>              List<SumResult<Uint8List>>
        │                                   ▲
        ▼                                   │
  AdsClient.sumRead()  ── empty? ──► return [] (no wire call)
        │                                   │
        ▼ buildSumReadPayload(items)        │ decodeSumReadResponse(data, items)
        │  (inner write-buffer, N×12B)      │  (N err words → then requested-len slices)
        ▼                                   │
  buildReadWritePayload(ig=0xF080,          │  ReadWriteResponse.data (inner buffer)
     io=N, readLength=N*4+Σlen, writeData)  │  ▲
        │                                   │  │ _throwOnResult(outer result)  ← throws
        ▼                                   │  │ _command → AMS errorCode       ← throws
  connection.request(0x09, payload) ──────► mock READ_WRITE case
                                              │ group ∈ {F080,F081,F082}? → sum sub-handler
                                              │   loop N items over `store`, per-item magic-error
                                              ▼   assemble response per pinned layout
```

Outer layer (AMS errorCode, outer ADS result) → **throws** `AdsException`.
Inner layer (per-item error words) → **never throws**; populates `SumResult.errorCode`.

### Recommended Project Structure
```
lib/src/protocol/sum_commands.dart   # pure builders + decoders + request/result value types
lib/src/client/ads_client.dart       # + sumRead / sumWrite / sumReadWrite methods
test/golden/sum_read_req.hex … sum_readwrite_res.hex   # 6 fixtures (req+res × 3)
```

### Pattern 1: Builder returns inner write-buffer; client wraps with buildReadWritePayload
**What:** `buildSumReadPayload(items) -> Uint8List` produces ONLY the N×12B inner buffer. The client
calls `buildReadWritePayload(indexGroup: 0xF080, indexOffset: N, readLength: N*4+Σlen, writeData:
inner)`. Keeps the ReadWrite envelope in its existing single source of truth.
**When to use:** All three variants.

### Pattern 2: Decoder takes the request items to know per-item lengths (READ only)
**What:** `decodeSumReadResponse(Uint8List data, List<SumReadRequest> items)` needs the requested
lengths to slice the data region (response has no length headers for 0xF080). READWRITE's decoder
does NOT need the items — it reads returned lengths from the response.
**When to use:** SUMUP_READ decode requires the request; keep the signature explicit.

### Anti-Patterns to Avoid
- **Using requested length to slice a READWRITE response:** use the RETURNED length word. Requested
  is an upper bound only.
- **Interleaving err+len for READ (0xF080):** wrong — that is READWRITE's shape. READ is err-region
  then data at requested lengths.
- **Throwing on a non-zero per-item error word:** SUM-04 forbids it. Only outer AMS/result throws.
- **Sending a wire frame for an empty batch:** short-circuit to `[]`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| ReadWrite envelope + framing | New frame packer | `buildReadWritePayload` | Golden-pinned; off-by-38 pitfall already solved |
| Outer error throwing | New throw logic | `_command` + `_throwOnResult` | Two-layer model already correct |
| Bounds-safe slicing | Manual index math | Mirror `_decodeResultAndData` overrun check | T-1-03 pattern: validate declared length ≤ available before slice |
| Per-item mock errors | New sentinel scheme | Existing `kErrResultGroup` magic group | Deterministic partial-failure already wired |

**Key insight:** Every layout ambiguity is already answered by `AdsDef.h`; the risk is re-deriving
it wrong, not missing a library.

## Mock Dispatch Design

**Insertion point:** Inside the existing `case AoEHeader::READ_WRITE:` block
(`mock_server.cpp:837`), immediately after the four `getU32` reads of `group/offset/readLength/
writeLength` and their bounds checks (after line 851), **before** the generic write-then-read at
line 853. Branch: `if (group == 0xF080u || group == 0xF081u || group == 0xF082u) { …sum handler…;
break; }`.

**Why here, not in the magic intercept:** The magic intercept (`:686-703`) reads the OUTER body's
first two u32 (`body[0]=group`, `body[4]=offset`). For a sum request those are `0xF080…/N` — never a
magic sentinel — so `isMagic` is false and dispatch reaches `READ_WRITE` normally. The sum handler
lives at the ReadWrite level and re-applies the per-item error trick itself.

**Per-item processing (reuse store + magic groups):**
1. Read `N = offset` (the outer indexOffset carries the item count — mock trusts it, or derives from
   writeLength for READ: `N = writeLength/12`). Recommend: use outer `offset` as N and validate it
   against the write-buffer size; `break` (no response) on mismatch — mirrors existing hostile-input
   discipline.
2. Loop `i` in `0..N`:
   - Parse item header from the write-buffer at the correct stride (12B for READ/WRITE, 16B for
     READWRITE).
   - **Per-item error injection:** if the item's inner `indexGroup == kErrResultGroup`
     (`0xE7700000`), that item's result word = its inner `indexOffset` and it contributes ZERO data
     bytes (READ/READWRITE) — exactly the whole-frame magic trick, applied per item. (Recommend
     supporting only the payload-level `kErrResultGroup` per item; `kErrAmsGroup` is a whole-frame
     concept and does not map to a single item.)
   - Otherwise result = 0 and the item hits `store`: READ copies min(len, stored) padded to len;
     WRITE stores `body`-slice write-back; READWRITE stores write payload then reads back.
3. Assemble the response buffer per the pinned layout for that group, wrap with `wrapResponse(f,
   READ_WRITE, …)`, `haveRes = true`.

**Alignment guarantee (SUM-04 litmus):** A failed item still occupies its result-word slot
(READ/WRITE) or its `(result, len=0)` header slot (READWRITE) but contributes 0 data bytes, so all
*other* items' data lands at the correct offset. This is exactly the fixture the SUM-04 test asserts.

## Runtime State Inventory

Not applicable — greenfield feature addition, no rename/refactor/migration. No stored data, live
service config, OS-registered state, secrets, or build artifacts are altered by adding sum commands.
(New golden `.hex` files are the only new build artifacts; they are generated by `dump_golden`, not
stale state.)

## Common Pitfalls

### Pitfall 1: Mid-batch offset drift (THE SUM-04 bug class)
**What goes wrong:** A failed item is skipped in the data region, so subsequent items' data is read
from the wrong offset — every item after the failure is corrupted.
**Why it happens:** Treating the per-item error region and data region as if a failure removes the
item entirely.
**How to avoid:** For READ, data offsets derive from *requested* lengths regardless of per-item
error (a failed item still consumed its `length_i` slot? — NO: on real PLCs a failed READ item
returns 0 data bytes). Safer: the decoder advances the data cursor by `length_i` for successful
items and by `0` for failed items — mirror whatever the mock emits, and pin BOTH with a golden where
item k fails. For READWRITE, always advance by the RETURNED length header (failed = 0). The golden
fixture is the arbiter.
**Warning signs:** Test passes for all-success batches but item k+1 data is garbage when item k fails.

### Pitfall 2: READ response sliced with response-supplied length (there is none)
**What goes wrong:** Decoder looks for a length word before each READ data block; there isn't one.
**How to avoid:** Pass the request items into the READ decoder; slice by requested `length_i`.

### Pitfall 3: readLength formula off by the header region
**What goes wrong:** Outer `readLength` too small → mock/PLC truncates, decoder overruns.
**How to avoid:** READ `N*4+Σlen`; WRITE `N*4`; READWRITE `N*8+ΣrLen`. Unit-test the formula.

### Pitfall 4: Empty batch emits a wire frame
**How to avoid:** Short-circuit `if (items.isEmpty) return [];` in each client method (documented).

## Code Examples

Builder skeleton (pure), consistent with `commands.dart` `checkUint` discipline:
```dart
// Source: derived from lib/src/protocol/commands.dart:206 (buildReadWritePayload)
Uint8List buildSumReadPayload(List<SumReadRequest> items) {
  final out = Uint8List(items.length * 12);
  final bd = ByteData.sublistView(out);
  var o = 0;
  for (final it in items) {
    bd.setUint32(o, checkUint(it.indexGroup, 32, 'indexGroup'), Endian.little);
    bd.setUint32(o + 4, checkUint(it.indexOffset, 32, 'indexOffset'), Endian.little);
    bd.setUint32(o + 8, checkUint(it.length, 32, 'length'), Endian.little);
    o += 12;
  }
  return out; // client wraps: buildReadWritePayload(ig:0xF080, io:N, readLength:N*4+Σlen, writeData:out)
}
```

READWRITE response decode (uses RETURNED lengths):
```dart
// N × (result u32, retLen u32) headers, then data at retLen_i. Validate before slicing (T-1-03).
List<SumResult<Uint8List>> decodeSumReadWriteResponse(Uint8List data, int n) {
  final bd = ByteData.sublistView(data);
  final results = <SumResult<Uint8List>>[];
  final lens = <int>[];
  for (var i = 0; i < n; i++) {
    final err = bd.getUint32(i * 8, Endian.little);
    final len = bd.getUint32(i * 8 + 4, Endian.little);
    results.add(SumResult(errorCode: err, _len: len)); // sketch
    lens.add(len);
  }
  var cursor = n * 8;
  for (var i = 0; i < n; i++) {
    if (cursor + lens[i] > data.length) throw MalformedFrameException(/* … */);
    // slice data[cursor .. cursor+lens[i]] into results[i]; failed items have len 0
    cursor += lens[i];
  }
  return results;
}
```

## Recommended Dart Shapes (Claude's discretion — brief)

Consistent with the `sealed class AdsResponse` style (`commands.dart:38`) and `ads_types.dart`
plain-class style:

```dart
// Request value types — simple immutable classes (match ads_types.dart convention).
final class SumReadRequest      { final int indexGroup, indexOffset, length; }
final class SumWriteRequest     { final int indexGroup, indexOffset; final Uint8List data; }
final class SumReadWriteRequest { final int indexGroup, indexOffset, readLength; final Uint8List writeData; }

// Result — generic class (records can't carry a type param cleanly + need methods).
final class SumResult<T> {
  final int errorCode;      // 0 == success
  final T? value;           // Uint8List for read/readWrite; null for write (T = void → value unused)
  bool get isSuccess => errorCode == 0;
  T get valueOrThrow => isSuccess ? value as T : throw AdsException.fromCode(errorCode);
}
```

Recommend a **class** (not a record) for `SumResult` — it needs the `isSuccess`/`valueOrThrow`
methods and a type parameter, both of which classes express more cleanly than records here, and it
mirrors the existing `sealed`/`final class` response idiom.

Client methods mirror `readWrite` (`ads_client.dart:108`): build inner buffer → `buildReadWrite
Payload` → `_command(AdsCommandId.readWrite, …)` → `_throwOnResult(outerResult)` → decode inner →
return `List<SumResult<…>>`. Empty-batch guard first.

## State of the Art

| Old Approach | Current Approach | When | Impact |
|--------------|------------------|------|--------|
| N separate Read/Write round-trips | One SUMUP ReadWrite frame | ADS since ~2010 | 100-item batch = 1 frame (Phase-3 concurrency lesson exercised in one frame) |

No deprecations relevant. 0xF083/F084 (READEX/READEX2) and 0xF085/F086 (notification sum) are
explicitly deferred to v2 per CONTEXT.md.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | On a per-item READ/READWRITE failure the PLC emits 0 data bytes for that item (data cursor advances by 0, not by requested length) | Pitfall 1, Wire Layouts A/C | If the PLC instead reserves the full slot with zero-fill, the golden fixture and decoder cursor rule must advance by requested length. **Mitigation: the mock defines our contract and the golden pins it — choose the 0-byte convention, document it, and the mock+decoder+golden are internally consistent regardless of a specific real PLC's choice.** No external PLC in scope this phase. |
| A2 | pyads/ads-client match these layouts | Summary | None load-bearing — primary source (AdsDef.h) already pins layouts; cross-check is corroboration only. |

**Note on A1:** Because this phase only ever talks to *our* mock (no real PLC in the test slice),
the mock's emission IS the specification the decoder must match, and the golden fixture freezes it.
Pick the 0-byte-on-failure convention (simplest, keeps error region and data region cleanly
separable) and make mock + decoder + golden agree. Flag in the parity header for the Phase 9 audit
that no C++ AdsLibTest sum scenario exists to cross-validate against (per CONTEXT.md decision).

## Open Questions (RESOLVED)

> RESOLVED: trust outer indexOffset as N; validate it equals writeLength/12 for READ/WRITE (16B stride for READWRITE); break on mismatch (implemented in plan 06-02 Task 1).

1. **N derivation in the mock for READ** — outer `indexOffset` carries N, but the mock could also
   derive `N = writeLength/12`. Recommendation: trust outer `indexOffset` as N and *validate* it
   equals `writeLength/12` (READ/WRITE) or is consistent with the 16B stride (READWRITE); `break`
   (no response) on mismatch, matching existing hostile-input handling. Not blocking.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | Pure codec + client | ✓ (pubspec.lock present) | project-pinned | — |
| CMake + C++ toolchain | mock_server / dump_golden rebuild | ✓ (test_harness/build populated, CMake 4.2.3) | 4.2.3 | — |

No new external dependencies. No missing dependencies.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` (Dart) via `dart_test.yaml` |
| Config file | `/Users/jonb/Projects/dart-ads/dart_test.yaml` |
| Quick run command | `dart test test/unit -n <regex>` |
| Full suite command | `dart test` (unit + integration; integration spins the mock) |
| Golden regen + drift gate | `test_harness/build/dump_golden test/golden && git diff --exit-code` |

### Phase Requirements → Test Map
| Req | Behavior | Test Type | Automated Command | File Exists? |
|-----|----------|-----------|-------------------|-------------|
| SUM-01 | READ builder/decoder round-trip + golden parity | unit | `dart test test/unit/golden_parity_test.dart -n 'sum_read'` | ❌ Wave 0 (new test + `sum_read_req/res.hex`) |
| SUM-02 | WRITE builder/decoder + result-only response | unit | `dart test test/unit -n 'sumWrite'` | ❌ Wave 0 |
| SUM-03 | READWRITE decoder uses RETURNED lengths | unit | `dart test test/unit -n 'sumReadWrite'` | ❌ Wave 0 |
| SUM-04 | Mid-batch failure: item k fails, items≠k carry correct data at correct offsets | unit + integration | `dart test -n 'sum.*partial'` | ❌ Wave 0 (decode fixture + live mock) |
| SUM-01/03 | Live batch read/readWrite + read-after-sumWrite vs mock | integration | `dart test test/integration/ads_client_test.dart -n 'sum'` | ❌ Wave 0 (mock sum handler required first) |
| SUM-01 | 100-item batch in one frame (concurrency lesson) | integration | `dart test -n 'sum.*large'` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `dart test test/unit -n 'sum'` (< 5 s)
- **Per wave merge:** `dart test` full suite (integration exercises live mock)
- **Phase gate:** full suite green + `dump_golden && git diff --exit-code` clean before `/gsd:verify-work`

### Golden Fixtures (multi-item batches — CONTEXT.md requires ≥1 per group)
Emit from `dump_golden.cpp` (mirror the `writeHex` pattern at `:120`, `:267`):
- `sum_read_req.hex` / `sum_read_res.hex` — batch of ≥3 items, one deliberately targeting
  `kErrResultGroup` so the res golden freezes the **mid-batch-failure alignment**.
- `sum_write_req.hex` / `sum_write_res.hex` — ≥3 items with distinct data, N×u32 result region.
- `sum_readwrite_req.hex` / `sum_readwrite_res.hex` — ≥3 items with **variable returned lengths**
  (at least one returned len < requested) to pin the returned-length slicing rule.

### Wave 0 Gaps
- [ ] `test/golden/sum_{read,write,readwrite}_{req,res}.hex` — 6 fixtures (blocked on dump_golden sum emit)
- [ ] `dump_golden.cpp` sum-emit blocks — must exist before goldens
- [ ] `mock_server.cpp` sum sub-handler in READ_WRITE case — blocks integration tests
- [ ] Unit tests for the three codecs + the SUM-04 alignment decode test
- [ ] Integration test additions in `test/integration/ads_client_test.dart`
- [ ] `test/support/mock_server.dart` — confirm it forwards to the rebuilt C++ mock (no Dart-side change expected)

## Project Constraints (from CLAUDE.md)

Extracted directives the planner must honor (from `/Users/jonb/Projects/dart-ads/CLAUDE.md`; the
CONTEXT.md "Established Patterns" corroborate these):
- `protocol/` purity — sum builders/decoders import only `dart:typed_data` + local pure types; no
  `dart:async`/`dart:io`.
- Golden parity for every new codec; goldens are byte-authoritative and CI-gated via
  `dump_golden && git diff --exit-code`.
- `--fatal-infos` analysis clean; atomic commits; verify ordering.
- Bounds-check declared lengths before slicing (T-1-03) — mirror `_decodeResultAndData`.
- `checkUint(…, 32, …)` on every u32 field written to the wire.

*(Full CLAUDE.md not re-quoted to conserve context; planner should re-read it directly for the
authoritative text before locking tasks.)*

## Security Domain

`security_enforcement` not set to false in config → included, scoped to this pure-protocol phase.

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | Validate outer `readLength`/each per-item length ≤ bytes present before slicing (T-1-03); `checkUint` on all outbound u32; cap N and total sizes against `kMaxFrameBytes` in the mock |
| V6 Cryptography | no | — |
| V2/V3/V4 Auth/Session/Access | no | ADS transport layer, out of phase scope |

| Threat Pattern | STRIDE | Mitigation |
|----------------|--------|-----------|
| Hostile per-item length / N causing overread | Tampering/DoS | Subtraction-form bounds checks (mirror `mock_server.cpp:764,849`), decoder validates each block ≤ remaining before slice, `break`/throw on mismatch |
| Oversized batch → 4GiB alloc | DoS | Cap total requested read/write against `kMaxFrameBytes` before allocating (mock already does per-command) |

## Sources

### Primary (HIGH confidence)
- `third_party/ADS/AdsLib/standalone/AdsDef.h:68-115` — SUMUP index-group definitions + Beckhoff
  layout doc-comments (the authority for all three wire layouts and the IOffs=list-size convention).
- `lib/src/protocol/commands.dart` — `buildReadWritePayload`, `_decodeResultAndData`, response idiom.
- `lib/src/client/ads_client.dart:108-126,280-299` — `readWrite`, `_command`, `_throwOnResult`.
- `test_harness/mock_server.cpp:604,682-872` — store, magic error groups, READ_WRITE dispatch.
- `test_harness/dump_golden.cpp:120,267-288` — `writeHex` golden emission pattern.

### Secondary (MEDIUM confidence)
- pyads / Beckhoff.Ads (ads-client) SUMUP implementations — training knowledge; corroborate the
  err-region-then-data (READ) and result+len-then-data (READWRITE) shapes. Not load-bearing given
  the primary source.

### Tertiary (LOW confidence)
- None required.

## Metadata

**Confidence breakdown:**
- Wire layouts: HIGH — pinned from vendored Beckhoff header primary source; critical ambiguity resolved.
- Mock design: HIGH — exact insertion point and reuse mechanics read from current source.
- Dart shapes: HIGH (consistency) — mirror existing idioms; naming is discretion per CONTEXT.md.
- Pitfalls / A1 convention: MEDIUM — the 0-byte-on-failure data convention is our choice frozen by
  the golden, not an external PLC observation (flagged in Assumptions Log).

**Research date:** 2026-07-04
**Valid until:** 2026-08-03 (stable — vendored source is version-pinned; no fast-moving deps)
