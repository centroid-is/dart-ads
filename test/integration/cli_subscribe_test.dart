@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/mock_server.dart';

/// End-to-end proof of the `subscribe` verb (CLI-04) driven as a SUBPROCESS
/// against the C++ mock — the only way to observe the real streaming lifecycle
/// AND the process exit code the shell sees when the operator presses Ctrl-C.
///
/// This is the single most leak-prone CLI path: a dropped SIGINT teardown
/// orphans a PLC notification handle (threat T-8-03). The case below proves the
/// full chain — subscribe, receive a timestamped sample, SIGINT, and a CLEAN
/// exit 0 with the handle-release teardown marker.
///
/// TRIGGER (why `--notify-burst`, not a cross-connection Write):
/// the mock's write-triggered serverOnChange emission fans out ONLY to handles
/// registered on the SAME connection as the writer (its `notes` table is
/// per-connection). The subscribe subprocess is its own process/connection and
/// the `subscribe` verb never writes, so no external Write (library or a second
/// CLI) can reach its notification table. `--notify-burst 1` instead makes the
/// mock emit ONE frame for the new handle immediately after the Add response, on
/// the subscriber's own connection — the deterministic same-connection trigger
/// (mirrors test/integration/ads_notification_test.dart's first-listen case).
///
/// LEAK ASSERTION (connection-scope limitation, for the Phase 9 audit):
/// because `notes` is per-connection and dies with the connection, a FRESH
/// connection reading the active-handle-count magic group (0xE7700002) observes
/// only its OWN empty table — always 0 — so it cannot prove THIS process
/// released its handle. The documented fallback is therefore used: assert the
/// subscriber exits 0 after SIGINT AND emits its handle-release teardown marker.
/// The same-connection zero-handle proof (activeHandleCount == 0 after cancel)
/// is covered at library level in ads_notification_test.dart, and the CLI's
/// SIGINT path drives that exact `StreamSubscription.cancel()` teardown.
void main() {
  late MockServer server;

  setUpAll(() async {
    // --notify-burst 1: emit ONE notification frame per AddDeviceNotification on
    // the registering connection, so the subscribe subprocess receives a sample
    // without any (impossible cross-connection) Write trigger.
    server = await startMockServer(args: <String>['--notify-burst', '1']);
  });
  tearDownAll(() async {
    await server.stop();
  });

  test(
    'subscribe streams a timestamped sample, then SIGINT tears the handle '
    'down cleanly (exit 0 + release marker)',
    () async {
      final proc = await Process.start('dart', <String>[
        'run',
        'bin/ads.dart',
        '--host',
        '127.0.0.1',
        '--port',
        '${server.port}',
        '--target',
        '192.168.0.1.1.1',
        '--mode',
        'direct',
        'subscribe',
        // Raw group/offset path (the mock's MAIN.flag watched region): no
        // browseSymbols round-trip, so the ONLY Add is the subscription itself.
        '--group',
        '0x4020',
        '--offset',
        '4',
        '--len',
        '1',
      ]);

      final stdoutLines = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final stderrBuf = StringBuffer();
      proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

      // Wait (bounded) for the first non-empty streamed line: `dart run` pays a
      // cold compile before the program prints, hence the generous ceiling.
      final firstLine =
          await stdoutLines.firstWhere((l) => l.trim().isNotEmpty).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return '';
        },
      );

      expect(firstLine.trim(), isNotEmpty,
          reason: 'subscribe never streamed a notification line; '
              'stderr: $stderrBuf');

      // The line is `<ISO8601 timestamp>  <0x-hex value>`.
      final parts = firstLine.trim().split(RegExp(r'\s+'));
      expect(parts, hasLength(2),
          reason: 'a sample line is a timestamp and a hex value: "$firstLine"');
      final ts =
          DateTime.parse(parts[0]); // throws -> test failure if not ISO8601
      expect(ts.isUtc, isTrue,
          reason: 'the FILETIME sample stamp renders as a UTC ISO8601 instant');
      expect(parts[1], startsWith('0x'),
          reason: 'the value is 0x-prefixed hex: "${parts[1]}"');

      // Ctrl-C: the verb's SIGINT handler cancels the subscription
      // (DeleteDeviceNotification) and closes the session, then exits 0.
      proc.kill(ProcessSignal.sigint);

      final code = await proc.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      expect(code, 0,
          reason: 'SIGINT must drive a CLEAN exit 0 via the teardown handler, '
              'never a default-terminate; stderr: $stderrBuf');
      expect(stderrBuf.toString(), contains('notification handle released'),
          reason: 'the teardown marker proves the handle-release path ran on '
              'SIGINT (the no-leak property; see connection-scope note above)');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
