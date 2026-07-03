# Stack Research

**Domain:** Pure-Dart networking/protocol library + CLI (Beckhoff ADS / AMS/TCP client, reimplementing the C++ AdsLib)
**Researched:** 2026-07-03
**Confidence:** HIGH (core Dart tooling verified against pub.dev/dart.dev); MEDIUM (AdsLib build specifics, C++ mock-server harness patterns)

## Executive Guidance

This is a "boring stack on purpose" project. The library is a byte-pushing protocol client with zero business need for third-party runtime dependencies. The right stack is **the Dart SDK core libraries (`dart:io`, `dart:typed_data`, `dart:async`, `dart:convert`) with essentially no runtime dependencies**, plus a thin, well-established dev/tooling layer (`test`, `lints`, `args`, `coverage`). Every runtime dependency you add is a liability for a publishable library that must stay pure-Dart and native-only. Resist the urge to pull in a framing/parsing package — AMS/TCP framing is a 6-byte fixed header with a 32-bit little-endian length field, which is a few dozen lines of Dart you should own and unit-test directly.

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Dart SDK | 3.12.x (dev on latest stable); pubspec floor `>=3.5.0 <4.0.0` | Language + runtime + core libs | Current stable is 3.12.2. Dart 3.x gives sound null safety, records, patterns, sealed classes — all directly useful for modeling ADS command/response variants and fixed-layout headers. A `^3.5` floor keeps you on modern language features while staying broadly installable for library consumers. |
| `dart:io` (SDK) | — | Raw TCP sockets, `Process` for test server | `Socket`/`RawSocket` are the only sane transport for AMS/TCP (port 48898). No web support by design — matches the project's native-VM + Flutter-desktop/mobile constraint. |
| `dart:typed_data` (SDK) | — | `Uint8List`, `ByteData`, `Endian.little` | The canonical way to encode/decode wire formats in Dart. `ByteData.getUint32(offset, Endian.little)` / `setUint32` map 1:1 onto ADS's little-endian fields. No package needed. |
| `dart:async` (SDK) | — | `Future` (request/response), `Stream`/`StreamController` (notifications), `Completer` (matching responses to in-flight requests by invoke-id) | Matches the project's idiomatic-async API mandate. Device notifications become a broadcast `Stream`; each request/response pair is a `Completer` keyed on the AMS invoke ID. |
| `dart:convert` (SDK) | — | UTF-8 for symbol names, hex/JSON for CLI I/O | Symbol names in ADS are null-terminated strings; `utf8`/`ascii` codecs handle them. JSON for CLI `pull`/`push` file formats. |

### Supporting Libraries (runtime — keep to near zero)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `args` | ^2.7.0 | CLI arg parsing + `CommandRunner`/`Command` for subcommands | **Use it.** The `browse/read/write/subscribe/pull/push/action` command set maps directly onto `CommandRunner` with one `Command` subclass each. This is the Dart-team-maintained standard; no reason to use anything else. |
| `path` | ^1.9.0 | Cross-platform path handling in the CLI (`pull`/`push` file targets) | Only in `bin/` / CLI code, not the protocol library. |
| `meta` | ^1.16.0 | `@internal`, `@immutable`, `@visibleForTesting` annotations | Optional. Helps mark internal framing classes so they don't leak into the public API of a pub.dev package. |
| `collection` | ^1.19.0 | `equality`, `UnmodifiableUint8ListView`-style helpers, list utils | Optional — only if you need deep equality on decoded structs in tests/public value types. |

> Deliberately **not** adding a framing package (see "What NOT to Use"). The library's `dependencies:` block should ideally be empty or contain only `meta`/`collection`.

### Development Tools (dev_dependencies)

| Tool | Version | Purpose | Notes |
|------|---------|---------|-------|
| `test` | ^1.31.0 | Unit + integration tests | The standard Dart test runner. Use `dart_test.yaml` + `@Tags(['integration'])` to separate fast codec unit tests from tests that spawn the C++ mock server. |
| `lints` | ^6.1.0 | Official Dart lint rules (`package:lints/recommended.yaml`) | Baseline for any pub.dev package. Enable `recommended` (stricter than `core`). See lint note below. |
| `coverage` | ^1.11.0 | `dart test --coverage` → LCOV | For CI coverage reporting (Codecov). |
| `dart format` (SDK) | — | Formatting | Enforced in CI (`dart format --output=none --set-exit-if-changed .`). |
| `dart analyze` (SDK) | — | Static analysis | CI gate: `dart analyze --fatal-infos`. |

**Lint choice:** `lints` (official) is the safe default for a published package. `very_good_analysis` (^10.3.0) is a stricter, opinionated superset — reasonable if you want maximum rigor, but it will flag a lot in low-level byte code (e.g. magic numbers, cascade preferences). Recommendation: start with `lints/recommended.yaml` and add targeted rules, rather than adopting `very_good_analysis` wholesale on a byte-manipulation-heavy codebase.

## Package Layout

Standard pub package layout for a combined library + CLI:

```
dart-ads/
  pubspec.yaml
  analysis_options.yaml         # include: package:lints/recommended.yaml
  dart_test.yaml                # tags: { integration: {} }
  CHANGELOG.md
  README.md
  LICENSE
  lib/
    dart_ads.dart               # public API barrel (exports src/ selectively)
    src/                        # implementation — NOT exported directly
      amstcp/                   # AMS/TCP + AMS header framing
      router/                   # Dart AmsRouter port
      commands/                 # Read/Write/ReadWrite/ReadState/WriteControl/sum
      notifications/            # subscription -> Stream plumbing
      symbols/                  # handle-by-name, symbol upload/browse
      transport/                # Socket wrapper, direct vs local-router
  bin/
    ads.dart                    # CLI entrypoint -> CommandRunner
  test/
    unit/                       # framing/codec tests, no I/O
    integration/                # @Tags(['integration']) — drives C++ mock server
  test/support/                 # Dart harness that spawns the mock server
  tool/
    mock_server/                # CMake + C++ mock ADS server (vendors Beckhoff/ADS)
  third_party/ADS/              # vendored Beckhoff/ADS (git submodule or subtree)
  example/
    main.dart                   # pub.dev scoring wants an example/
```

**`pubspec.yaml` essentials:**

```yaml
name: dart_ads          # pub package names are snake_case; repo can stay "dart-ads"
description: Pure-Dart client for the Beckhoff ADS (AMS/TCP) protocol.
version: 0.1.0
repository: https://github.com/<you>/dart-ads
environment:
  sdk: ">=3.5.0 <4.0.0"
# Platform declaration excludes web (native-only):
platforms:
  linux:
  macos:
  windows:
  android:
  ios:
executables:
  ads: ads          # `dart pub global activate` -> `ads` command from bin/ads.dart
dependencies:
  args: ^2.7.0
  path: ^1.9.0
  meta: ^1.16.0
dev_dependencies:
  test: ^1.31.0
  lints: ^6.1.0
  coverage: ^1.11.0
```

Declaring `platforms:` without `web:` is how you signal native-only on pub.dev and avoid false "supports web" scoring. `dart:io` usage already makes it non-web at runtime, but the explicit declaration is the current best practice.

## Binary / Wire-Protocol Handling (ADS is little-endian)

**Decode path:** wrap the received bytes once and read fields by offset.

```dart
// b is a Uint8List slice of one complete AMS/TCP frame.
final bd = ByteData.sublistView(b);            // zero-copy view, no allocation
final length = bd.getUint32(2, Endian.little);  // AMS/TCP header length field
final cmdId  = bd.getUint16(offset, Endian.little);
```

**Guidance:**
- Use **`ByteData.sublistView(uint8list)`** for zero-copy reading — do not copy into a `List<int>`.
- **Always pass `Endian.little` explicitly** on every `getX`/`setX`. ADS/AMS is little-endian on the wire; never rely on the host/default. Make a code-review rule of it.
- For encoding, allocate a `Uint8List` of the exact known frame size, wrap in `ByteData`, and `setUint16/32` fields by offset. AMS headers are fixed-layout, so sizes are computable up front.
- Model `AmsNetId` (6 bytes) and headers as small value classes with `toBytes()`/`fromBytes(ByteData, offset)` — keeps offset math localized and unit-testable.
- Use Dart **records/sealed classes** for command/response variants (e.g. a sealed `AdsResponse` with subtypes) to get exhaustive `switch` handling.
- Benchmark note (MEDIUM confidence, from community sources): `ByteData` accessors are the idiomatic and fast path; only drop to manual byte-shifting on `Uint8List` if profiling shows a hotspot. Don't prematurely optimize.

## Socket & Framing Strategy

**Transport:** use `Socket` (from `dart:io`), not `RawSocket`, unless you need byte-level backpressure control. `Socket` exposes an inbound `Stream<Uint8List>` and is the ergonomic choice; `RawSocket` only pays off if you must manage read events manually.

**Framing (the important part):** TCP is a byte stream — `Socket`'s stream emits arbitrary-sized chunks (as small as 1 byte, or several frames coalesced). AMS/TCP frames are **length-prefixed**: a 6-byte AMS/TCP header whose bytes 2–5 are a little-endian `uint32` payload length, followed by the AMS header + data. Implement an incremental framer:

1. Maintain a rolling buffer (a growable `BytesBuilder` for accumulation, or better, a manual `Uint8List` + read-offset ring to avoid re-allocation churn).
2. On each inbound chunk, append, then loop: if buffered bytes ≥ 6, read the length field; if buffered bytes ≥ `6 + length`, slice out one complete frame, emit it, advance the offset; else wait for more.
3. **Guard the length field** — reject absurd lengths before allocating (a hostile/buggy peer sending a huge prefix is the classic OOM). Enforce a sane max frame size.
4. Emit complete frames as a `Stream<Uint8List>` that the command layer consumes; correlate responses to requests via the AMS **invoke ID** using a `Map<int, Completer>`.

**Do not** use `BytesBuilder`-per-frame naively then `takeBytes()` on every chunk — it works in tests and melts under 1-byte chunking. Own a small, tested `AmsFramer` class.

**Package option (rejected for runtime):** the `framer` package (1.0.1) offers a `LengthPrefixedCodec` (u32be/varint). It is immature (1 like, ~34 weekly downloads, and its length codecs are big-endian/varint — not ADS's little-endian layout, which also includes the 2-byte reserved prefix). Reference it for design ideas, but **write your own** — the logic is small, and a published protocol library should not depend on a low-adoption package for its hot path.

## CLI Framework

Use **`args` + `CommandRunner`**. Structure:

```dart
// bin/ads.dart
final runner = CommandRunner<int>('ads', 'Beckhoff ADS command-line client')
  ..addCommand(BrowseCommand())
  ..addCommand(ReadCommand())
  ..addCommand(WriteCommand())
  ..addCommand(SubscribeCommand())   // long-lived; prints Stream events until Ctrl-C
  ..addCommand(PullCommand())
  ..addCommand(PushCommand())
  ..addCommand(ActionCommand());
exit(await runner.run(args) ?? 0);
```

- Global options (`--net-id`, `--host`, `--port 48898`, `--router`/`--direct`, `--timeout`) go on the runner's `argParser`; per-command options on each `Command`.
- `subscribe` is naturally a streaming command: bind the library's notification `Stream` to stdout and complete on SIGINT.
- Register `executables: { ads: ads }` in pubspec so `dart pub global activate dart_ads` yields an `ads` binary; also `dart compile exe bin/ads.dart` for a standalone native binary.

No need for heavier CLI frameworks — `args` is the Dart-team standard and covers subcommands, help generation, and usage errors.

## Testing Stack

**Runner:** `package:test`. Split tests:
- **Unit** (`test/unit/`): pure codec/framing tests — build known byte vectors (ideally captured from the reference AdsLib) and assert encode/decode round-trips. Fast, no I/O, run everywhere.
- **Integration** (`test/integration/`): tagged `@Tags(['integration'])`, spawn the C++ mock server, exercise real socket round-trips.

**`dart_test.yaml`:**
```yaml
tags:
  integration:
    timeout: 30s
```
Run units by default in CI on all platforms; run integration in a job that builds the C++ server (Linux runner with CMake). Invoke integration explicitly: `dart test -t integration`.

**Driving the CMake-built C++ mock server from Dart:**
- Build the server in a CI step (or a `tool/build_mock.sh`) via CMake, producing an executable under `tool/mock_server/build/`.
- In a Dart `setUpAll`, launch it with `Process.start(exePath, ['--port', '0' or fixed])`.
- **Port handshake:** prefer having the server bind an ephemeral port (`0`) and print the chosen port to stdout; the Dart harness reads the first stdout line to learn the port. This avoids flaky hard-coded ports and parallel-run collisions. If the server can't do ephemeral, pick a fixed high port and poll-connect with retry until it accepts.
- **Readiness:** don't assume the server is listening the instant `Process.start` returns. Either parse a "listening on N" stdout line or retry `Socket.connect` with a short backoff until success or timeout.
- **Lifecycle:** kill in `tearDownAll` (`process.kill(); await process.exitCode;`), and forward server stderr to test output for debugging. Guard against orphan processes on test failure.
- Keep server logs (stdout/stderr) piped and printed on failure — invaluable when a frame mismatch happens.

## CMake + C++ Mock Server (vendoring Beckhoff/ADS)

**How AdsLib is normally built (MEDIUM confidence):**
- Requires a **C++14** compiler.
- Upstream supports **Meson** (`meson setup build && ninja -C build`), **CMake** (`CMakeLists.txt`), and a plain **Makefile**. Since the project mandates CMake for the harness, use the provided `CMakeLists.txt`.
- AdsLib is a **client** library (AmsRouter, AdsDef, framing structs). It does **not** ship a ready-made server — you'll write a small mock server in C++ that **reuses AdsLib's frame structs / (de)serialization** (`AmsHeader`, `AoEHeader`, AMS/TCP header layouts) to produce byte-accurate responses. This is the intended use: reuse framing, hand-roll minimal server-side response logic for the commands under test.

**Vendoring approach:**
- Add `github.com/Beckhoff/ADS` as a **git submodule** under `third_party/ADS/` (pin to a specific commit/tag for reproducibility). Submodule is cleaner than subtree here since you're not modifying upstream.
- Your `tool/mock_server/CMakeLists.txt` does `add_subdirectory(third_party/ADS)` (or references its lib target) and links the mock server target against the AdsLib target.
- Use a **recent CMake** (3.16+ is a safe modern floor; exact upstream minimum not verified — set your own `cmake_minimum_required(VERSION 3.16)`).
- CI: on the Linux integration job, `apt-get install cmake ninja-build g++`, `cmake -S tool/mock_server -B build -G Ninja`, `cmake --build build`.

**Confidence flag for roadmap:** the exact reuse surface of AdsLib for a *server* (which structs are public enough to serialize responses without private headers) needs hands-on verification early — flag the mock-server phase for deeper research.

## Lint / Format / CI Conventions

**`analysis_options.yaml`:**
```yaml
include: package:lints/recommended.yaml
analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
linter:
  rules:
    - prefer_final_locals
    - public_member_api_docs   # pub.dev scoring rewards documented public API
```

**CI (GitHub Actions, `dart-lang/setup-dart`):**
- **Analyze/format/unit job** (matrix over stable + optionally beta): `dart pub get` → `dart format --output=none --set-exit-if-changed .` → `dart analyze --fatal-infos` → `dart test` (unit only).
- **Integration job** (Linux): install CMake/Ninja/g++, checkout submodules (`submodules: recursive`), build mock server, `dart test -t integration`.
- **Coverage:** `dart test --coverage=coverage` → `format_coverage`/`coverage` → upload LCOV to Codecov.
- **Publishing:** use Dart's **automated publishing** — the reusable workflow `dart-lang/setup-dart/.github/workflows/publish.yml@v1` triggered on version tags, authenticated via **OIDC** (no long-lived pub.dev token secret). Configure the publisher on pub.dev to trust the GitHub repo/tag pattern.

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Custom `AmsFramer` on `dart:typed_data` | `framer` package (1.0.1) | Never for this — its length codecs are big-endian/varint and it's low-adoption. Only for prototyping ideas. |
| `Socket` (buffered) | `RawSocket` | If you need explicit read/write event control and backpressure at the byte level; adds complexity for marginal gain here. |
| `lints/recommended` | `very_good_analysis` ^10.3.0 | If you want maximally strict linting and are willing to tune out many false-positives on byte-level code. |
| `args` + `CommandRunner` | `dcli`, hand-rolled parsing | `args` is the standard; alternatives add deps without benefit for this command set. |
| CMake for mock server | Meson (upstream default) | If you'd rather match AdsLib's primary build system; but PROJECT mandates CMake and CMake is more familiar in CI. |
| git submodule for AdsLib | git subtree / vendored copy | Subtree if you must patch upstream and want it in-tree without submodule friction. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `dart:ffi` / TcAdsDll bindings | Defeats the entire premise (pure-Dart, portable, no native runtime dep). Explicitly out of scope. | Pure-Dart AMS/TCP implementation on `dart:io`. |
| `dart:html` / `package:web` / WebSocket transport | No raw TCP in browsers; project is native-only by design. | `dart:io` `Socket`. Declare `platforms:` without `web`. |
| Third-party binary-parsing packages (`binary`, `buffer`, `framer`, protobuf) | ADS has a fixed, hand-specified layout; a published protocol lib should own its wire code and minimize deps. | `dart:typed_data` `ByteData`/`Uint8List` directly. |
| Default/host endianness in `ByteData` calls | ADS is little-endian; relying on default risks host-dependent bugs on big-endian or future changes. | Always pass `Endian.little` explicitly. |
| Naive per-chunk `BytesBuilder.takeBytes()` framing | Melts under 1-byte TCP chunking; OOM on hostile length prefix. | Incremental buffered framer with a max-frame guard. |
| Hard-coded fixed test ports everywhere | Flaky under parallel test runs / port reuse. | Ephemeral port + stdout handshake from the mock server. |
| Long-lived pub.dev publish token in CI secrets | Security risk; deprecated pattern. | OIDC automated publishing via `dart-lang/setup-dart` reusable workflow. |

## Stack Patterns by Variant

**If connecting directly to a remote ADS peer (no TwinCAT installed):**
- The Dart-ported `AmsRouter` owns routing; you open the `Socket` to `<peer>:48898` yourself and assign local AMS Net ID.
- Because there's no local router, you handle AMS/TCP port-open handshake and route bookkeeping in Dart.

**If connecting via a local TwinCAT router:**
- Connect `Socket` to `127.0.0.1:48898` (the local router); the router handles onward routing.
- Transport abstraction should make direct-vs-router a strategy selected at runtime (as PROJECT requires) — a single `AdsTransport` interface with two implementations behind it.

**If shipping the CLI as a distributable binary:**
- `dart compile exe bin/ads.dart -o ads` for a self-contained native executable (no Dart SDK needed on target). Build per-platform in CI release artifacts.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Dart SDK 3.12.x | `args ^2.7.0`, `test ^1.31.0`, `lints ^6.1.0` | All current, actively maintained by Dart team. `lints 6.x` targets Dart 3.x. |
| pubspec floor `>=3.5.0` | Consumers on Dart 3.5+ | Balances modern language features against consumer reach; raise only if you adopt a 3.6+/3.7+ only feature. |
| Beckhoff/ADS AdsLib | C++14 compiler, CMake 3.16+ (self-set), Ninja/Make | Pin to a specific upstream commit/tag via submodule for reproducible mock-server builds. |

## Sources

- https://pub.dev/packages/args — args 2.7.0, CommandRunner/Command for subcommands (HIGH)
- https://pub.dev/packages/test — test 1.31.2 latest (HIGH)
- https://pub.dev/packages/lints — lints 6.1.0 latest (HIGH)
- https://pub.dev/packages/very_good_analysis — very_good_analysis 10.3.0 (HIGH)
- https://pub.dev/packages/framer — framer 1.0.1, LengthPrefixedCodec u32be/varint, low adoption (HIGH on facts / basis for rejection)
- https://dart.dev/get-dart — Dart stable 3.12.2 as of research date (HIGH)
- https://github.com/Beckhoff/ADS — AdsLib build (Meson/CMake/Make), C++14, client-only (no bundled server) (MEDIUM — README-level)
- https://api.dart.dev dart:typed_data (ByteData/Endian), dart:io (Socket/RawSocket) — endianness + socket API (HIGH)
- https://www.rugu.dev/en/blog/sockets-and-message-framing/ — length-prefix vs delimiter framing over dart:io sockets (MEDIUM)
- https://dart.dev/tools/pub/automated-publishing — OIDC-based automated pub.dev publishing via GitHub Actions (HIGH)
- https://dart.dev/blog/announcing-dart-support-for-github-actions — dart-lang/setup-dart CI workflow (HIGH)

---
*Stack research for: Pure-Dart Beckhoff ADS (AMS/TCP) client library + CLI*
*Researched: 2026-07-03*
