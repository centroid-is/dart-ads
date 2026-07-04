/// The `browse` verb: list/browse the PLC symbol table.
///
/// This plan (08-03) fills the `run()` body over `AdsClient.browseSymbols`,
/// reusing the shared connect→guarded backbone from 08-01. Default output is an
/// aligned table (name, type, size, group:offset, comment); `--filter <glob>`
/// narrows by a simple `*`/`?` glob and `--json` emits a machine-readable array.
library;

import 'dart:convert';

import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';

/// `ads browse` — browse/list PLC symbols.
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
        final results = argResults!;
        final filter = (results['filter'] as String?)?.trim();
        final asJson = results['json'] as bool;

        final session = await connectFromGlobals(globalResults!);
        try {
          var symbols = await session.client.browseSymbols();
          if (filter != null && filter.isNotEmpty) {
            final re = _globToRegExp(filter);
            symbols =
                symbols.where((s) => re.hasMatch(s.name)).toList(growable: false);
          }

          if (asJson) {
            print(jsonEncode(symbols.map(_symbolToJson).toList()));
          } else {
            _printTable(symbols);
          }
          return exitOk;
        } finally {
          await session.close();
        }
      });
}

/// The JSON shape for a single symbol (machine-readable `browse --json`).
Map<String, Object?> _symbolToJson(AdsSymbolInfo s) => <String, Object?>{
      'name': s.name,
      'type': s.typeName,
      'size': s.size,
      'indexGroup': s.indexGroup,
      'indexOffset': s.indexOffset,
      'comment': s.comment,
    };

/// Renders [symbols] as an aligned, human-readable table with a header row.
/// Right-pads each column to the widest cell (including the header) so the
/// columns line up regardless of symbol-name/type length.
void _printTable(List<AdsSymbolInfo> symbols) {
  const headers = <String>['NAME', 'TYPE', 'SIZE', 'GROUP:OFFSET', 'COMMENT'];
  final rows = <List<String>>[headers];
  for (final s in symbols) {
    rows.add(<String>[
      s.name,
      s.typeName,
      s.size.toString(),
      '0x${s.indexGroup.toRadixString(16)}:'
          '0x${s.indexOffset.toRadixString(16)}',
      s.comment,
    ]);
  }

  final widths = List<int>.filled(headers.length, 0);
  for (final row in rows) {
    for (var c = 0; c < row.length; c++) {
      if (row[c].length > widths[c]) widths[c] = row[c].length;
    }
  }

  for (final row in rows) {
    final sb = StringBuffer();
    for (var c = 0; c < row.length; c++) {
      // The last column (comment) needs no trailing padding.
      if (c == row.length - 1) {
        sb.write(row[c]);
      } else {
        sb
          ..write(row[c].padRight(widths[c]))
          ..write('  ');
      }
    }
    print(sb.toString().trimRight());
  }
}

/// Translates a simple `*`/`?` glob into a [RegExp] anchored to a full-string
/// match. `*` matches any run, `?` matches one character; every other regex
/// metacharacter is escaped so a glob like `MAIN.c*` matches literally on the
/// dot and only wildcards on `*`/`?`.
RegExp _globToRegExp(String glob) {
  final sb = StringBuffer('^');
  for (final unit in glob.split('')) {
    switch (unit) {
      case '*':
        sb.write('.*');
      case '?':
        sb.write('.');
      default:
        sb.write(RegExp.escape(unit));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString());
}
