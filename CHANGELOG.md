# Changelog

## 0.1.0

Initial release: a pure-Dart Beckhoff ADS (AMS/TCP) client, wire-compatible with
the reference C++ AdsLib and validated byte-for-byte against a CMake-built C++
mock server.

### Library

- AMS/TCP framing (AMS/TCP + AMS headers) and a streaming frame reassembler.
- The six core ADS commands: Read, Write, ReadWrite, ReadState, WriteControl,
  ReadDeviceInfo — with both-level ADS error mapping (`AdsException`).
- Device notifications exposed as `Stream<AdsNotification>` with full handle
  lifecycle (subscribe / cancel / disconnect).
- Symbol access by name, symbol browse, typed scalar codecs, and RAII-style
  `AdsHandle`.
- Sum (batched) read / write / read-write commands with per-item results and
  partial-failure alignment.
- `AmsRouter` with a local-port allocator, route table, source-NetId stamping,
  and runtime-selectable `DirectTarget` / `LocalRouterTarget` transport modes.

### CLI

- The `ads` command with seven verbs: `browse`, `read`, `write`, `subscribe`,
  `pull`, `push`, `action`.

### Known limitations

- `LocalRouterTarget` is mock-verified only; the AMS/TCP `0x1000` port
  registration a real TwinCAT router requires is a v2 item.
- Direct mode needs a reverse ADS route configured on the target PLC.
- No web support (ADS is raw TCP).
