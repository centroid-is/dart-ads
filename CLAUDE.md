<!-- GSD:project-start source:PROJECT.md -->
## Project

**dart-ads**

`dart-ads` is a pure-Dart client library for the Beckhoff ADS protocol (AMS/TCP), reimplementing the open-source Beckhoff C++ AdsLib in Dart-only code. It lets Dart and Flutter applications talk to Beckhoff/TwinCAT PLCs directly — reading and writing variables, subscribing to device notifications, browsing symbols, and issuing control actions — without any native/FFI dependency. It ships with a companion Dart CLI for interacting with PLCs from the terminal.

The C++ AdsLib (github.com/Beckhoff/ADS) is the reference implementation: its wire framing, protocol behavior, and API surface guide the Dart port, and a CMake-built C++ mock server derived from it drives the integration tests.

**Core Value:** A Dart application can reliably connect to a Beckhoff PLC and read, write, and subscribe to variables over ADS — with wire behavior verified byte-for-byte against the reference C++ implementation.

### Constraints

- **Tech stack**: Pure Dart on `dart:io` (raw sockets). No native/FFI dependencies in the library.
- **Platform**: Native Dart VM + Flutter desktop/mobile. No web.
- **Correctness**: Wire behavior must match the reference C++ AdsLib; the C++ mock server is the source of truth for integration tests.
- **Tooling**: C++ integration-test harness builds via CMake.
- **Packaging**: Standalone pure-Dart pub package (library + CLI), publishable to pub.dev.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Executive Guidance
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
### Development Tools (dev_dependencies)
| Tool | Version | Purpose | Notes |
|------|---------|---------|-------|
| `test` | ^1.31.0 | Unit + integration tests | The standard Dart test runner. Use `dart_test.yaml` + `@Tags(['integration'])` to separate fast codec unit tests from tests that spawn the C++ mock server. |
| `lints` | ^6.1.0 | Official Dart lint rules (`package:lints/recommended.yaml`) | Baseline for any pub.dev package. Enable `recommended` (stricter than `core`). See lint note below. |
| `coverage` | ^1.11.0 | `dart test --coverage` → LCOV | For CI coverage reporting (Codecov). |
| `dart format` (SDK) | — | Formatting | Enforced in CI (`dart format --output=none --set-exit-if-changed .`). |
| `dart analyze` (SDK) | — | Static analysis | CI gate: `dart analyze --fatal-infos`. |
## Package Layout
# Platform declaration excludes web (native-only):
## Binary / Wire-Protocol Handling (ADS is little-endian)
- Use **`ByteData.sublistView(uint8list)`** for zero-copy reading — do not copy into a `List<int>`.
- **Always pass `Endian.little` explicitly** on every `getX`/`setX`. ADS/AMS is little-endian on the wire; never rely on the host/default. Make a code-review rule of it.
- For encoding, allocate a `Uint8List` of the exact known frame size, wrap in `ByteData`, and `setUint16/32` fields by offset. AMS headers are fixed-layout, so sizes are computable up front.
- Model `AmsNetId` (6 bytes) and headers as small value classes with `toBytes()`/`fromBytes(ByteData, offset)` — keeps offset math localized and unit-testable.
- Use Dart **records/sealed classes** for command/response variants (e.g. a sealed `AdsResponse` with subtypes) to get exhaustive `switch` handling.
- Benchmark note (MEDIUM confidence, from community sources): `ByteData` accessors are the idiomatic and fast path; only drop to manual byte-shifting on `Uint8List` if profiling shows a hotspot. Don't prematurely optimize.
## Socket & Framing Strategy
## CLI Framework
- Global options (`--net-id`, `--host`, `--port 48898`, `--router`/`--direct`, `--timeout`) go on the runner's `argParser`; per-command options on each `Command`.
- `subscribe` is naturally a streaming command: bind the library's notification `Stream` to stdout and complete on SIGINT.
- Register `executables: { ads: ads }` in pubspec so `dart pub global activate dart_ads` yields an `ads` binary; also `dart compile exe bin/ads.dart` for a standalone native binary.
## Testing Stack
- **Unit** (`test/unit/`): pure codec/framing tests — build known byte vectors (ideally captured from the reference AdsLib) and assert encode/decode round-trips. Fast, no I/O, run everywhere.
- **Integration** (`test/integration/`): tagged `@Tags(['integration'])`, spawn the C++ mock server, exercise real socket round-trips.
- Build the server in a CI step (or a `tool/build_mock.sh`) via CMake, producing an executable under `tool/mock_server/build/`.
- In a Dart `setUpAll`, launch it with `Process.start(exePath, ['--port', '0' or fixed])`.
- **Port handshake:** prefer having the server bind an ephemeral port (`0`) and print the chosen port to stdout; the Dart harness reads the first stdout line to learn the port. This avoids flaky hard-coded ports and parallel-run collisions. If the server can't do ephemeral, pick a fixed high port and poll-connect with retry until it accepts.
- **Readiness:** don't assume the server is listening the instant `Process.start` returns. Either parse a "listening on N" stdout line or retry `Socket.connect` with a short backoff until success or timeout.
- **Lifecycle:** kill in `tearDownAll` (`process.kill(); await process.exitCode;`), and forward server stderr to test output for debugging. Guard against orphan processes on test failure.
- Keep server logs (stdout/stderr) piped and printed on failure — invaluable when a frame mismatch happens.
## CMake + C++ Mock Server (vendoring Beckhoff/ADS)
- Requires a **C++14** compiler.
- Upstream supports **Meson** (`meson setup build && ninja -C build`), **CMake** (`CMakeLists.txt`), and a plain **Makefile**. Since the project mandates CMake for the harness, use the provided `CMakeLists.txt`.
- AdsLib is a **client** library (AmsRouter, AdsDef, framing structs). It does **not** ship a ready-made server — you'll write a small mock server in C++ that **reuses AdsLib's frame structs / (de)serialization** (`AmsHeader`, `AoEHeader`, AMS/TCP header layouts) to produce byte-accurate responses. This is the intended use: reuse framing, hand-roll minimal server-side response logic for the commands under test.
- Add `github.com/Beckhoff/ADS` as a **git submodule** under `third_party/ADS/` (pin to a specific commit/tag for reproducibility). Submodule is cleaner than subtree here since you're not modifying upstream.
- Your `tool/mock_server/CMakeLists.txt` does `add_subdirectory(third_party/ADS)` (or references its lib target) and links the mock server target against the AdsLib target.
- Use a **recent CMake** (3.16+ is a safe modern floor; exact upstream minimum not verified — set your own `cmake_minimum_required(VERSION 3.16)`).
- CI: on the Linux integration job, `apt-get install cmake ninja-build g++`, `cmake -S tool/mock_server -B build -G Ninja`, `cmake --build build`.
## Lint / Format / CI Conventions
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
- The Dart-ported `AmsRouter` owns routing; you open the `Socket` to `<peer>:48898` yourself and assign local AMS Net ID.
- Because there's no local router, you handle AMS/TCP port-open handshake and route bookkeeping in Dart.
- Connect `Socket` to `127.0.0.1:48898` (the local router); the router handles onward routing.
- Transport abstraction should make direct-vs-router a strategy selected at runtime (as PROJECT requires) — a single `AdsTransport` interface with two implementations behind it.
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
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
