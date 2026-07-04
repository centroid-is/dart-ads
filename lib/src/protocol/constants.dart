/// Wire-protocol constants for the Beckhoff ADS / AMS protocol.
///
/// Every value here is authoritative: it is transcribed directly from the
/// vendored Beckhoff/ADS reference headers
/// (`third_party/ADS/AdsLib/standalone/AdsDef.h`), so the Dart codec and the
/// C++ golden-frame harness agree by construction.
///
/// This file is pure: it imports nothing (no `dart:async` / `dart:io`) and
/// exposes only compile-time `const` integer values grouped into namespaced
/// `abstract final class` holders.
library;

/// ADS service (command) IDs — the `commandId` u16 field of the AMS header.
///
/// Source: `ADSSRVID_*` in `AdsDef.h`.
abstract final class AdsCommandId {
  AdsCommandId._();

  /// Invalid / unset service ID (`ADSSRVID_INVALID`).
  static const int invalid = 0x00;

  /// Read device info (`ADSSRVID_READDEVICEINFO`).
  static const int readDeviceInfo = 0x01;

  /// Read data by index group/offset (`ADSSRVID_READ`).
  static const int read = 0x02;

  /// Write data by index group/offset (`ADSSRVID_WRITE`).
  static const int write = 0x03;

  /// Read the ADS/device state (`ADSSRVID_READSTATE`).
  static const int readState = 0x04;

  /// Write control (change ADS/device state) (`ADSSRVID_WRITECTRL`).
  static const int writeControl = 0x05;

  /// Add a device notification subscription (`ADSSRVID_ADDDEVICENOTE`).
  static const int addDeviceNotification = 0x06;

  /// Delete a device notification subscription (`ADSSRVID_DELDEVICENOTE`).
  static const int deleteDeviceNotification = 0x07;

  /// A delivered device notification (`ADSSRVID_DEVICENOTE`).
  static const int deviceNotification = 0x08;

  /// Combined read/write in one round-trip (`ADSSRVID_READWRITE`).
  static const int readWrite = 0x09;
}

/// AMS header `stateFlags` u16 values.
///
/// The low bit distinguishes request (0) from response (1); the ADS-over-TCP
/// command flag (`0x0004`) is set on every AMS/TCP frame.
abstract final class AmsStateFlags {
  AmsStateFlags._();

  /// ADS command over AMS/TCP, request direction (`0x0004`).
  static const int request = 0x0004;

  /// ADS command over AMS/TCP, response direction (`0x0005`).
  static const int response = 0x0005;

  /// Bit set on responses; distinguishes a response from its request.
  static const int responseBit = 0x0001;
}

/// AMS ports for the well-known TwinCAT runtime endpoints.
///
/// Source: `AMSPORT_*` in `AdsDef.h`. The full set is not needed for framing;
/// the PLC ports below are the ones this project exercises first.
abstract final class AmsPort {
  AmsPort._();

  /// TwinCAT 2 PLC runtime 1 (`AMSPORT_R0_PLC_RTS1`).
  static const int plcRuntime1 = 801;

  /// TwinCAT 3 PLC runtime (`AMSPORT_R0_PLC_TC3`).
  static const int plcTc3 = 851;
}

/// ADS index groups referenced across the protocol codecs.
///
/// Source: `ADSIGRP_*` in `AdsDef.h`. Only the symbol-access and device-data
/// groups this project uses are transcribed; the full upstream list is larger.
abstract final class AdsIndexGroup {
  AdsIndexGroup._();

  /// Symbol table (`ADSIGRP_SYMTAB`).
  static const int symbolTable = 0xF000;

  /// Symbol name (`ADSIGRP_SYMNAME`).
  static const int symbolName = 0xF001;

  /// Symbol value (`ADSIGRP_SYMVAL`).
  static const int symbolValue = 0xF002;

  /// Get a symbol handle by name (`ADSIGRP_SYM_HNDBYNAME`).
  static const int symbolHandleByName = 0xF003;

  /// Read/write a symbol value by name (`ADSIGRP_SYM_VALBYNAME`).
  static const int symbolValueByName = 0xF004;

  /// Read/write a symbol value by handle (`ADSIGRP_SYM_VALBYHND`).
  static const int symbolValueByHandle = 0xF005;

  /// Release a symbol handle (`ADSIGRP_SYM_RELEASEHND`).
  static const int symbolReleaseHandle = 0xF006;

  /// Symbol info by name (`ADSIGRP_SYM_INFOBYNAME`).
  static const int symbolInfoByName = 0xF007;

  /// Symbol upload (`ADSIGRP_SYM_UPLOAD`).
  static const int symbolUpload = 0xF00B;

  /// Symbol upload info (`ADSIGRP_SYM_UPLOADINFO`).
  static const int symbolUploadInfo = 0xF00C;

  /// Sum-command batched read (`ADSIGRP_SUMUP_READ`).
  static const int sumUpRead = 0xF080;

  /// Sum-command batched write (`ADSIGRP_SUMUP_WRITE`).
  static const int sumUpWrite = 0xF081;

  /// Sum-command batched read/write (`ADSIGRP_SUMUP_READWRITE`).
  static const int sumUpReadWrite = 0xF082;

  /// Device data (state, name, ...) (`ADSIGRP_DEVICE_DATA`).
  static const int deviceData = 0xF100;
}

/// Offsets within [AdsIndexGroup.deviceData].
///
/// Source: `ADSIOFFS_DEVDATA_*` in `AdsDef.h`.
abstract final class AdsDeviceDataOffset {
  AdsDeviceDataOffset._();

  /// ADS state of the device (`ADSIOFFS_DEVDATA_ADSSTATE`).
  static const int adsState = 0x0000;

  /// Device state (`ADSIOFFS_DEVDATA_DEVSTATE`).
  static const int deviceState = 0x0002;
}

/// ADS device run states (`adsState` u16 in ReadState / WriteControl).
///
/// Source: `enum ADSSTATE` in `AdsDef.h` (values 0..19; `ADSSTATE_MAXSTATES`
/// (20) is a sentinel and is intentionally omitted). Each member carries its
/// wire [code]; use [AdsState.fromCode] to map a raw u16 back to a member.
///
/// A real PLC can report a value outside this list, so [fromCode] is tolerant:
/// it returns [AdsState.unknown] for any unrecognised value rather than
/// throwing. `AdsState.unknown` carries the sentinel [code] `-1` (never a valid
/// wire value) so it can never collide with a real state.
enum AdsState {
  /// `ADSSTATE_INVALID`.
  invalid(0),

  /// `ADSSTATE_IDLE`.
  idle(1),

  /// `ADSSTATE_RESET`.
  reset(2),

  /// `ADSSTATE_INIT`.
  init(3),

  /// `ADSSTATE_START`.
  start(4),

  /// `ADSSTATE_RUN`.
  run(5),

  /// `ADSSTATE_STOP`.
  stop(6),

  /// `ADSSTATE_SAVECFG`.
  saveConfig(7),

  /// `ADSSTATE_LOADCFG`.
  loadConfig(8),

  /// `ADSSTATE_POWERFAILURE`.
  powerFailure(9),

  /// `ADSSTATE_POWERGOOD`.
  powerGood(10),

  /// `ADSSTATE_ERROR`.
  error(11),

  /// `ADSSTATE_SHUTDOWN`.
  shutdown(12),

  /// `ADSSTATE_SUSPEND`.
  suspend(13),

  /// `ADSSTATE_RESUME`.
  resume(14),

  /// `ADSSTATE_CONFIG`.
  config(15),

  /// `ADSSTATE_RECONFIG`.
  reconfig(16),

  /// `ADSSTATE_STOPPING`.
  stopping(17),

  /// `ADSSTATE_INCOMPATIBLE`.
  incompatible(18),

  /// `ADSSTATE_EXCEPTION`.
  exception(19),

  /// Tolerant fallback for a wire value outside the known 0..19 range. Carries
  /// the sentinel [code] `-1`, which is never a valid u16 wire value.
  unknown(-1);

  const AdsState(this.code);

  /// The u16 wire value for this state (or `-1` for [unknown]).
  final int code;

  /// Maps a raw wire [code] to its [AdsState] member, or [AdsState.unknown] for
  /// any unrecognised value. Never throws — a hostile / future state value
  /// surfaces as [unknown] rather than crashing decode (research Pitfall 4).
  static AdsState fromCode(int code) {
    for (final state in values) {
      if (state != unknown && state.code == code) {
        return state;
      }
    }
    return unknown;
  }
}
