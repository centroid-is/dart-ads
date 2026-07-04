/// The `read` verb: read a variable by name (typed) or by index-group/offset
/// (raw).
///
/// This plan (08-03) fills the `run()` body, reusing the shared connect→guarded
/// backbone (08-01) and the value-parsing seam (`decodeTypedValue`/`formatHex`).
/// The by-name path decodes via the symbol's declared type (or a forced
/// `--type`), the group/offset path returns raw hex, and an unknown symbol
/// surfaces the device's ADS error → exit 1 with a human-readable name.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

import '../base_command.dart';
import '../connection.dart';
import '../exit_codes.dart';
import '../value_parsing.dart';

/// `ads read` — read a variable (by name or index-group/offset).
class ReadCommand extends BaseAdsCommand {
  /// Declares the read-specific flags (name path and raw group/offset path).
  ReadCommand() {
    argParser
      ..addOption(
        'name',
        help:
            'Symbol name to read (typed via its symbol type when resolvable).',
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
        final r = argResults!;
        final nameOpt = (r['name'] as String?)?.trim();
        final groupOpt = (r['group'] as String?)?.trim();
        final offsetOpt = (r['offset'] as String?)?.trim();
        final lenOpt = (r['len'] as String?)?.trim();
        final typeOpt = (r['type'] as String?)?.trim();
        final raw = r['raw'] as bool;
        final asJson = r['json'] as bool;

        final hasName = nameOpt != null && nameOpt.isNotEmpty;
        final hasGroup = groupOpt != null && groupOpt.isNotEmpty;
        final hasOffset = offsetOpt != null && offsetOpt.isNotEmpty;
        final hasRawPath = hasGroup || hasOffset;

        if (hasName && hasRawPath) {
          throw UsageException(
            '--name and --group/--offset are mutually exclusive',
            '',
          );
        }
        if (!hasName && !hasRawPath) {
          throw UsageException(
            'read needs either --name <symbol> or --group/--offset <int>',
            '',
          );
        }

        final session = await connectFromGlobals(globalResults!);
        try {
          final client = session.client;
          final Object output; // String (plain) or Map (json)

          if (hasName) {
            output = await _readByName(
              client,
              name: nameOpt,
              typeOpt: typeOpt,
              raw: raw,
              asJson: asJson,
            );
          } else {
            if (!hasGroup || !hasOffset) {
              throw UsageException(
                'a raw read needs both --group and --offset',
                '',
              );
            }
            if (lenOpt == null || lenOpt.isEmpty) {
              throw UsageException(
                'a raw --group/--offset read needs --len <bytes>',
                '',
              );
            }
            final group = _parseAnyInt(groupOpt, 'group');
            final offset = _parseAnyInt(offsetOpt, 'offset');
            final len = _parseAnyInt(lenOpt, 'len');
            final bytes = await client.read(
              indexGroup: group,
              indexOffset: offset,
              length: len,
            );
            final hex = formatHex(bytes);
            output = asJson
                ? <String, Object?>{
                    'group': '0x${group.toRadixString(16)}',
                    'offset': '0x${offset.toRadixString(16)}',
                    'len': len,
                    'hex': hex,
                  }
                : hex;
          }

          print(asJson ? jsonEncode(output) : output);
          return exitOk;
        } finally {
          await session.close();
        }
      });
}

/// Reads a symbol [name] and returns either a plain display string or a JSON
/// map (when [asJson]). Honors `--raw` (force hex) and `--type` (force decode);
/// otherwise resolves the symbol's declared type/size and typed-decodes, falling
/// back to raw hex when the declared type is not codec-known.
Future<Object> _readByName(
  AdsClient client, {
  required String name,
  required String? typeOpt,
  required bool raw,
  required bool asJson,
}) async {
  if (raw) {
    final sym = await _resolveOrRaise(client, name);
    final bytes = await client.readByName(name, sym.size);
    return _nameResult(name, 'raw', formatHex(bytes), asJson, hex: true);
  }

  if (typeOpt != null && typeOpt.isNotEmpty) {
    final normType = _normalizeType(typeOpt);
    final bytes = await _readTypedBytes(client, name, normType);
    final value = decodeTypedValue(normType, bytes);
    return _nameResult(name, normType, value, asJson);
  }

  // No --type: resolve the symbol's declared type/size and typed-decode.
  final sym = await _resolveOrRaise(client, name);
  final normType = _normalizeType(sym.typeName);
  final bytes = await client.readByName(name, sym.size);
  try {
    final value = decodeTypedValue(normType, bytes);
    return _nameResult(name, normType, value, asJson);
  } on FormatException {
    // Declared type is not codec-known — fall back to the raw hex escape hatch.
    return _nameResult(name, 'raw', formatHex(bytes), asJson, hex: true);
  }
}

/// Builds the by-name result as a plain string or a JSON map.
Object _nameResult(
  String name,
  String type,
  String value,
  bool asJson, {
  bool hex = false,
}) {
  if (!asJson) return value;
  return <String, Object?>{
    'name': name,
    'type': type,
    if (hex) 'hex': value else 'value': value,
  };
}

/// Reads the wire bytes for symbol [name] as [type] (a normalized, lower-case
/// type name). Fixed-width types use their known size; STRING/WSTRING resolve
/// the symbol's declared byte size first.
Future<Uint8List> _readTypedBytes(
  AdsClient client,
  String name,
  String type,
) async {
  final fixed = _fixedTypeSizes[type];
  if (fixed != null) {
    return client.readByName(name, fixed);
  }
  if (type == 'string' || type == 'wstring') {
    final sym = await _resolveOrRaise(client, name);
    return client.readByName(name, sym.size);
  }
  throw FormatException('Unknown --type "$type"');
}

/// Fixed wire sizes (bytes) for the codec-known scalar types, mirroring the
/// value-parsing seam so `--type` can size its read without a symbol lookup.
const Map<String, int> _fixedTypeSizes = {
  'bool': 1,
  'byte': 1,
  'sint': 1,
  'word': 2,
  'int': 2,
  'dword': 4,
  'dint': 4,
  'real': 4,
  'lreal': 8,
};

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
    throw FormatException('--$flag must be an integer (decimal or 0x hex)', raw);
  }
  return value;
}
