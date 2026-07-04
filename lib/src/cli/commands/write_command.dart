/// The `write` verb (stub): write a variable by name or by index-group/offset.
///
/// Shape only in 08-01; the real write body lands in a later Phase 8 plan that
/// replaces ONLY this `run()`.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads write` — write a variable (stub).
class WriteCommand extends BaseAdsCommand {
  /// Declares the write-specific flags (name path and raw group/offset path).
  WriteCommand() {
    argParser
      ..addOption(
        'name',
        help:
            'Symbol name to write (typed via its symbol type when resolvable).',
        valueHelp: 'symbol',
      )
      ..addOption(
        'group',
        help: 'Index group for a raw write (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'offset',
        help: 'Index offset for a raw write (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'type',
        help: 'Interpret --value with this type (bool|int16|dint|real|...).',
        valueHelp: 'type',
      )
      ..addOption(
        'value',
        help: 'The value to write, parsed per --type (or the symbol type).',
        valueHelp: 'value',
      )
      ..addOption(
        'raw',
        help: 'Write these raw hex bytes verbatim.',
        valueHelp: 'hex',
      );
  }

  @override
  String get name => 'write';

  @override
  String get description => 'Write a variable (by name or index-group/offset).';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('write lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
