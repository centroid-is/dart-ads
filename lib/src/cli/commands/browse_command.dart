/// The `browse` verb (stub): list/browse the PLC symbol table.
///
/// This plan (08-01) defines the command shape — name, description, flags, and
/// the shared connect→guarded backbone — so `--help` is accurate and the
/// exit-code contract holds now. The real browse body lands in a later Phase 8
/// plan, which replaces ONLY this `run()` body (never the runner).
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads browse` — browse/list PLC symbols (stub).
class BrowseCommand extends BaseAdsCommand {
  /// Declares the browse-specific flags.
  BrowseCommand() {
    argParser
      ..addOption(
        'filter',
        help: 'Only list symbols whose name matches this glob.',
        valueHelp: 'glob',
      )
      ..addFlag(
        'json',
        help: 'Emit JSON instead of a table (for piping).',
        negatable: false,
      );
  }

  @override
  String get name => 'browse';

  @override
  String get description => 'Browse/list PLC symbols.';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('browse lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
