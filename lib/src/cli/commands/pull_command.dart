/// The `pull` verb (CLI-05): snapshot symbols (and optionally values) to JSON.
///
/// `pull` browses the symbol table and, with `--values`, issues ONE `sumRead`
/// over every (filtered) symbol and attaches each value as lossless `0x`-hex.
/// The hex encoding is what makes the snapshot push-loadable byte-for-byte — the
/// project's lossless pull->push contract.
///
/// ## Snapshot JSON schema — `dart-ads/pull/1`
///
/// ```json
/// {
///   "schema": "dart-ads/pull/1",
///   "generatedAt": "<ISO-8601 UTC>",
///   "target": "<target AmsNetId>",
///   "symbols": [
///     {
///       "name": "MAIN.counter",
///       "type": "DINT",
///       "size": 4,
///       "indexGroup": 16416,
///       "indexOffset": 0,
///       "value": "0x2a000000",   // present only with --values, ok items
///       "ok": true,              // present only with --values
///       "error": 0               // present only with --values
///     }
///   ]
/// }
/// ```
///
/// `indexGroup`/`indexOffset`/`size`/`value` are exactly what `push` needs to
/// rebuild a `SumWriteRequest` per item, so a pull's output is a valid push
/// input. A per-item read failure carries `ok: false` + a non-zero `error` and
/// NO `value` key (a failed sumRead item emits zero data bytes, SUM-04).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';
import '../value_parsing.dart';

/// `ads pull` — snapshot PLC symbols (and optionally values) to a JSON file.
class PullCommand extends BaseAdsCommand {
  /// Declares the pull-specific flags.
  PullCommand() {
    argParser
      ..addFlag(
        'values',
        help: 'Include current values (batched via sumRead), not just symbols.',
        negatable: false,
      )
      ..addOption(
        'out',
        help: 'Write the JSON snapshot to this file (default: stdout).',
        valueHelp: 'file',
      )
      ..addOption(
        'filter',
        help: 'Only snapshot symbols whose name matches this glob.',
        valueHelp: 'glob',
      );
  }

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Snapshot PLC symbols (and optionally values) to JSON.';

  @override
  Future<int> run() => guarded(() async {
        final results = argResults!;
        final withValues = results['values'] as bool;
        final outPath = (results['out'] as String?)?.trim();
        final filter = (results['filter'] as String?)?.trim();
        final target = (globalResults!['target'] as String?)?.trim() ?? '';

        final session = await connectFromGlobals(globalResults!);
        try {
          var symbols = await session.client.browseSymbols();
          if (filter != null && filter.isNotEmpty) {
            final re = _globToRegExp(filter);
            symbols = symbols
                .where((s) => re.hasMatch(s.name))
                .toList(growable: false);
          }

          // Each symbol object starts as its metadata; --values overlays the
          // per-item hex value/ok/error from a SINGLE sumRead batch.
          final symbolJson = <Map<String, Object?>>[
            for (final s in symbols)
              <String, Object?>{
                'name': s.name,
                'type': s.typeName,
                'size': s.size,
                'indexGroup': s.indexGroup,
                'indexOffset': s.indexOffset,
              },
          ];

          if (withValues && symbols.isNotEmpty) {
            final items = <SumReadRequest>[
              for (final s in symbols)
                SumReadRequest(
                  indexGroup: s.indexGroup,
                  indexOffset: s.indexOffset,
                  length: s.size,
                ),
            ];
            final read = await session.client.sumRead(items);
            for (var i = 0; i < symbolJson.length; i++) {
              final item = read[i];
              symbolJson[i]['ok'] = item.isSuccess;
              symbolJson[i]['error'] = item.errorCode;
              if (item.isSuccess) {
                symbolJson[i]['value'] = formatHex(item.value!);
              }
            }
          }

          final doc = <String, Object?>{
            'schema': _schema,
            'generatedAt': DateTime.now().toUtc().toIso8601String(),
            'target': target,
            'symbols': symbolJson,
          };

          final text = const JsonEncoder.withIndent('  ').convert(doc);
          if (outPath != null && outPath.isNotEmpty) {
            File(outPath).writeAsStringSync('$text\n');
          } else {
            print(text);
          }
          return exitOk;
        } finally {
          await session.close();
        }
      });
}

/// The snapshot schema tag written into (and validated by push against) the
/// snapshot header.
const String _schema = 'dart-ads/pull/1';

/// Translates a simple `*`/`?` glob into a full-string-anchored [RegExp],
/// mirroring `browse`'s glob rule so `--filter` behaves identically.
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
