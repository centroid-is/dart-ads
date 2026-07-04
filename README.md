# dart_ads

Pure-Dart client library for the Beckhoff ADS protocol (AMS/TCP), reimplementing
the open-source Beckhoff C++ AdsLib in Dart-only code. It lets Dart and Flutter
applications talk to Beckhoff/TwinCAT PLCs directly — reading and writing
variables, subscribing to device notifications, browsing symbols, and issuing
control actions — without any native/FFI dependency.

Wire behaviour is verified byte-for-byte against the reference C++ AdsLib via a
CMake-built C++ mock server that drives the integration tests.

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
