# dart-ads

## What This Is

`dart-ads` is a pure-Dart client library for the Beckhoff ADS protocol (AMS/TCP), reimplementing the open-source Beckhoff C++ AdsLib in Dart-only code. It lets Dart and Flutter applications talk to Beckhoff/TwinCAT PLCs directly — reading and writing variables, subscribing to device notifications, browsing symbols, and issuing control actions — without any native/FFI dependency. It ships with a companion Dart CLI for interacting with PLCs from the terminal.

The C++ AdsLib (github.com/Beckhoff/ADS) is the reference implementation: its wire framing, protocol behavior, and API surface guide the Dart port, and a CMake-built C++ mock server derived from it drives the integration tests.

## Core Value

A Dart application can reliably connect to a Beckhoff PLC and read, write, and subscribe to variables over ADS — with wire behavior verified byte-for-byte against the reference C++ implementation.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these. -->

**Protocol & transport**
- [x] AMS/TCP framing (AMS header, AMS/TCP header) implemented in pure Dart — Validated in Phase 1 (byte-for-byte vs C++ goldens)
- [x] Configurable transport: direct + local-router modes selectable at runtime — Validated in Phase 4 (dual-mode integration proof; real-TwinCAT 0x1000 registration tracked v2)
- [x] Dart port of the AmsRouter — Validated in Phase 4 (port allocator, route table, source stamping, C++ parity tests)
- [x] Connection lifecycle: open, close, error/timeout handling — Validated in Phase 2 (reconnect deferred to v2 per RECON-01)

**ADS commands (full AdsLib parity)**
- [x] Read, Write, ReadWrite — Validated in Phase 3 (live vs mock + C++ parity ports)
- [x] ReadState, WriteControl — Validated in Phase 3 (stateful WriteControl→ReadState proven)
- [x] Device notifications as Dart Streams — Validated in Phase 5 (nested parser, handle lifecycle, C++ parity + stress tests)
- [x] Symbol access by name + browse + typed values — Validated in Phase 7 (handle lifecycle w/ leak proof, entryLength-safe blob parser, full scalar codec)
- [x] Sum (batched) commands (read/write/readwrite) — Validated in Phase 6 (per-item results, partial-failure alignment; batched notifications v2)
- [x] Route / AmsRouter management (add/remove routes, setLocalAddress) — Validated in Phase 4

**API surface**
- [ ] Idiomatic async Dart API: `Future`s for request/response, `Stream`s for notifications, non-blocking sockets

**Dart CLI**
- [ ] `browse` — browse/list PLC symbols
- [ ] `read` — read a variable (by name or index-group/offset)
- [ ] `write` — write a variable
- [ ] `subscribe` — stream device notifications for a symbol
- [ ] `pull` — download data/symbols from the PLC (e.g. dump symbols or values to file)
- [ ] `push` — upload/write data to the PLC (e.g. apply values from file)
- [ ] `action` — issue a control action / method call (WriteControl / RPC-style invocation)

**Testing**
- [x] C++ mock ADS server built with CMake, reusing AdsLib framing, that Dart integration tests connect to — Validated in Phase 1 (mock + dump_golden + selftest; live connect lands in Phase 2)
- [x] Dart integration tests validate encode/decode and behavior against the mock server's real frames — Validated in Phase 2 (live round-trip, reorder, disconnect)
- [x] Unit tests for framing and codecs — Validated in Phase 1 (50 tests incl. golden parity + adversarial reassembly)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Web/browser support — ADS is raw TCP; `dart:html` has no socket access. Native VM + Flutter desktop/mobile only.
- FFI bindings to TcAdsDll / native AdsLib — the whole point is a pure-Dart reimplementation.
- ADS *server*/device implementation — this is a client library, not an ADS device.
- Reimplementing TwinCAT itself or its runtime — we interoperate with it, not replace it.

## Context

- **Reference source:** The open-source Beckhoff C++ AdsLib (github.com/Beckhoff/ADS) will be vendored into the repo as reference material and reused for the CMake test server.
- **Protocol:** ADS runs over AMS/TCP, default port `48898`. Communication is either direct to a remote ADS peer (AdsLib ships its own AmsRouter for this) or via a local TwinCAT router.
- **First consumer:** The user's own HMI/automation app needs Beckhoff PLC connectivity from Dart/Flutter — driving the async, Stream-based API design.
- **Distribution:** Intended as a standalone package, publishable to pub.dev.

## Constraints

- **Tech stack**: Pure Dart on `dart:io` (raw sockets). No native/FFI dependencies in the library.
- **Platform**: Native Dart VM + Flutter desktop/mobile. No web.
- **Correctness**: Wire behavior must match the reference C++ AdsLib; the C++ mock server is the source of truth for integration tests.
- **Tooling**: C++ integration-test harness builds via CMake.
- **Packaging**: Standalone pure-Dart pub package (library + CLI), publishable to pub.dev.

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Pure-Dart reimplementation (no FFI) | Portability across Dart/Flutter platforms; no native toolchain at runtime | — Pending |
| Reference the open-source Beckhoff/ADS C++ AdsLib | Authoritative protocol behavior; reusable for the mock test server | — Pending |
| Idiomatic async API (Futures + Streams) | Matches Dart conventions and non-blocking sockets; natural fit for notifications | — Pending |
| Full AdsLib parity in v1 | The consuming HMI app needs symbol-by-name, notifications, and sum commands, not just basic read/write | — Pending |
| Configurable direct + local-router transport | Support both TwinCAT-installed and router-less deployments | — Pending |
| C++ mock ADS server via CMake for integration tests | Validate Dart wire behavior against real C++-produced frames | — Pending |
| Ship a Dart CLI (browse/read/write/subscribe/pull/push/action) | Real end-to-end exercise of the library and a useful operator tool | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-04 after Phase 7 (Symbol Access, Browse & Typed Values) completion*
