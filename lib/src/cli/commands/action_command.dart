/// The `action` verb (stub): issue a control action (WriteControl state change).
///
/// Shape only in 08-01; the real body (WriteControl with a case-insensitive
/// AdsState name, printing old → new state) lands in a later Phase 8 plan that
/// replaces ONLY this `run()`.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads action` — issue a control action / state change (stub).
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
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('action lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
