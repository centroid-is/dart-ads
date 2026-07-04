/// Pure value types returned by the [AdsClient] command methods.
///
/// These are deliberately dependency-light: they import only the pure
/// `protocol/` [AdsState] enum (no `dart:async` / `dart:io`), so the typed
/// return surface of the client stays trivially constructible and testable.
/// `readState()` returns an [AdsStateInfo]; `readDeviceInfo()` returns a
/// [DeviceInfo].
library;

import '../protocol/constants.dart';

/// The decoded result of a ReadState (0x04) command.
///
/// [adsState] is the run state mapped through [AdsState.fromCode] (an unknown /
/// future wire value surfaces as [AdsState.unknown] rather than throwing). The
/// raw ints remain accessible per the Phase-3 decision: [rawAdsState] is the
/// unmapped u16 the device reported, and [deviceState] is the device-specific
/// state word.
class AdsStateInfo {
  /// Creates a state-info value from the mapped [adsState] plus the raw
  /// [rawAdsState] and [deviceState] wire values.
  const AdsStateInfo({
    required this.adsState,
    required this.rawAdsState,
    required this.deviceState,
  });

  /// The ADS run state, mapped from [rawAdsState] via [AdsState.fromCode].
  final AdsState adsState;

  /// The raw u16 ADS-state wire value the device reported (kept alongside the
  /// mapped [adsState] so an unmapped value is never lost).
  final int rawAdsState;

  /// The device-specific state word (u16).
  final int deviceState;

  @override
  String toString() => 'AdsStateInfo(adsState: $adsState, '
      'rawAdsState: $rawAdsState, deviceState: $deviceState)';
}

/// The decoded result of a ReadDeviceInfo (0x01) command: the device [name] and
/// its [version] / [revision] / [build] triple.
class DeviceInfo {
  /// Creates a device-info value from the device [name] and version triple.
  const DeviceInfo({
    required this.name,
    required this.version,
    required this.revision,
    required this.build,
  });

  /// The device name (NUL-terminated ASCII contents of the 16-byte name field).
  final String name;

  /// Major version (u8).
  final int version;

  /// Revision (u8).
  final int revision;

  /// Build number (u16).
  final int build;

  @override
  String toString() =>
      'DeviceInfo(name: "$name", v$version.$revision build $build)';
}
