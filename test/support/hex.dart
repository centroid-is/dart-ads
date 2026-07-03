/// Test-support helpers for reading committed golden hex fixtures.
///
/// This lives under `test/` (not `lib/`), so importing `dart:io` here is
/// intentional and allowed — it is test-only support code.
library;

import 'dart:io';
import 'dart:typed_data';

/// Reads a `#`-commented hex golden file and returns the decoded bytes.
///
/// The fixture format is human-diffable text: one frame per file, arbitrary
/// whitespace, and inline `#` comments. Everything after the first `#` on a
/// line is dropped, all whitespace is stripped, and the remaining hex nibble
/// pairs are decoded into a [Uint8List].
///
/// [path] is resolved relative to the current working directory (the package
/// root when running `dart test`), e.g.
/// `'test/golden/read_device_info_req.hex'`.
///
/// A fully-commented or whitespace-only file decodes to an empty [Uint8List].
///
/// Throws [FormatException] if the cleaned content has an odd number of hex
/// nibbles — matching the C++ twin (`mock_server.cpp` `readGoldenHex`), which
/// rejects such a file as corrupt. Silently dropping the trailing nibble would
/// decode a truncated fixture into a shorter-but-plausible byte string and
/// point the resulting parity failure at the codec instead of the fixture.
Uint8List readGolden(String path) {
  final cleaned = File(path)
      .readAsLinesSync()
      .map((line) => line.split('#').first) // drop inline comments
      .join()
      .replaceAll(RegExp(r'\s'), ''); // strip all whitespace

  if (cleaned.length.isOdd) {
    throw FormatException(
        'odd number of hex nibbles (${cleaned.length}) in $path');
  }

  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
