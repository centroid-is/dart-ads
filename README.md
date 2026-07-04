# dart_ads

Pure-Dart client library for the Beckhoff ADS protocol (AMS/TCP), reimplementing
the open-source Beckhoff C++ AdsLib in Dart-only code. It lets Dart and Flutter
applications talk to Beckhoff/TwinCAT PLCs directly — reading and writing
variables, subscribing to device notifications, browsing symbols, and issuing
control actions — without any native/FFI dependency.

Wire behaviour is verified byte-for-byte against the reference C++ AdsLib via a
CMake-built C++ mock server that drives the integration tests.

## Installation

As a library dependency:

```yaml
# pubspec.yaml
dependencies:
  dart_ads: ^0.1.0
```

```console
$ dart pub add dart_ads
```

As the `ads` CLI (installs an `ads` binary into `~/.pub-cache/bin`, which must be
on your `PATH`):

```console
$ dart pub global activate dart_ads
$ ads --help
```

## Library quickstart

Connect in direct mode, read the PLC state, read a typed DINT by name, and stream
the first three on-change notifications. A complete runnable version lives in
[`example/example.dart`](example/example.dart).

```dart
import 'package:dart_ads/dart_ads.dart';

Future<void> main() async {
  // The embedded AmsRouter dials the PLC peer directly (no local TwinCAT router).
  // Set the source NetId before the first direct connect.
  final router = AmsRouter()
    ..setLocalAddress(AmsNetId.parse('192.168.0.100.1.1'));

  final plc = AmsNetId.parse('192.168.0.10.1.1');
  router.addRoute(plc, '192.168.0.10');

  final client = await router.connect(
    plc,
    AmsPort.plcTc3,
    mode: const DirectTarget('192.168.0.10'),
  );

  try {
    final state = await client.readState();
    print('ADS state: ${state.adsState}');

    final counter = await client.readDintByName('MAIN.counter');
    print('MAIN.counter = $counter');

    final handle = await client.getHandleByName('MAIN.counter');
    final stream = client.subscribe(
      indexGroup: AdsIndexGroup.symbolValueByHandle,
      indexOffset: handle,
      length: 4,
    );
    var seen = 0;
    await for (final sample in stream) {
      print('notification: ${sample.data}');
      if (++seen >= 3) break;
    }
    await client.releaseHandle(handle);
  } finally {
    await router.close();
  }
}
```

The library also offers `read` / `write` / `readWrite` by index-group/offset,
typed `read*ByName` / `write*ByName` helpers for every ADS scalar, symbol
`browseSymbols`, RAII `AdsHandle`, and batched `sumRead` / `sumWrite` /
`sumReadWrite`. See the public barrel `package:dart_ads/dart_ads.dart` for the
full surface.

## CLI usage

`ads` is a `CommandRunner` with global connection flags shared by every verb and
per-verb flags on each command.

**Global flags** (apply to every connection verb):

| Flag | Default | Meaning |
|------|---------|---------|
| `--host=<ip\|name>` | — | PLC/router host (required by connection verbs). |
| `--port=<int>` | `48898` | AMS/TCP port of the endpoint. |
| `--target=<AmsNetId>` | — | Target AMS NetId `a.b.c.d.e.f` (required). |
| `--ams-port=<int>` | `851` | Target AMS port (851 = TwinCAT 3 PLC runtime). |
| `--source=<AmsNetId>` | derived | Source AMS NetId (derived as `<ip>.1.1` in direct mode when `--host` is a dotted IPv4). |
| `--timeout=<ms>` | `5000` | Request + connect timeout in milliseconds. |
| `--mode=<direct\|router>` | `direct` | Dial the device directly, or delegate onward routing to a local TwinCAT router. |

**The seven verbs:**

| Verb | Purpose | Key flags |
|------|---------|-----------|
| `browse` | Browse/list PLC symbols. | `--filter=<glob>`, `--json` |
| `read` | Read a variable by name or index-group/offset. | `--name=<symbol>` \| `--group=<int> --offset=<int> --len=<int>`, `--type=<type>`, `--raw`, `--json` |
| `write` | Write a variable by name or index-group/offset. | `--name=<symbol>` \| `--group --offset`, `--type=<type> --value=<value>` \| `--raw=<hex>` |
| `subscribe` | Stream device notifications for a symbol until interrupted. | `--name=<symbol>` \| `--group --offset --len`, `--on-change`/`--cycle=<ms>`, `--max-delay=<ms>` |
| `pull` | Snapshot PLC symbols (and optionally values) to JSON. | `--values`, `--out=<file>`, `--filter=<glob>` |
| `push` | Apply values from a pull JSON file to the PLC. | `--in=<file>`, `--dry-run` |
| `action` | Issue a control action (set PLC state via WriteControl). | `--state=<state>` |

Run `ads help <verb>` for the full per-verb flag list. Example:

```console
$ ads --host 192.168.0.10 --target 192.168.0.10.1.1 read --name MAIN.counter --type DINT
$ ads --host 192.168.0.10 --target 192.168.0.10.1.1 subscribe --name MAIN.counter --on-change
```

`subscribe` streams until you interrupt it with Ctrl-C (clean SIGINT teardown).

## Transport modes

An `AmsRouter` reaches a PLC in one of two runtime-selectable modes — the six ADS
command calls are **identical** in both; only the `TransportTarget` differs:

```dart
final router = AmsRouter()
  ..setLocalAddress(AmsNetId.parse('192.168.0.100.1.1'));

// Direct: dial the device peer yourself (no local TwinCAT router needed).
router.addRoute(plcNetId, '192.168.0.10'); // register the target's host first
final client = await router.connect(
  plcNetId,
  AmsPort.plcTc3,
  mode: const DirectTarget('192.168.0.10'),
);

// Local router: delegate onward routing to an installed TwinCAT router.
final client2 = await router.connect(
  plcNetId,
  AmsPort.plcTc3,
  mode: const LocalRouterTarget(), // 127.0.0.1:48898 by default
);
```

### Direct mode requires a REVERSE route on the target PLC

In `DirectTarget` mode this library's embedded router stamps your source AMS
NetId onto every frame. The **target PLC must have a reverse ADS route back to
that source NetId** for its responses to reach you. Add it out-of-band:

- in the TwinCAT route configuration (System → Routes), or
- with `adstool addroute` from the Beckhoff ADS tools.

If the reverse route is missing, the PLC silently drops the response and the
request times out. Rather than surfacing a bare timeout, `connect()` raises an
actionable `AdsRoutingException` carrying ADS error `0x0745` (1861,
`ADSERR_CLIENT_SYNCTIMEOUT`) whose message names the source NetId and advises
adding the reverse route and checking the firewall / AMS port `48898`.

Programmatic reverse-route creation over UDP `:48899` is a v2 feature (ROUTE-04);
for now the reverse route is configured on the target.

In `LocalRouterTarget` mode the local router owns the route table, so no reverse
route is required and the router returns its own routing errors unchanged.

### LocalRouterTarget limitation: no `0x1000` port registration yet

A **real** TwinCAT router requires clients to register via the AMS/TCP `0x1000`
port-connect handshake (receiving a router-assigned local NetId + AMS port)
before it routes replies back. `LocalRouterTarget` does **not** perform that
handshake yet: it self-allocates a source port from this library's private
`30000+` range and stamps its own source NetId. The C++ mock used by the
integration tests accepts this (it echoes any source address), but an installed
TwinCAT router would drop the replies.

`LocalRouterTarget` is therefore **mock-verified only** today. The `0x1000`
registration is beyond AdsLib parity (the C++ AdsLib *is* its own router and
never dials one) and is deferred to v2; against real PLCs, use `DirectTarget`
with a reverse route.

## Limitations

- **`LocalRouterTarget` is mock-verified only** — the AMS/TCP `0x1000` router
  registration a real TwinCAT router requires is a v2 item. Against real PLCs,
  use `DirectTarget`.
- **Direct mode needs a reverse route** configured on the target PLC back to your
  source NetId (see [Direct mode requires a REVERSE route](#direct-mode-requires-a-reverse-route-on-the-target-plc)).
- **No web support.** ADS is raw TCP; `dart:html` has no socket access. This is a
  native VM + Flutter desktop/mobile package by design.

## Test parity with the reference C++ AdsLib

Wire behaviour is validated against the reference Beckhoff C++ AdsLib: a
CMake-built C++ mock server (reusing AdsLib's own framing) drives the integration
tests, and every applicable `AdsLibTest` / `AdsLibOOITest` scenario has a Dart
counterpart whose test `group(...)` is named after its C++ function. The full
scenario-by-scenario audit lives in [`PARITY.md`](PARITY.md).

Run the suite:

```console
$ dart test -x slow          # full suite, excluding the endurance soak
$ dart test --run-skipped -t slow   # the endurance soak on demand
```

## v2 roadmap

Deferred to a future release:

- **DTYPE-01 / DTYPE-02** — richer PLC data-type support (structured / array
  types beyond the current scalar codecs).
- **RECON-01** — automatic reconnection and subscription re-arming after a
  dropped connection.
- **RPC-01** — ADS method (RPC) invocation.
- **ROUTE-04** — programmatic reverse-route creation over UDP `:48899`.
- **NOTIF-05** — batched (sum) notifications.
- **TRACE-01** — wire-level frame tracing / diagnostics.

## License

MIT — see [LICENSE](LICENSE).
