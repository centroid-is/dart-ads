/// The `action` verb (CLI-07): issue a control action — set the PLC's ADS run
/// state via WriteControl, selected by a case-insensitive `--state <name>` mapped
/// through the [AdsState] enum, printing the old → new state for confirmation.
///
/// This plan (08-07) fills the `run()` body over the shared connect→guarded
/// backbone (08-01). The name is matched against [AdsState.values] `.name`
/// case-insensitively; an unmatched name is a [UsageException] (→ exit 2) listing
/// the valid names, NEVER a silent [AdsState.unknown] no-op (threat T-8-10). RPC
/// / method-call invocation is explicitly DEFERRED to v2 (RPC-01) and is not
/// implemented here.
library;

import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';

/// `ads action` — issue a control action / state change via WriteControl.
class ActionCommand extends BaseAdsCommand {
  /// Declares the action-specific flags.
  ActionCommand() {
    argParser.addOption(
      'state',
      help: 'Target ADS state (RUN|STOP|CONFIG|...), case-insensitive.',
      valueHelp: 'state',
    );
  }

  @override
  String get name => 'action';

  @override
  String get description =>
      'Issue a control action (set PLC state via WriteControl).';

  @override
  Future<int> run() => guarded(() async {
        final stateOpt = (argResults!['state'] as String?)?.trim();
        if (stateOpt == null || stateOpt.isEmpty) {
          throw UsageException(
            'action needs --state <name> (${_validNames()})',
            '',
          );
        }

        // Map the operator's name to an AdsState case-insensitively against the
        // enum's own member names — never AdsState.unknown, which is a tolerant
        // wire-decode sentinel, not an operator-selectable target.
        final wanted = stateOpt.toLowerCase();
        final target = AdsState.values.firstWhere(
          (s) => s != AdsState.unknown && s.name.toLowerCase() == wanted,
          orElse: () => throw UsageException(
            'unknown --state "$stateOpt"; valid: ${_validNames()}',
            '',
          ),
        );

        final session = await connectFromGlobals(globalResults!);
        try {
          final client = session.client;
          // Read old state, apply the transition, read new state — all within
          // this one connection so the mock's connection-scoped WriteControl is
          // observable as old → new.
          final before = await client.readState();
          await client.writeControl(adsState: target);
          final after = await client.readState();

          print('${before.adsState.name} -> ${after.adsState.name}');
          return exitOk;
        } finally {
          await session.close();
        }
      });

  /// The operator-selectable state names (every [AdsState] except the tolerant
  /// [AdsState.unknown] decode sentinel), for usage messages.
  static String _validNames() => AdsState.values
      .where((s) => s != AdsState.unknown)
      .map((s) => s.name)
      .join('|');
}
