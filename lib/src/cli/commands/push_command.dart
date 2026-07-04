/// The `push` verb (CLI-06): apply values from a pull JSON snapshot to the PLC.
///
/// `push` reads a `dart-ads/pull/1` snapshot (see [PullCommand]), rebuilds one
/// `SumWriteRequest` per item from its `indexGroup`/`indexOffset` + `0x`-hex
/// `value`, and issues ONE `sumWrite`. `--dry-run` lists the intended writes and
/// touches NOTHING on the wire. Otherwise it prints a per-item pass/fail report
/// and exits non-zero if ANY item failed.
///
/// ## Untrusted snapshot file (threat T-8-02 / T-8-09)
///
/// The `--in` file is untrusted (hand-edited, possibly hostile). Parsing runs
/// inside [guarded], so a malformed/typewrong/oversized snapshot throws
/// [FormatException] -> exit `2`, NEVER a crash:
///   * `jsonDecode` failure (bad JSON) -> FormatException;
///   * wrong `schema`, non-list `symbols`, a missing/typewrong item field, a
///     non-hex `value`, or a value longer than the item's declared `size` ->
///     FormatException;
///   * the item count is capped at [_maxItems] so a hostile huge array cannot
///     drive an unbounded allocation or an oversized single round-trip.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';
import '../value_parsing.dart';

/// The snapshot schema this verb accepts (must match [PullCommand]'s writer).
const String _schema = 'dart-ads/pull/1';

/// Ceiling on snapshot item count — a hostile file cannot force an unbounded
/// allocation or an oversized single sumWrite round-trip (threat T-8-09). Far
/// above any realistic symbol table.
const int _maxItems = 100000;

/// One decoded, validated write intent parsed from a snapshot item.
class _PushItem {
  const _PushItem(this.name, this.indexGroup, this.indexOffset, this.data);

  final String name;
  final int indexGroup;
  final int indexOffset;
  final Uint8List data;
}

/// `ads push` — apply values from a pull JSON snapshot to the PLC.
class PushCommand extends BaseAdsCommand {
  /// Declares the push-specific flags.
  PushCommand() {
    argParser
      ..addOption(
        'in',
        help: 'Read the values-to-apply from this pull JSON file.',
        valueHelp: 'file',
      )
      ..addFlag(
        'dry-run',
        help: 'List the intended writes without applying them.',
        negatable: false,
      );
  }

  @override
  String get name => 'push';

  @override
  String get description => 'Apply values from a pull JSON file to the PLC.';

  @override
  Future<int> run() => guarded(() async {
        final results = argResults!;
        final inPath = (results['in'] as String?)?.trim();
        final dryRun = results['dry-run'] as bool;

        if (inPath == null || inPath.isEmpty) {
          throw const FormatException('missing required --in <snapshot.json>');
        }

        // Parse + validate the untrusted file BEFORE any connect. A bad file
        // must exit 2 without dialing the PLC (threat T-8-02).
        final items = _parseSnapshot(File(inPath).readAsStringSync());

        // --dry-run: list intended writes, touch nothing on the wire.
        if (dryRun) {
          if (items.isEmpty) {
            print('push --dry-run: snapshot has no writable items');
          } else {
            print('push --dry-run: ${items.length} intended write(s):');
            for (final it in items) {
              print('  ${it.name} '
                  '0x${it.indexGroup.toRadixString(16)}:'
                  '0x${it.indexOffset.toRadixString(16)} '
                  '<- ${formatHex(it.data)}');
            }
          }
          return exitOk;
        }

        if (items.isEmpty) {
          print('push: snapshot has no writable items');
          return exitOk;
        }

        final session = await connectFromGlobals(globalResults!);
        try {
          final requests = <SumWriteRequest>[
            for (final it in items)
              SumWriteRequest(
                indexGroup: it.indexGroup,
                indexOffset: it.indexOffset,
                data: it.data,
              ),
          ];
          final report = await session.client.sumWrite(requests);

          var failures = 0;
          for (var i = 0; i < items.length; i++) {
            final r = report[i];
            if (r.isSuccess) {
              print('  OK    ${items[i].name}');
            } else {
              failures++;
              print('  FAIL  ${items[i].name} '
                  '0x${r.errorCode.toRadixString(16)} '
                  '${adsErrorName(r.errorCode)}');
            }
          }
          print('push: ${items.length - failures}/${items.length} applied');
          // Any failed item -> non-zero, so a partial failure is never silent.
          return failures == 0 ? exitOk : exitAdsError;
        } finally {
          await session.close();
        }
      });
}

/// Parses + validates an untrusted snapshot string into write intents.
///
/// Throws [FormatException] (-> exit 2) on any malformed/hostile shape: bad
/// JSON, wrong `schema`, non-list `symbols`, an over-[_maxItems] array, a
/// missing/typewrong item field, a non-hex `value`, or a value longer than the
/// item's declared `size`. Items with no `value` (a symbols-only pull, or a
/// failed read item) are skipped — there is nothing to write.
List<_PushItem> _parseSnapshot(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw FormatException('snapshot is not valid JSON: ${e.message}');
  }

  if (decoded is! Map) {
    throw const FormatException('snapshot root must be a JSON object');
  }
  if (decoded['schema'] != _schema) {
    throw FormatException(
        'snapshot schema must be "$_schema", got "${decoded['schema']}"');
  }
  final rawSymbols = decoded['symbols'];
  if (rawSymbols is! List) {
    throw const FormatException('snapshot "symbols" must be a list');
  }
  if (rawSymbols.length > _maxItems) {
    throw FormatException(
        'snapshot has ${rawSymbols.length} items, exceeding the $_maxItems cap');
  }

  final out = <_PushItem>[];
  for (var i = 0; i < rawSymbols.length; i++) {
    final entry = rawSymbols[i];
    if (entry is! Map) {
      throw FormatException('snapshot symbols[$i] must be an object');
    }
    final rawValue = entry['value'];
    // Symbols-only or failed-read items carry no value: nothing to push.
    if (rawValue == null) continue;
    if (rawValue is! String) {
      throw FormatException('snapshot symbols[$i].value must be a hex string');
    }

    final name = entry['name'] is String ? entry['name'] as String : '?';
    final group = _requireInt(entry['indexGroup'], i, 'indexGroup');
    final offset = _requireInt(entry['indexOffset'], i, 'indexOffset');
    final size = _requireInt(entry['size'], i, 'size');

    // parseHex throws FormatException on any non-hex/odd input (-> exit 2).
    final data = parseHex(rawValue);
    if (data.length > size) {
      throw FormatException('snapshot symbols[$i].value is ${data.length} '
          'bytes but the declared size is $size');
    }
    out.add(_PushItem(name, group, offset, data));
  }
  return out;
}

/// Reads a required non-negative u32 field from an untrusted item, throwing
/// [FormatException] (-> exit 2) if absent or the wrong type/range.
int _requireInt(Object? value, int index, String field) {
  if (value is! int) {
    throw FormatException('snapshot symbols[$index].$field must be an integer');
  }
  if (value < 0 || value > 0xFFFFFFFF) {
    throw FormatException(
        'snapshot symbols[$index].$field ($value) is out of the u32 range');
  }
  return value;
}
