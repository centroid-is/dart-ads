/// The `write` verb: write a variable by name (value parsed to the symbol's PLC
/// type or an explicit `--type`) or by index-group/offset (`--raw` hex bytes).
///
/// This plan (08-04) fills the `run()` body, reusing the shared connect→guarded
/// backbone (08-01) and the value-parsing seam (`encodeTypedValue`/`parseHex`).
/// The by-name path encodes the operator's `--value` via the symbol's declared
/// type (or a forced `--type`); the group/offset path takes `--raw` hex bytes
/// verbatim. Every hostile value/hex surfaces as a [FormatException] (→ exit 2),
/// never a crash or a truncated buffer reaching the PLC (threat T-8-01d).
library;

import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';
import '../value_parsing.dart';

/// `ads write` — write a variable (by name or index-group/offset).
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
        final r = argResults!;
        final nameOpt = (r['name'] as String?)?.trim();
        final groupOpt = (r['group'] as String?)?.trim();
        final offsetOpt = (r['offset'] as String?)?.trim();
        final typeOpt = (r['type'] as String?)?.trim();
        final valueOpt = r['value'] as String?;
        final rawOpt = r['raw'] as String?;

        final hasName = nameOpt != null && nameOpt.isNotEmpty;
        final hasGroup = groupOpt != null && groupOpt.isNotEmpty;
        final hasOffset = offsetOpt != null && offsetOpt.isNotEmpty;
        final hasRawPath = hasGroup || hasOffset;
        // Use wasParsed (not a non-empty check) so an intentional empty write —
        // e.g. `--value ""` clearing a STRING, or `--raw 0x` — is honored.
        final hasValue = r.wasParsed('value');
        final hasRaw = r.wasParsed('raw');

        // Target selection is name XOR group/offset.
        if (hasName && hasRawPath) {
          throw UsageException(
            '--name and --group/--offset are mutually exclusive',
            '',
          );
        }
        if (!hasName && !hasRawPath) {
          throw UsageException(
            'write needs either --name <symbol> or --group/--offset <int>',
            '',
          );
        }
        // Payload source is --value (typed) XOR --raw (hex).
        if (hasValue && hasRaw) {
          throw UsageException(
            '--value and --raw are mutually exclusive',
            '',
          );
        }
        if (!hasValue && !hasRaw) {
          throw UsageException(
            'write needs either --value <v> or --raw <hex>',
            '',
          );
        }

        final session = await connectFromGlobals(globalResults!);
        try {
          final client = session.client;
          final Uint8List data;
          final String target;

          if (hasName) {
            data = hasRaw
                ? parseHex(rawOpt!)
                : await _encodeForName(client, nameOpt, typeOpt, valueOpt!);
            await client.writeByName(nameOpt, data);
            target = nameOpt;
          } else {
            if (!hasGroup || !hasOffset) {
              throw UsageException(
                'a raw write needs both --group and --offset',
                '',
              );
            }
            // A typed write needs a symbol size, which the raw group/offset
            // path lacks — require --raw here (use --name for typed writes).
            if (!hasRaw) {
              throw UsageException(
                'a --group/--offset write needs --raw <hex> '
                    '(typed writes need a symbol size; use --name)',
                '',
              );
            }
            final group = _parseAnyInt(groupOpt, 'group');
            final offset = _parseAnyInt(offsetOpt, 'offset');
            data = parseHex(rawOpt!);
            await client.write(
              indexGroup: group,
              indexOffset: offset,
              data: data,
            );
            target = '0x${group.toRadixString(16)}:'
                '0x${offset.toRadixString(16)}';
          }

          print('wrote ${data.length} bytes to $target');
          return exitOk;
        } finally {
          await session.close();
        }
      });
}

/// Encodes the operator's [value] for symbol [name] into wire bytes.
///
/// With an explicit [typeOpt] the value is parsed as that type; STRING/WSTRING
/// additionally resolve the symbol's declared byte size. Without [typeOpt] the
/// symbol's declared type and size are resolved and used. Every hostile value
/// (non-numeric, out-of-range, unknown type) surfaces as a [FormatException]
/// via [encodeTypedValue] (→ exit 2), never a truncated buffer.
Future<Uint8List> _encodeForName(
  AdsClient client,
  String name,
  String? typeOpt,
  String value,
) async {
  if (typeOpt != null && typeOpt.isNotEmpty) {
    final normType = _normalizeType(typeOpt);
    // Only the variable-length string types need the symbol's declared size;
    // fixed scalars size themselves, so skip the browse for them.
    int? size;
    if (normType == 'string' || normType == 'wstring') {
      size = (await _resolveOrRaise(client, name)).size;
    }
    return encodeTypedValue(normType, value, size: size);
  }

  // No --type: resolve the symbol's declared type/size and encode with it.
  final sym = await _resolveOrRaise(client, name);
  final normType = _normalizeType(sym.typeName);
  return encodeTypedValue(normType, value, size: sym.size);
}

/// Resolves [name] to its [AdsSymbolInfo] via `browseSymbols`. When the symbol
/// is absent, forces the device's own ADS error (unknown symbol → exit 1 with a
/// human-readable name) by attempting a handle-by-name, rather than leaking a
/// generic lookup failure.
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

/// Normalizes a symbol/`--type` type name for the value-parsing codec: strips a
/// trailing `(...)` size suffix (e.g. `STRING(80)` → `string`) and lower-cases.
String _normalizeType(String typeName) {
  var t = typeName.trim();
  final paren = t.indexOf('(');
  if (paren >= 0) t = t.substring(0, paren);
  return t.trim().toLowerCase();
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
