/// The `subscribe` verb (CLI-04): stream device notifications for a symbol.
///
/// Opens a device-notification `Stream` for a symbol (by `--name`) or a raw
/// `(group, offset, len)` triple, prints each sample as a timestamped line
/// (ISO8601 + hex) until the operator interrupts with Ctrl-C, then tears the
/// notification handle down cleanly on SIGINT so the PLC never leaks a handle
/// (the CONTEXT's headline correctness property, threat T-8-03).
///
/// A single idempotent teardown closure runs on EVERY exit path — signal
/// (SIGINT/SIGTERM), stream `done`, or stream error — cancelling the
/// subscription (which fires DeleteDeviceNotification via the library's
/// Always-Delete onCancel) and awaiting the session's idempotent `close()`
/// (which also invalidates handles at the router). The session + subscription
/// are fully-built locals the signal handlers close over (snapshot-before-await):
/// handlers are installed only AFTER the subscription exists, so a signal can
/// never race a half-built session.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';
import '../value_parsing.dart';

/// `ads subscribe` — stream device notifications until interrupted.
class SubscribeCommand extends BaseAdsCommand {
  /// Declares the subscribe-specific flags (target + transmission mode).
  SubscribeCommand() {
    argParser
      ..addOption(
        'name',
        help: 'Symbol name to subscribe to.',
        valueHelp: 'symbol',
      )
      ..addOption(
        'group',
        help: 'Index group for a raw subscription (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'offset',
        help: 'Index offset for a raw subscription (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'len',
        help: 'Byte length for a raw subscription.',
        valueHelp: 'int',
      )
      ..addFlag(
        'on-change',
        help: 'Notify only when the value changes (default).',
        defaultsTo: true,
      )
      ..addOption(
        'cycle',
        help: 'Server cycle time in milliseconds (selects cyclic mode).',
        valueHelp: 'ms',
      )
      ..addOption(
        'max-delay',
        help: 'Maximum delay before a notification is delivered (ms).',
        valueHelp: 'ms',
      );
  }

  @override
  String get name => 'subscribe';

  @override
  String get description =>
      'Stream device notifications for a symbol until interrupted.';

  @override
  Future<int> run() => guarded(() async {
        final r = argResults!;
        final nameOpt = (r['name'] as String?)?.trim();
        final groupOpt = (r['group'] as String?)?.trim();
        final offsetOpt = (r['offset'] as String?)?.trim();
        final lenOpt = (r['len'] as String?)?.trim();
        final cycleOpt = (r['cycle'] as String?)?.trim();
        final maxDelayOpt = (r['max-delay'] as String?)?.trim();

        final hasName = nameOpt != null && nameOpt.isNotEmpty;
        final hasGroup = groupOpt != null && groupOpt.isNotEmpty;
        final hasOffset = offsetOpt != null && offsetOpt.isNotEmpty;
        final hasRawPath = hasGroup || hasOffset;

        if (hasName && hasRawPath) {
          throw UsageException(
            '--name and --group/--offset are mutually exclusive',
            '',
          );
        }
        if (!hasName && !hasRawPath) {
          throw UsageException(
            'subscribe needs either --name <symbol> or --group/--offset <int>',
            '',
          );
        }

        // Transmission mode: --cycle selects serverCycle (with the given cycle
        // time); otherwise serverOnChange (the --on-change default). --max-delay
        // applies to both.
        final AdsTransmissionMode mode;
        var cycleTime = Duration.zero;
        if (cycleOpt != null && cycleOpt.isNotEmpty) {
          mode = AdsTransmissionMode.serverCycle;
          cycleTime = Duration(milliseconds: _parseAnyInt(cycleOpt, 'cycle'));
        } else {
          mode = AdsTransmissionMode.serverOnChange;
        }
        final maxDelay = (maxDelayOpt != null && maxDelayOpt.isNotEmpty)
            ? Duration(milliseconds: _parseAnyInt(maxDelayOpt, 'max-delay'))
            : Duration.zero;

        final session = await connectFromGlobals(globalResults!);

        // Single idempotent teardown, run on EVERY exit path (signal, done,
        // error). It cancels the subscription (-> DeleteDeviceNotification),
        // closes the session (idempotent; invalidates handles at the router),
        // and detaches the signal watchers so the isolate can exit.
        var tornDown = false;
        StreamSubscription<AdsNotification>? sub;
        var signals = <StreamSubscription<ProcessSignal>>[];
        final done = Completer<int>();

        Future<void> teardown() async {
          if (tornDown) return;
          tornDown = true;
          for (final s in signals) {
            await s.cancel();
          }
          final hadSubscription = sub != null;
          await sub?.cancel(); // fires DeleteDeviceNotification (Always-Delete)
          await session.close(); // idempotent
          if (hadSubscription) {
            // Observable teardown marker: proves the handle-release path ran on
            // this exit (the CONTEXT's headline no-leak property). The mock's
            // notification table is connection-scoped, so a fresh connection
            // cannot observe THIS process's post-teardown handle count — this
            // marker is the connection-local evidence the integration test
            // asserts on (the library's same-connection zero-handle proof lives
            // in test/integration/ads_notification_test.dart).
            stderr.writeln('subscribe: notification handle released, '
                'session closed');
          }
          if (!done.isCompleted) done.complete(exitOk);
        }

        try {
          // Resolve the target region: by-name via the symbol table, or the
          // explicit raw group/offset/len triple.
          final int group;
          final int offset;
          final int length;
          if (hasName) {
            final sym = await _resolveOrRaise(session.client, nameOpt);
            group = sym.indexGroup;
            offset = sym.indexOffset;
            length = sym.size;
          } else {
            if (!hasGroup || !hasOffset) {
              throw UsageException(
                'a raw subscription needs both --group and --offset',
                '',
              );
            }
            if (lenOpt == null || lenOpt.isEmpty) {
              throw UsageException(
                'a raw --group/--offset subscription needs --len <bytes>',
                '',
              );
            }
            group = _parseAnyInt(groupOpt, 'group');
            offset = _parseAnyInt(offsetOpt, 'offset');
            length = _parseAnyInt(lenOpt, 'len');
          }

          final stream = session.client.subscribe(
            indexGroup: group,
            indexOffset: offset,
            length: length,
            mode: mode,
            cycleTime: cycleTime,
            maxDelay: maxDelay,
          );

          // Assign `sub` synchronously so the teardown closure (and the signal
          // handlers installed just below) always see a fully-built local.
          sub = stream.listen(
            (n) {
              stdout.writeln(
                '${n.timestamp.toIso8601String()}  ${formatHex(n.data)}',
              );
            },
            onError: (Object e, StackTrace st) {
              // A stream error (e.g. Add refusal, connection drop) fails the run
              // with the mapped exit code; teardown still releases everything.
              if (!done.isCompleted) done.completeError(e, st);
              unawaited(teardown());
            },
            onDone: () => unawaited(teardown()),
            cancelOnError: true,
          );

          // Snapshot-before-await: the session + subscription are built, so a
          // signal now drives the SAME idempotent teardown, never a half-built
          // session. Ctrl-C (SIGINT) is the operator path; SIGTERM lets the
          // integration test drive the same clean teardown.
          signals = <StreamSubscription<ProcessSignal>>[
            ProcessSignal.sigint.watch().listen((_) => unawaited(teardown())),
            ProcessSignal.sigterm.watch().listen((_) => unawaited(teardown())),
          ];

          return await done.future;
        } finally {
          // Belt-and-suspenders: guarantees the handle is released even if the
          // body threw before wiring the stream/signals.
          await teardown();
        }
      });
}

/// Resolves symbol [name] to its [AdsSymbolInfo] via `browseSymbols`. When the
/// symbol is absent, forces the device's own ADS error (unknown symbol → exit 1
/// with a human-readable name) by attempting a handle-by-name, rather than
/// leaking a generic lookup failure. Mirrors the `read` verb's resolver.
Future<AdsSymbolInfo> _resolveOrRaise(AdsClient client, String name) async {
  final symbols = await client.browseSymbols();
  for (final s in symbols) {
    if (s.name == name) return s;
  }
  // Not in the table: let the device raise its ADS error for the unknown name.
  await client.getHandleByName(name);
  // getHandleByName should have thrown; guard against a surprise success.
  throw FormatException('symbol "$name" not found');
}

/// Parses an operator-supplied integer, accepting an optional `0x`/`0X` hex
/// prefix, else decimal. A non-integer throws [FormatException] (→ exit 2).
int _parseAnyInt(String raw, String flag) {
  final s = raw.trim();
  final int? value;
  if (s.length >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    value = int.tryParse(s.substring(2), radix: 16);
  } else {
    value = int.tryParse(s);
  }
  if (value == null) {
    throw FormatException(
        '--$flag must be an integer (decimal or 0x hex)', raw);
  }
  return value;
}
