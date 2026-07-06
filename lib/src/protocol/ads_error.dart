/// ADS error-code table and the typed [AdsException] family.
///
/// This file is pure: it imports nothing (no `dart:async` / `dart:io`), so the
/// whole `protocol/` subtree stays unit-testable in isolation. The table is
/// transcribed VERBATIM from the vendored Beckhoff/ADS reference header
/// (`third_party/ADS/AdsLib/standalone/AdsDef.h`), so the Dart error messages
/// match the operator-facing text a real TwinCAT PLC / the C++ AdsLib emits.
///
/// [AdsException] is a NEW, DISTINCT exception family. It is intentionally
/// separate from the wire-level `MalformedFrameException`
/// (`protocol/exceptions.dart`) and the transport-level `AdsTimeoutException` /
/// `AdsConnectionException` (`connection/exceptions.dart`). A well-formed
/// response carrying a non-zero ADS `result` (or a non-zero AMS header
/// `errorCode`) surfaces as an [AdsException]; callers can therefore `catch`
/// device errors separately from framing failures and transport failures.
library;

/// A single known ADS error code's constant name and its canonical, operator
/// facing text (both from `AdsDef.h`).
typedef AdsErrorEntry = ({String name, String text});

/// The full ADS error table: code -> (constant name, canonical text).
///
/// Codes are the complete u32 AMS/ADS error value (base range + offset), shown
/// in hex. `0x0000` (`ADSERR_NOERR`) is success and is intentionally absent — a
/// zero code never maps to an exception. The client range has intentional gaps
/// (`0x0749` jumps straight to `0x0750`); those gaps are preserved here — a
/// lookup miss falls back to a synthetic name rather than an invented entry.
const Map<int, AdsErrorEntry> _adsErrorTable = <int, AdsErrorEntry>{
  // Global return codes (base 0x0000).
  0x0006: (
    name: 'GLOBALERR_TARGET_PORT',
    text: 'target port not found, possibly the ADS Server is not started',
  ),
  0x0007: (
    name: 'GLOBALERR_MISSING_ROUTE',
    text: 'target machine not found, possibly missing ADS routes',
  ),
  0x0019: (name: 'GLOBALERR_NO_MEMORY', text: 'no memory'),
  0x001A: (name: 'GLOBALERR_TCP_SEND', text: 'TCP send error'),

  // Router return codes (base 0x0500).
  0x0506: (
    name: 'ROUTERERR_PORTALREADYINUSE',
    text: 'the desired port number is already assigned',
  ),
  0x0507: (name: 'ROUTERERR_NOTREGISTERED', text: 'port not registered'),
  0x0508: (
    name: 'ROUTERERR_NOMOREQUEUES',
    text: 'the maximum number of ports reached',
  ),

  // ADS device errors (base 0x0700).
  0x0700: (name: 'ADSERR_DEVICE_ERROR', text: 'error class < device error >'),
  0x0701: (
    name: 'ADSERR_DEVICE_SRVNOTSUPP',
    text: 'service is not supported by server',
  ),
  0x0702: (name: 'ADSERR_DEVICE_INVALIDGRP', text: 'invalid indexGroup'),
  0x0703: (name: 'ADSERR_DEVICE_INVALIDOFFSET', text: 'invalid indexOffset'),
  0x0704: (
    name: 'ADSERR_DEVICE_INVALIDACCESS',
    text: 'reading/writing not permitted',
  ),
  0x0705: (
    name: 'ADSERR_DEVICE_INVALIDSIZE',
    text: 'parameter size not correct',
  ),
  0x0706: (
    name: 'ADSERR_DEVICE_INVALIDDATA',
    text: 'invalid parameter value(s)',
  ),
  0x0707: (
    name: 'ADSERR_DEVICE_NOTREADY',
    text: 'device is not in a ready state',
  ),
  0x0708: (name: 'ADSERR_DEVICE_BUSY', text: 'device is busy'),
  0x0709: (
    name: 'ADSERR_DEVICE_INVALIDCONTEXT',
    text: 'invalid context (must be in Windows)',
  ),
  0x070A: (name: 'ADSERR_DEVICE_NOMEMORY', text: 'out of memory'),
  0x070B: (
    name: 'ADSERR_DEVICE_INVALIDPARM',
    text: 'invalid parameter value(s)',
  ),
  0x070C: (name: 'ADSERR_DEVICE_NOTFOUND', text: 'not found (files, ...)'),
  0x070D: (
    name: 'ADSERR_DEVICE_SYNTAX',
    text: 'syntax error in command or file'
  ),
  0x070E: (name: 'ADSERR_DEVICE_INCOMPATIBLE', text: 'objects do not match'),
  0x070F: (name: 'ADSERR_DEVICE_EXISTS', text: 'object already exists'),
  0x0710: (name: 'ADSERR_DEVICE_SYMBOLNOTFOUND', text: 'symbol not found'),
  0x0711: (
    name: 'ADSERR_DEVICE_SYMBOLVERSIONINVALID',
    text: 'symbol version invalid (online change) '
        '=> release handle and get a new one',
  ),
  0x0712: (
    name: 'ADSERR_DEVICE_INVALIDSTATE',
    text: 'server is in invalid state',
  ),
  0x0713: (
    name: 'ADSERR_DEVICE_TRANSMODENOTSUPP',
    text: 'AdsTransMode not supported',
  ),
  0x0714: (
    name: 'ADSERR_DEVICE_NOTIFYHNDINVALID',
    text: 'notification handle is invalid (online change) '
        '=> release handle and get a new one',
  ),
  0x0715: (
    name: 'ADSERR_DEVICE_CLIENTUNKNOWN',
    text: 'notification client not registered',
  ),
  0x0716: (
    name: 'ADSERR_DEVICE_NOMOREHDLS',
    text: 'no more notification handles',
  ),
  0x0717: (
    name: 'ADSERR_DEVICE_INVALIDWATCHSIZE',
    text: 'size for watch too big',
  ),
  0x0718: (name: 'ADSERR_DEVICE_NOTINIT', text: 'device not initialized'),
  0x0719: (name: 'ADSERR_DEVICE_TIMEOUT', text: 'device has a timeout'),
  0x071A: (name: 'ADSERR_DEVICE_NOINTERFACE', text: 'query interface failed'),
  0x071B: (
    name: 'ADSERR_DEVICE_INVALIDINTERFACE',
    text: 'wrong interface required',
  ),
  0x071C: (name: 'ADSERR_DEVICE_INVALIDCLSID', text: 'class ID is invalid'),
  0x071D: (name: 'ADSERR_DEVICE_INVALIDOBJID', text: 'object ID is invalid'),
  0x071E: (name: 'ADSERR_DEVICE_PENDING', text: 'request is pending'),
  0x071F: (name: 'ADSERR_DEVICE_ABORTED', text: 'request is aborted'),
  0x0720: (name: 'ADSERR_DEVICE_WARNING', text: 'signal warning'),
  0x0721: (name: 'ADSERR_DEVICE_INVALIDARRAYIDX', text: 'invalid array index'),
  0x0722: (
    name: 'ADSERR_DEVICE_SYMBOLNOTACTIVE',
    text: 'symbol not active (online change) '
        '=> release handle and get a new one',
  ),
  0x0723: (name: 'ADSERR_DEVICE_ACCESSDENIED', text: 'access denied'),
  0x0724: (
    name: 'ADSERR_DEVICE_LICENSENOTFOUND',
    text: 'no license found => activate license for TwinCAT 3 function',
  ),
  0x0725: (name: 'ADSERR_DEVICE_LICENSEEXPIRED', text: 'license expired'),
  0x0726: (name: 'ADSERR_DEVICE_LICENSEEXCEEDED', text: 'license exceeded'),
  0x0727: (name: 'ADSERR_DEVICE_LICENSEINVALID', text: 'license invalid'),
  0x0728: (
    name: 'ADSERR_DEVICE_LICENSESYSTEMID',
    text: 'license invalid system id',
  ),
  0x0729: (
    name: 'ADSERR_DEVICE_LICENSENOTIMELIMIT',
    text: 'license not time limited',
  ),
  0x072A: (
    name: 'ADSERR_DEVICE_LICENSEFUTUREISSUE',
    text: 'license issue time in the future',
  ),
  0x072B: (
    name: 'ADSERR_DEVICE_LICENSETIMETOLONG',
    text: 'license time period too long',
  ),
  0x072C: (
    name: 'ADSERR_DEVICE_EXCEPTION',
    text: 'exception in device specific code => check each device transition',
  ),
  0x072D: (
    name: 'ADSERR_DEVICE_LICENSEDUPLICATED',
    text: 'license file read twice',
  ),
  0x072E: (name: 'ADSERR_DEVICE_SIGNATUREINVALID', text: 'invalid signature'),
  0x072F: (
    name: 'ADSERR_DEVICE_CERTIFICATEINVALID',
    text: 'public key certificate',
  ),

  // ADS client errors (base 0x0740). Note the intentional 0x0749 -> 0x0750 gap.
  0x0740: (name: 'ADSERR_CLIENT_ERROR', text: 'error class < client error >'),
  0x0741: (
    name: 'ADSERR_CLIENT_INVALIDPARM',
    text: 'invalid parameter at service call',
  ),
  0x0742: (name: 'ADSERR_CLIENT_LISTEMPTY', text: 'polling list is empty'),
  0x0743: (
    name: 'ADSERR_CLIENT_VARUSED',
    text: 'var connection already in use',
  ),
  0x0744: (name: 'ADSERR_CLIENT_DUPLINVOKEID', text: 'invoke id in use'),
  0x0745: (
    name: 'ADSERR_CLIENT_SYNCTIMEOUT',
    text: 'timeout elapsed => check ADS routes of sender and receiver '
        'and your firewall setting',
  ),
  0x0746: (name: 'ADSERR_CLIENT_W32ERROR', text: 'error in win32 subsystem'),
  0x0747: (
    name: 'ADSERR_CLIENT_TIMEOUTINVALID',
    text: 'invalid client timeout value',
  ),
  0x0748: (name: 'ADSERR_CLIENT_PORTNOTOPEN', text: 'ads port not opened'),
  0x0749: (name: 'ADSERR_CLIENT_NOAMSADDR', text: 'no ams address'),
  0x0750: (
    name: 'ADSERR_CLIENT_SYNCINTERNAL',
    text: 'internal error in ads sync',
  ),
  0x0751: (name: 'ADSERR_CLIENT_ADDHASH', text: 'hash table overflow'),
  0x0752: (
    name: 'ADSERR_CLIENT_REMOVEHASH',
    text: 'key not found in hash table',
  ),
  0x0753: (name: 'ADSERR_CLIENT_NOMORESYM', text: 'no more symbols in cache'),
  0x0754: (
    name: 'ADSERR_CLIENT_SYNCRESINVALID',
    text: 'invalid response received',
  ),
  0x0755: (name: 'ADSERR_CLIENT_SYNCPORTLOCKED', text: 'sync port is locked'),
};

/// A short hex rendering of an ADS error [code] (`0x` + at least 4 lower-case
/// hex digits), used for synthetic names and [AdsException.toString].
String _hex(int code) => '0x${code.toRadixString(16).padLeft(4, '0')}';

/// The `AdsDef.h` constant name for [code], or a synthetic `ADS error 0x…`
/// name when the code is not in the table.
///
/// Never throws: a real PLC can return a code newer than this table, and it
/// must still surface a usable identifier rather than crashing the mapper.
String adsErrorName(int code) =>
    _adsErrorTable[code]?.name ?? 'ADS error ${_hex(code)}';

/// The canonical operator-facing text for [code], or a generic
/// `unknown ADS error code` message when the code is not in the table.
///
/// Never throws (see [adsErrorName]).
String adsErrorText(int code) =>
    _adsErrorTable[code]?.text ?? 'unknown ADS error code';

/// A device-level ADS error surfaced as a typed exception.
///
/// This is a distinct family from `MalformedFrameException` (wire framing) and
/// `AdsTimeoutException` / `AdsConnectionException` (transport). It carries the
/// raw [code] so callers can branch on it, the `AdsDef.h` constant [name], and
/// the canonical [message] text. Use [AdsException.fromCode] to build one from a
/// non-zero ADS `result` or AMS header `errorCode`.
class AdsException implements Exception {
  /// Creates an exception from an explicit [code], [name], and [message]. Most
  /// callers should use [AdsException.fromCode] instead.
  const AdsException(this.code, this.name, this.message);

  /// Builds an exception for [code], composing the [name] and [message] from the
  /// error table (with a synthetic fallback for unknown codes — never throws).
  factory AdsException.fromCode(int code) =>
      AdsException(code, adsErrorName(code), adsErrorText(code));

  /// The raw ADS/AMS error code (the full u32 value, e.g. `0x0703`).
  final int code;

  /// The `AdsDef.h` constant name (e.g. `ADSERR_DEVICE_INVALIDOFFSET`), or a
  /// synthetic `ADS error 0x…` name for an unknown [code].
  final String name;

  /// The canonical operator-facing text (e.g. `invalid indexOffset`).
  final String message;

  /// Whether [code] is an ADS *device* error — the `[0x0700, 0x0740)` range.
  bool get isDeviceError => code >= 0x0700 && code < 0x0740;

  /// Whether [code] is an ADS *client* error — the `[0x0740, 0x07FF]` range.
  bool get isClientError => code >= 0x0740 && code <= 0x07FF;

  @override
  String toString() =>
      'AdsException: ADS error ${_hex(code)} ($name): $message';
}
