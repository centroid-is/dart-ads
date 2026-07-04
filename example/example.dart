// A minimal end-to-end tour of the dart_ads library: connect to a Beckhoff PLC
// in direct mode, read the ADS state, read a typed DINT symbol by name, and
// stream the first three device notifications before closing cleanly.
//
// It imports ONLY the public barrel (`package:dart_ads/dart_ads.dart`) — never
// anything under `src/` — so it exercises exactly the surface a consumer sees.
//
// The endpoints below are placeholders; substitute your PLC's AMS NetId and
// host. Direct mode requires a REVERSE ADS route on the target PLC back to this
// source NetId (configure it in the TwinCAT route table) or the PLC silently
// drops every reply.
import 'dart:async';

import 'package:dart_ads/dart_ads.dart';

Future<void> main() async {
  // The embedded AmsRouter stamps our source NetId onto every frame and dials
  // the PLC peer directly — no local TwinCAT router required. Set the local
  // address before the first direct connect (direct mode cannot auto-derive it).
  final router = AmsRouter()
    ..setLocalAddress(AmsNetId.parse('192.168.0.100.1.1'));

  // Register the target's host, then dial it in direct mode. In DirectTarget
  // mode the route table is the routing authority, so the host must agree with
  // the DirectTarget endpoint below.
  final plcNetId = AmsNetId.parse('192.168.0.10.1.1');
  router.addRoute(plcNetId, '192.168.0.10');

  final client = await router.connect(
    plcNetId,
    AmsPort.plcTc3,
    mode: const DirectTarget('192.168.0.10'),
  );

  try {
    // 1) Read the PLC's ADS run-state (RUN / STOP / CONFIG / ...).
    final state = await client.readState();
    print('ADS state: ${state.adsState} (device state ${state.deviceState})');

    // 2) Read a typed DINT (32-bit signed) variable by symbol name.
    final counter = await client.readDintByName('MAIN.counter');
    print('MAIN.counter = $counter');

    // 3) Subscribe to on-change notifications for that symbol and print the
    //    first three samples, then stop. Resolve the symbol to a handle and
    //    subscribe on the symbol-value-by-handle index group.
    final handle = await client.getHandleByName('MAIN.counter');
    try {
      final stream = client.subscribe(
        indexGroup: AdsIndexGroup.symbolValueByHandle,
        indexOffset: handle,
        length: 4, // a DINT is 4 bytes
        mode: AdsTransmissionMode.serverOnChange,
      );

      var received = 0;
      await for (final AdsNotification sample in stream) {
        print('notification: ${sample.data}');
        if (++received >= 3) break; // cancels the subscription (onCancel)
      }
    } finally {
      await client.releaseHandle(handle);
    }
  } finally {
    // Tears down the connection this router dialed and frees its source port.
    await router.close();
  }
}
