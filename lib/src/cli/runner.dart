/// The `ads` CLI backbone: an [AdsCliRunner] (`package:args`
/// [CommandRunner]) that declares the connection flags EVERY verb shares and
/// registers the seven ADS verbs (CLI-08).
///
/// The global connection flags live on the runner's [argParser] (not on each
/// command) so `--host/--port/--target/--ams-port/--source/--timeout/--mode`
/// mean the same thing for every verb and a command reads them via
/// `globalResults`. Per-verb flags live on each [Command]'s own parser.
///
/// `dart:io` is intentionally NOT imported here — the runner only wires
/// argument parsing and command registration; process-exit and I/O live in
/// `bin/ads.dart` and the individual commands.
library;

import 'package:args/command_runner.dart';

import 'commands/action_command.dart';
import 'commands/browse_command.dart';
import 'commands/pull_command.dart';
import 'commands/push_command.dart';
import 'commands/read_command.dart';
import 'commands/subscribe_command.dart';
import 'commands/write_command.dart';

/// The `ads` command runner: shared connection flags + the seven verbs.
///
/// Returns an `int` process exit code from `run(args)` (mapped by each verb's
/// `guarded(...)`); a thrown [UsageException] (unknown command/flag/value) is
/// translated to exit code `2` by `bin/ads.dart`.
class AdsCliRunner extends CommandRunner<int> {
  /// Builds the runner, declares the global connection flags, and registers all
  /// seven verb commands.
  AdsCliRunner()
      : super(
          'ads',
          'Talk to a Beckhoff/TwinCAT PLC over ADS (AMS/TCP) from the '
              'terminal.',
        ) {
    argParser
      // NOTE: no `abbr: 'h'` on --host — CommandRunner already owns `-h` for
      // --help, so an `h` abbreviation would collide at construction.
      ..addOption(
        'host',
        help: 'PLC/router host (IP or resolvable name). Required by every '
            'connection verb.',
        valueHelp: 'ip|name',
      )
      ..addOption(
        'port',
        help: 'AMS/TCP port of the endpoint.',
        valueHelp: 'int',
        defaultsTo: '48898',
      )
      ..addOption(
        'target',
        help: 'Target AMS NetId (a.b.c.d.e.f). Required by every connection '
            'verb.',
        valueHelp: 'AmsNetId',
      )
      ..addOption(
        'ams-port',
        help: 'Target AMS port (851 = TwinCAT 3 PLC runtime).',
        valueHelp: 'int',
        defaultsTo: '851',
      )
      ..addOption(
        'source',
        help: 'Source AMS NetId. Optional in direct mode when --host is a '
            'dotted IPv4 (a <ip>.1.1 source is derived); otherwise required '
            'in direct mode.',
        valueHelp: 'AmsNetId',
      )
      ..addOption(
        'timeout',
        help: 'Request + connect timeout in milliseconds.',
        valueHelp: 'ms',
        defaultsTo: '5000',
      )
      ..addOption(
        'mode',
        help: 'Transport mode: dial the device directly, or delegate onward '
            'routing to a local TwinCAT router.',
        allowed: <String>['direct', 'router'],
        defaultsTo: 'direct',
      );

    addCommand(BrowseCommand());
    addCommand(ReadCommand());
    addCommand(WriteCommand());
    addCommand(SubscribeCommand());
    addCommand(PullCommand());
    addCommand(PushCommand());
    addCommand(ActionCommand());
  }
}
