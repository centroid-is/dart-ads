/// The `read` verb (stub): read a variable by name or by index-group/offset.
///
/// Shape only in 08-01 (name/description/flags + the connect→guarded backbone);
/// the real read body lands in a later Phase 8 plan that replaces ONLY this
/// `run()`. The `--group/--offset/--len` raw path needs no symbol lookup, which
/// is why the exit-code contract test drives this verb.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads read` — read a variable (stub).
class ReadCommand extends BaseAdsCommand {
  /// Declares the read-specific flags (name path and raw group/offset path).
  ReadCommand() {
    argParser
      ..addOption(
        'name',
        help: 'Symbol name to read (typed via its symbol type when resolvable).',
        valueHelp: 'symbol',
      )
      ..addOption(
        'group',
        help: 'Index group for a raw read (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'offset',
        help: 'Index offset for a raw read (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'len',
        help: 'Byte length for a raw read.',
        valueHelp: 'int',
      )
      ..addOption(
        'type',
        help: 'Force a typed decode (bool|int16|dint|real|lreal|string|...).',
        valueHelp: 'type',
      )
      ..addFlag(
        'raw',
        help: 'Force raw hex output (skip typed decode).',
        negatable: false,
      )
      ..addFlag(
        'json',
        help: 'Emit JSON instead of a plain value.',
        negatable: false,
      );
  }

  @override
  String get name => 'read';

  @override
  String get description => 'Read a variable (by name or index-group/offset).';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('read lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
