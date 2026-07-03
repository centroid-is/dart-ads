/// Internal unsigned-range checks shared by the wire encoders.
///
/// `ByteData.setUint16` / `setUint32` do not range-check — they silently store
/// the low bits (`setUint16(0, 70000)` writes 4464, `setUint16(0, -1)` writes
/// 0xFFFF). For a codec whose whole contract is byte-exactness, silent
/// truncation is the worst failure mode: the frame is well-formed but *wrong*,
/// and a PLC will act on it. Every encoder therefore validates its integer
/// fields through [checkUint] at the API boundary, failing fast with an
/// [ArgumentError] instead of corrupting the wire.
///
/// Pure: imports nothing (no `dart:async` / `dart:io`). This library is
/// intentionally NOT exported by the package barrel.
library;

/// Returns [value] unchanged if it fits an unsigned [bits]-bit wire field,
/// otherwise throws [ArgumentError] naming the offending [name].
int checkUint(int value, int bits, String name) {
  // `(1 << 32) - 1` is NOT portable: under dart2js, `1 << 32` evaluates to 0
  // (JS shift semantics), folding max to -1 and rejecting every value (WR-09).
  // Build the mask from two sub-31-bit shifts, which are safe on VM and web.
  final max = ((1 << (bits - 1)) - 1) * 2 + 1;
  if (value < 0 || value > max) {
    throw ArgumentError.value(value, name, 'must fit in u$bits (0..$max)');
  }
  return value;
}
