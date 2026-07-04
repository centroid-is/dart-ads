# Phase 6: Sum (Batched) Commands - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (grey-area recommendations auto-accepted per standing user directive)

<domain>
## Phase Boundary

Users batch multiple reads/writes into a single ADS request and receive per-item results, with partial failures surfaced per item rather than as a whole-batch throw. Delivers SUMUP_READ (0xF080), SUMUP_WRITE (0xF081), SUMUP_READWRITE (0xF082) payload builders/decoders (pure protocol), AdsClient sum methods returning per-item results, mock support for the three sum groups over its data store, and partial-failure tests. No batched notifications (SUMUP_ADDDEVNOTE v2/NOTIF-05).

Requirements: SUM-01, SUM-02, SUM-03, SUM-04.

</domain>

<decisions>
## Implementation Decisions

### API Shape
- `AdsClient.sumRead(List<SumReadRequest>)` → `List<SumResult<Uint8List>>`; `sumWrite(List<SumWriteRequest>)` → `List<SumResult<void>>`; `sumReadWrite(List<SumReadWriteRequest>)` → `List<SumResult<Uint8List>>`
- Request items as simple value types (indexGroup, indexOffset, length / data); `SumResult` carries per-item `errorCode` (0 = success) + value; convenience `isSuccess`/`valueOrThrow` (throws AdsException with the item's code)
- Partial failure NEVER throws for the batch (SUM-04); whole-batch throws only for transport-level failures or a non-zero outer AMS errorCode / outer ReadWrite result
- Empty batch: return empty list without a wire call (documented)
- All three implemented as ReadWrite to the SUMUP index groups with indexOffset = item count (AdsLib convention — researcher pins exact layouts from vendored source/adstool)

### Wire Layouts (researcher to pin byte-exact from vendored AdsLib/adstool)
- SUMUP_READ 0xF080: write buffer = N × 12B (ig u32, io u32, len u32); response = N × u32 error codes region followed by concatenated data (researcher confirms error-region shape: err-only vs err+len)
- SUMUP_WRITE 0xF081: write buffer = N × 12B headers followed by concatenated data; response = N × u32 error codes
- SUMUP_READWRITE 0xF082: write buffer = N × 16B (ig, io, readLen, writeLen) + concatenated write data; response = N × (err u32, len u32) + concatenated variable-length data
- Builders/decoders in protocol/ (pure), following the buildXxxPayload single-source-of-truth pattern; golden fixtures emitted by dump_golden for at least one multi-item batch per sum group

### Mock Support
- Mock handles ReadWrite to 0xF080/81/82 by looping over its existing data store with the same per-command semantics (incl. write-back)
- Batch items targeting the existing magic error groups (0xE7700000 payload-result region) yield that item's error code in the per-item error region while other items succeed — the deterministic partial-failure fixture (SUM-04 test: item N fails, others carry data, alignment preserved)

### Tests
- Unit: builder/decoder round-trips + golden parity for the three groups; partial-failure decode with mid-batch error (offset alignment proof)
- Integration: live batch read/write/readWrite against the mock incl. read-after-sumWrite; mid-batch failure surfaces per-item; large batch (e.g. 100 items) exercises the Phase-3 concurrency lesson in one frame
- No C++ AdsLibTest sum scenarios exist (not part of TEST-05 slice) — note this in the parity header for the Phase 9 audit

### Claude's Discretion
- File layout (protocol/sum_commands.dart, client method placement), exact value-type naming
- Whether SumResult is sealed class or record-based — pick idiomatic and consistent with AdsResponse style

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- ReadWrite plumbing end-to-end (client → connection → mock); buildReadWritePayload pattern
- Mock data store with write-back + magic error groups; dump_golden harness; readGolden
- AdsException/fromCode; range_check builders

### Established Patterns
- protocol/ purity; golden parity for every new codec; -n regex filters; --fatal-infos; verify ordering; atomic commits

### Integration Points
- Phase 8 CLI pull/push consume sumRead/sumWrite
- Phase 7 symbol browse may use sum reads later (not required)

</code_context>

<specifics>
## Specific Ideas

- SUM-04's litmus test: a batch where item k deliberately fails must return data for items ≠ k with correct offsets — the alignment bug class from research PITFALLS
- The outer ReadWrite errorCode/result vs inner per-item codes are DIFFERENT layers — outer non-zero throws AdsException; inner codes go into SumResult items

</specifics>

<deferred>
## Deferred Ideas

- SUMUP_ADDDEVNOTE / SUMUP_DELDEVNOTE batched subscriptions → v2 (NOTIF-05)
- SUMUP_READEX/READEX2 variants → v2 unless research shows they're needed for CLI pull

</deferred>
