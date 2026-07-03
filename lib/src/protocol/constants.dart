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
/// Source: `enum ADSSTATE` in `AdsDef.h`.
abstract final class AdsState {
  AdsState._();

  static const int invalid = 0;
  static const int idle = 1;
  static const int reset = 2;
  static const int init = 3;
  static const int start = 4;
  static const int run = 5;
  static const int stop = 6;
  static const int saveConfig = 7;
  static const int loadConfig = 8;
  static const int powerFailure = 9;
  static const int powerGood = 10;
  static const int error = 11;
  static const int shutdown = 12;
  static const int suspend = 13;
  static const int resume = 14;
  static const int config = 15;
  static const int reconfig = 16;
}

/// ADS error codes carried in a response's `result u32` / the AMS header's
/// `errorCode u32`.
///
/// Source: `ADSERR_*` in `AdsDef.h`. `ERR_ADSERRS` (0x0700) is the device-error
/// base; only the commonly-encountered codes are transcribed here.
abstract final class AdsError {
  AdsError._();

  /// Base offset for device ADS errors (`ERR_ADSERRS`).
  static const int adsErrorBase = 0x0700;

  /// No error (`ADSERR_NOERR`).
  static const int noError = 0x00;

  /// Error class: device error (`ADSERR_DEVICE_ERROR`).
  static const int deviceError = 0x00 + adsErrorBase;

  /// Service not supported by server (`ADSERR_DEVICE_SRVNOTSUPP`).
  static const int serviceNotSupported = 0x01 + adsErrorBase;

  /// Invalid index group (`ADSERR_DEVICE_INVALIDGRP`).
  static const int invalidIndexGroup = 0x02 + adsErrorBase;

  /// Invalid index offset (`ADSERR_DEVICE_INVALIDOFFSET`).
  static const int invalidIndexOffset = 0x03 + adsErrorBase;

  /// Reading/writing not permitted (`ADSERR_DEVICE_INVALIDACCESS`).
  static const int invalidAccess = 0x04 + adsErrorBase;

  /// Parameter size not correct (`ADSERR_DEVICE_INVALIDSIZE`).
  static const int invalidSize = 0x05 + adsErrorBase;

  /// Invalid parameter value(s) (`ADSERR_DEVICE_INVALIDDATA`).
  static const int invalidData = 0x06 + adsErrorBase;

  /// Device not in a ready state (`ADSERR_DEVICE_NOTREADY`).
  static const int notReady = 0x07 + adsErrorBase;

  /// Device is busy (`ADSERR_DEVICE_BUSY`).
  static const int busy = 0x08 + adsErrorBase;

  /// Out of memory (`ADSERR_DEVICE_NOMEMORY`).
  static const int noMemory = 0x0A + adsErrorBase;

  /// Not found (files, ...) (`ADSERR_DEVICE_NOTFOUND`).
  static const int notFound = 0x0C + adsErrorBase;

  /// Symbol not found (`ADSERR_DEVICE_SYMBOLNOTFOUND`).
  static const int symbolNotFound = 0x10 + adsErrorBase;

  /// Server is in an invalid state (`ADSERR_DEVICE_INVALIDSTATE`).
  static const int invalidState = 0x12 + adsErrorBase;

  /// Notification handle is invalid (`ADSERR_DEVICE_NOTIFYHNDINVALID`).
  static const int notificationHandleInvalid = 0x14 + adsErrorBase;

  /// Device has a timeout (`ADSERR_DEVICE_TIMEOUT`).
  static const int timeout = 0x19 + adsErrorBase;

  /// Access denied (`ADSERR_DEVICE_ACCESSDENIED`).
  static const int accessDenied = 0x23 + adsErrorBase;
}
