/// Pure-Dart client library for the Beckhoff ADS protocol (AMS/TCP).
///
/// This barrel is the package's curated public surface. It re-exports only the
/// protocol codec types a consumer needs to build and parse AMS/TCP frames:
/// the address value types, the three fixed-layout headers, the six per-command
/// request encoders and typed response decoders, the streaming frame
/// reassembler, the framing exception, and the wire-protocol constants.
///
/// Everything under `src/` that is not re-exported here (internal helpers such
/// as the frame composer and the C-string/length-guard utilities) stays private
/// to the package — those symbols are library-private in their source files and
/// are intentionally not part of the public contract.
library;

/// AMS address value types: the 6-byte [AmsNetId] and the [AmsAddr]
/// (net id + u16 port) pair.
export 'src/protocol/ams_net_id.dart' show AmsNetId, AmsAddr;

/// The 6-byte AMS/TCP frame wrapper.
export 'src/protocol/ams_tcp_header.dart' show AmsTcpHeader;

/// The 32-byte AMS header codec.
export 'src/protocol/ams_header.dart' show AmsHeader;

/// The six core ADS commands: request encoders and their typed response
/// decoders, plus the sealed [AdsResponse] hierarchy.
export 'src/protocol/commands.dart'
    show
        // Sealed response hierarchy.
        AdsResponse,
        ReadDeviceInfoResponse,
        ReadResponse,
        WriteResponse,
        ReadStateResponse,
        WriteControlResponse,
        ReadWriteResponse,
        // Request encoders.
        encodeReadDeviceInfoRequest,
        encodeReadRequest,
        encodeWriteRequest,
        encodeReadStateRequest,
        encodeWriteControlRequest,
        encodeReadWriteRequest,
        // Response decoders.
        decodeReadDeviceInfoResponse,
        decodeReadResponse,
        decodeWriteResponse,
        decodeReadStateResponse,
        decodeWriteControlResponse,
        decodeReadWriteResponse;

/// The streaming AMS/TCP frame reassembler.
export 'src/protocol/frame_assembler.dart' show FrameAssembler;

/// The wire-level framing exception.
export 'src/protocol/exceptions.dart' show MalformedFrameException;

/// The ADS-agnostic transport seam: the [AdsTransport] interface and its
/// `dart:io` [SocketTransport] implementation. `FakeTransport` is intentionally
/// NOT exported — it is an in-memory test double reached via its `src/` path in
/// same-package unit tests, not part of the public contract.
export 'src/transport/transport.dart' show AdsTransport;
export 'src/transport/socket_transport.dart' show SocketTransport;

/// The transport-error-family exceptions, distinct from [MalformedFrameException]
/// so callers can catch timeouts and disconnects separately.
export 'src/connection/exceptions.dart'
    show AdsTimeoutException, AdsConnectionException;

/// The [AmsConnection] (L4): invoke-ID correlation, per-request timeout, the
/// notification demux hook, and single-shot disconnect fan-out. The internal
/// `PendingRequest` record stays package-private and is intentionally NOT
/// exported.
export 'src/connection/ams_connection.dart' show AmsConnection;

/// Wire-protocol constants (command IDs, state flags, ports, index groups,
/// device-data offsets, run states). The ADS error family lives in
/// [AdsException] / [adsErrorName] / [adsErrorText] below, not here.
export 'src/protocol/constants.dart'
    show
        AdsCommandId,
        AmsStateFlags,
        AmsPort,
        AdsIndexGroup,
        AdsDeviceDataOffset,
        AdsState;

/// The ADS error family: the full `AdsDef.h` error table exposed via
/// [adsErrorName] / [adsErrorText], and the typed [AdsException] (with
/// `isDeviceError` / `isClientError` range helpers) — a distinct family from
/// [MalformedFrameException], [AdsTimeoutException], and [AdsConnectionException].
export 'src/protocol/ads_error.dart'
    show AdsException, adsErrorName, adsErrorText;

/// The router-layer [AdsRoutingException] — an [AdsException] subtype carrying
/// the [AmsNetId] a routing failure concerns plus actionable remediation text
/// (local missing-route `0x0007`; direct-mode reverse-route timeout `0x0745`).
export 'src/router/routing_exception.dart' show AdsRoutingException;

/// The [AdsClient] (L6-lite): the idiomatic async API over the six core ADS
/// commands, with both-levels [AdsException] mapping. Its typed returns
/// [AdsStateInfo] (from `readState`) and [DeviceInfo] (from `readDeviceInfo`)
/// are pure value types.
export 'src/client/ads_client.dart' show AdsClient;
export 'src/client/ads_types.dart' show AdsStateInfo, DeviceInfo;

/// The [AmsRouter] registry: the local-AMS-port allocator (base 30000, 128
/// slots), the target-NetId → [AmsConnection] route table, and the mutable
/// source address with `<ip>.1.1` auto-derive. The `TransportFactory` typedef
/// is its injectable connection seam. (Plan 04 adds the transport-mode targets.)
export 'src/router/ams_router.dart' show AmsRouter, TransportFactory;
