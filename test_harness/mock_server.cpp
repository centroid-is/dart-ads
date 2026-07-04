// SPDX-License-Identifier: MIT
//
// mock_server — a minimal C++ mock ADS server for the dart_ads integration
// tests. It reuses the SAME Beckhoff/ADS #pragma pack(1) framing structs the
// reference AdsLib puts on the wire (AmsTcpHeader / AoEHeader from AmsHeader.h,
// layered via Frame::prepend) so the canned responses are byte-accurate BY
// CONSTRUCTION, not by hand.
//
// The transport is a hand-rolled POSIX <sys/socket.h> accept loop (macOS + Linux
// are both POSIX) — we deliberately do NOT pull in AdsLib's Sockets.cpp / WinSock
// conditionals. AdsLib is reused for framing only, never for transport.
//
// Command table (intentionally minimal for Phase 1; grows in later phases per
// the locked decision):
//   ReadDeviceInfo (0x01) -> result 0, v3.1 build 4024, name "Dart ADS Mock"
//
// Modes:
//   --port N       bind a fixed port instead of an ephemeral (:0) port
//   --fragment N   send each response in N-byte chunks, one send() per chunk,
//                  with TCP_NODELAY so a single frame is spread across multiple
//                  TCP segments — exercises the Dart FrameAssembler's partial-
//                  frame reassembly (TEST-04).
//   --coalesce     buffer two response frames and emit them in a SINGLE send(),
//                  so two frames arrive in one TCP segment — exercises the
//                  FrameAssembler's ability to split coalesced frames (TEST-04).
//   --delay-ms N   DEFER the first response of a connection and flush it LAST
//                  (after usleep(N ms)); responses #2..N go out immediately. An
//                  inline pre-send sleep does NOT reorder (the mock answers
//                  frames in receive order), so two PIPELINED requests provably
//                  receive OUT-OF-ORDER responses — exercises the Dart invoke-ID
//                  correlation under response reordering (PROTO-03). Thread-free.
//   --close-after N close the socket on the Nth COMPLETE inbound request WITHOUT
//                  answering it, so the Dart client is left with at least one
//                  pending request that must fan out with a connection error
//                  (TRANS-03). Deterministic, thread-free mid-request disconnect.
//   --selftest [p] build the canned ReadDeviceInfo response in-process and
//                  compare it byte-for-byte against the committed golden
//                  (default p = test/golden/read_device_info_res.hex). Prints OK
//                  and exits 0 on match, prints a diff and exits 1 on mismatch.
//                  This is an automated byte-accuracy gate with NO socket — the
//                  live accept loop + readiness handshake are wired in Phase 2.
//
// Readiness handshake (Phase 2): after binding, the server prints exactly
//   LISTENING <port>\n
// to stdout and flushes, so the Dart test harness learns the ephemeral port and
// knows the socket is accepting — never a sleep.
//
// No threads. Single-connection, single-request-per-accept is sufficient for the
// Phase-1 build + selftest; concurrency and hostile-input hardening of the live
// accept loop are Phase-2 transport concerns.

#include "AmsHeader.h"
#include "AdsDef.h"
#include "Frame.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <utility>
#include <vector>

// ---- Deterministic identities (match the committed golden fixtures) --------
// The golden ReadDeviceInfo response was generated with these exact identities
// (see test_harness/dump_golden.cpp). --selftest reuses them so the in-process
// response is byte-identical to the committed golden.
static const AmsNetId kTarget(192, 168, 0, 1, 1, 1);
static const uint16_t kTargetPort = AMSPORT_R0_PLC_TC3; // 851 = 0x0353
static const AmsNetId kSource(192, 168, 0, 100, 1, 1);
static const uint16_t kSourcePort = 40001; // 0x9c41
static const uint32_t kGoldenInvokeId = 1;

// Offset of AoEHeader::leStateFlags within the 32-byte AMS header:
//   targetNetId[6] leTargetPort[2] sourceNetId[6] leSourcePort[2] leCmdId[2] => 18
static const size_t kStateFlagsInAms = 18;

// Offset of the AMS-header errorCode (u32) within the 32-byte AMS header:
//   ...leStateFlags[2]@18 leLength[4]@20 => leErrorCode@24. VERIFIED against
//   lib/src/protocol/ams_header.dart line 88.
static const size_t kAmsErrorCodeOffset = 24;

// ---- Magic index-group error fixtures (Phase 3) ----------------------------
// Two reserved, obviously-synthetic index groups let the integration/parity
// tests inject a REAL ADS error at each of the two error levels. The request's
// indexOffset chooses the error code, so a single fixture covers every code
// (the offset->code trick):
//   kErrResultGroup -> the ADS payload `result` u32 == request indexOffset
//                      (device/payload-level error; readLength=0, empty data).
//   kErrAmsGroup    -> the AMS-header errorCode == request indexOffset
//                      (router/transport-level error; payload result stays 0).
// e.g. a request to (kErrResultGroup, 0x703) yields ADSERR_DEVICE_INVALIDOFFSET;
// a request to (kErrAmsGroup, 0x0007) yields GLOBALERR_MISSING_ROUTE in the AMS
// header. See 03-RESEARCH.md "Magic index-group error fixtures" and the Phase 9
// parity audit / the Dart tests in 03-05.
static const uint32_t kErrResultGroup = 0xE7700000u;
static const uint32_t kErrAmsGroup = 0xE7700001u;

// ---- Magic notification fixtures (Phase 5) --------------------------------
// Two more obviously-synthetic index groups drive the deterministic
// notification tests (05-06):
//   kNotifyCountGroup    -> a Read returns the current active-handle count as a
//                           u32 (the in-band handle-leak proof: read 0 before
//                           subscribing, N after N adds, 0 after cancel/close).
//   kNotifyBurst2x2Group -> a Write emits ONE crafted 0x08 frame with 2 stamps
//                           x 2 samples (distinct timestamps/handles/data) — the
//                           fixture that proves the nested stamp/sample parser.
//   kNotifyHostileGroup  -> a Write emits ONE deliberately MALFORMED 0x08 frame
//                           (a sample whose declared size overruns the payload)
//                           whose AMS/TCP wrapper is well-formed, so it reaches
//                           the Dart notification parser as a complete frame and
//                           is CONTAINED there (droppedNotifications++, connection
//                           stays alive) — the hostile-frame survival proof
//                           (threat T-5-02). Then answers a normal WRITE result 0.
static const uint32_t kNotifyCountGroup = 0xE7700002u;
static const uint32_t kNotifyBurst2x2Group = 0xE7700003u;
static const uint32_t kNotifyHostileGroup = 0xE7700004u;

// Inbound max-frame guard, mirroring the Dart FrameAssembler's 4 MiB cap: a
// single hostile 6-byte wrapper declaring a multi-GiB length must not make
// the server buffer everything the peer sends. The cap also keeps
// `sizeof(AmsTcpHeader) + length` well inside size_t on 32-bit builds, where
// 6 + 0xFFFFFFFF would otherwise wrap and cause a heap overread. NOTE: the
// cap only covers the AMS/TCP `length` field — the per-command payload
// length fields (WRITE `length`, READ_WRITE `writeLength`) are validated in
// overflow-free subtraction form at their dispatch sites instead; READ's
// `length` and ADD_DEVICE_NOTIFICATION's `cbLength` are capped directly
// against kMaxFrameBytes at theirs (cbLength sizes every later notification
// allocation, so an uncapped 0xFFFFFFFF would 4-GiB-allocate on emission —
// WR-02).
static const uint32_t kMaxFrameBytes = 4 * 1024 * 1024;

// ---- Little-endian scalar helpers for the response ADS payload -------------
static void putU16(std::vector<uint8_t>& v, uint16_t x)
{
    v.push_back(static_cast<uint8_t>(x & 0xFF));
    v.push_back(static_cast<uint8_t>((x >> 8) & 0xFF));
}

static void putU32(std::vector<uint8_t>& v, uint32_t x)
{
    for (int i = 0; i < 4; ++i) {
        v.push_back(static_cast<uint8_t>((x >> (8 * i)) & 0xFF));
    }
}

// 8-byte little-endian writer, mirroring putU32 (8 shift iterations). Used for
// the FILETIME timestamp (u64) at the head of every 0x08 notification stamp.
static void putU64(std::vector<uint8_t>& v, uint64_t x)
{
    for (int i = 0; i < 8; ++i) {
        v.push_back(static_cast<uint8_t>((x >> (8 * i)) & 0xFF));
    }
}

// ---- Little-endian scalar readers for the inbound request ADS payload -------
// Every field read is BOUNDS-CHECKED against the payload length (bodyLen, itself
// derived from the already-capped tcp.length()) BEFORE dereferencing, so a short
// or hostile frame can never overread `inbuf` (threat T-3-03, ASVS V5). Explicit
// little-endian shifts (never memcpy/host-order) satisfy the CLAUDE.md endian
// rule and mirror putU16/putU32 so the codec is correct-by-inspection.
static bool getU16(const uint8_t* body, size_t bodyLen, size_t off, uint16_t& out)
{
    if (off + 2 > bodyLen) {
        return false;
    }
    out = static_cast<uint16_t>(static_cast<uint16_t>(body[off]) |
                                (static_cast<uint16_t>(body[off + 1]) << 8));
    return true;
}

static bool getU32(const uint8_t* body, size_t bodyLen, size_t off, uint32_t& out)
{
    if (off + 4 > bodyLen) {
        return false;
    }
    out = static_cast<uint32_t>(body[off]) |
          (static_cast<uint32_t>(body[off + 1]) << 8) |
          (static_cast<uint32_t>(body[off + 2]) << 16) |
          (static_cast<uint32_t>(body[off + 3]) << 24);
    return true;
}

// Wrap an ADS-payload Frame in the 32-byte AoEHeader and the 6-byte AmsTcpHeader,
// exactly mirroring AmsConnection::Write: prepend<AoEHeader> then
// prepend<AmsTcpHeader>{frame.size()} so the wrapper length = 32 + payload.
// The AoEHeader ctor hardcodes AMS_REQUEST in leStateFlags (upstream only ever
// builds requests), so for a response we patch that single field to AMS_RESPONSE
// after layering — the struct exposes no public setter.
//
// amsError (default 0): when non-zero, patch the AMS-header errorCode to this
// value — the SAME purely-additive technique used for stateFlags above, applied
// at the errorCode wire offset (kAmsErrorCodeOffset). The default leaves the
// ReadDeviceInfo call site — and thus the golden/selftest — byte-identical.
static std::vector<uint8_t> wrapResponse(Frame& f, uint16_t cmdId,
                                         const AmsNetId& target, uint16_t targetPort,
                                         const AmsNetId& source, uint16_t sourcePort,
                                         uint32_t invokeId, uint32_t amsError = 0)
{
    const AoEHeader aoe(target, targetPort, source, sourcePort, cmdId,
                        static_cast<uint32_t>(f.size()), invokeId);
    f.prepend<AoEHeader>(aoe);
    f.prepend<AmsTcpHeader>(AmsTcpHeader{ static_cast<uint32_t>(f.size()) });

    std::vector<uint8_t> bytes(f.data(), f.data() + f.size());
    const size_t off = sizeof(AmsTcpHeader) + kStateFlagsInAms;
    bytes[off] = static_cast<uint8_t>(AoEHeader::AMS_RESPONSE & 0xFF);
    bytes[off + 1] = static_cast<uint8_t>((AoEHeader::AMS_RESPONSE >> 8) & 0xFF);
    if (amsError != 0) {
        const size_t eoff = sizeof(AmsTcpHeader) + kAmsErrorCodeOffset;
        bytes[eoff] = static_cast<uint8_t>(amsError & 0xFF);
        bytes[eoff + 1] = static_cast<uint8_t>((amsError >> 8) & 0xFF);
        bytes[eoff + 2] = static_cast<uint8_t>((amsError >> 16) & 0xFF);
        bytes[eoff + 3] = static_cast<uint8_t>((amsError >> 24) & 0xFF);
    }
    return bytes;
}

// Build the canned ReadDeviceInfo (0x01) response frame:
//   result u32=0, version u8=3, revision u8=1, build u16=4024, name[16].
static std::vector<uint8_t> buildReadDeviceInfoRes(const AmsNetId& target, uint16_t targetPort,
                                                  const AmsNetId& source, uint16_t sourcePort,
                                                  uint32_t invokeId)
{
    std::vector<uint8_t> p;
    putU32(p, 0);    // result = 0 (success)
    p.push_back(3);  // version
    p.push_back(1);  // revision
    putU16(p, 4024); // build = 0x0FB8
    const char name[16] = "Dart ADS Mock"; // 13 chars + NUL padding to 16
    for (int i = 0; i < 16; ++i) {
        p.push_back(static_cast<uint8_t>(name[i]));
    }
    Frame f(p.size(), p.data());
    return wrapResponse(f, AoEHeader::READ_DEVICE_INFO, target, targetPort,
                        source, sourcePort, invokeId);
}

// ---- Golden hex parser (mirrors test/support/hex.dart) ---------------------
// Reads a '#'-commented hex fixture, strips comments + whitespace, decodes to
// bytes. Returns false on a missing/odd-length/invalid file.
static bool readGoldenHex(const std::string& path, std::vector<uint8_t>& out)
{
    std::ifstream in(path);
    if (!in) {
        return false;
    }
    std::string cleaned;
    std::string line;
    while (std::getline(in, line)) {
        const size_t hash = line.find('#');
        if (hash != std::string::npos) {
            line.erase(hash); // drop inline comment
        }
        for (char c : line) {
            if (!std::isspace(static_cast<unsigned char>(c))) {
                cleaned.push_back(c);
            }
        }
    }
    if (cleaned.size() % 2 != 0) {
        return false;
    }
    out.clear();
    out.reserve(cleaned.size() / 2);
    for (size_t i = 0; i < cleaned.size(); i += 2) {
        const std::string byteHex = cleaned.substr(i, 2);
        char* end = nullptr;
        const long v = std::strtol(byteHex.c_str(), &end, 16);
        if (end != byteHex.c_str() + 2) {
            return false;
        }
        out.push_back(static_cast<uint8_t>(v));
    }
    return true;
}

static void printHex(const std::vector<uint8_t>& bytes)
{
    static const char* kHex = "0123456789abcdef";
    for (uint8_t b : bytes) {
        putchar(kHex[b >> 4]);
        putchar(kHex[b & 0x0F]);
    }
    putchar('\n');
}

// ---- --selftest: byte-accuracy gate without a socket -----------------------
static int runSelftest(const std::string& goldenPath)
{
    // The golden response is addressed like a real ADS response: TO the
    // client (kSource identities) FROM the PLC (kTarget identities) — the
    // inverse of the request addressing.
    const std::vector<uint8_t> got =
        buildReadDeviceInfoRes(kSource, kSourcePort, kTarget, kTargetPort, kGoldenInvokeId);

    std::vector<uint8_t> golden;
    if (!readGoldenHex(goldenPath, golden)) {
        fprintf(stderr, "selftest: cannot read golden '%s'\n", goldenPath.c_str());
        return 1;
    }
    if (got == golden) {
        printf("OK\n");
        return 0;
    }
    fprintf(stderr, "selftest: MISMATCH against %s\n", goldenPath.c_str());
    fprintf(stderr, "  expected (%zu bytes): ", golden.size());
    fflush(stderr);
    printHex(golden);
    fprintf(stderr, "  actual   (%zu bytes): ", got.size());
    fflush(stderr);
    printHex(got);
    return 1;
}

// ---- Transmission modes (drive the Phase-2 FrameAssembler, TEST-04) --------
enum class TransmitMode { Normal, Fragment, Coalesce };

// Blocking write of the whole buffer in a single logical response.
//
// A send() interrupted by a signal returns -1/EINTR — retry, it is not an
// error. A peer that closed mid-response yields EPIPE (reachable because
// main() ignores SIGPIPE), which reports as failure so the caller drops the
// connection instead of the whole process dying.
static bool sendAll(int fd, const uint8_t* data, size_t size)
{
    size_t sent = 0;
    while (sent < size) {
        const ssize_t n = send(fd, data + sent, size - sent, 0);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

// Emit a response frame per the selected transmission mode.
//   Fragment: one send() per N-byte chunk (TCP_NODELAY) -> multiple segments.
//   Coalesce: buffer frames; flush two-at-a-time in a single send() -> one
//             segment carrying two frames.
//   Normal:   single send().
static void sendResponse(int fd, const std::vector<uint8_t>& frame, TransmitMode mode,
                         size_t fragmentN, std::vector<uint8_t>& coalesceBuf)
{
    switch (mode) {
    case TransmitMode::Fragment: {
        const size_t n = fragmentN ? fragmentN : 1;
        for (size_t off = 0; off < frame.size(); off += n) {
            const size_t chunk = std::min(n, frame.size() - off);
            if (!sendAll(fd, frame.data() + off, chunk)) {
                return;
            }
        }
        break;
    }
    case TransmitMode::Coalesce: {
        coalesceBuf.insert(coalesceBuf.end(), frame.begin(), frame.end());
        // Flush once two frames are buffered, so both land in one segment.
        // (A trailing single frame is flushed by the caller after the loop.)
        // Heuristic: flush when buffer holds at least two ReadDeviceInfo frames.
        if (coalesceBuf.size() >= frame.size() * 2) {
            sendAll(fd, coalesceBuf.data(), coalesceBuf.size());
            coalesceBuf.clear();
        }
        break;
    }
    case TransmitMode::Normal:
    default:
        sendAll(fd, frame.data(), frame.size());
        break;
    }
}

// ---- 0x08 device-notification emission (Phase 5) ---------------------------
// The unsolicited notification stream is doubly nested:
//   length u32, stamps u32,
//   per stamp { timestamp u64 (FILETIME), sampleCount u32,
//               per sample { handle u32, size u32, data[size] } }
// These value types model one crafted frame; emitNotification serialises them,
// backfills the self-describing `length`, wraps as a DEVICE_NOTIFICATION (0x08)
// frame addressed TO the client, and sends it immediately via sendResponse.
struct NotifySample {
    uint32_t handle;
    std::vector<uint8_t> data;
};
struct NotifyStamp {
    uint64_t timestamp; // FILETIME: 100ns ticks since 1601-01-01 UTC
    std::vector<NotifySample> samples;
};

// A deterministic base FILETIME (a whole number of microseconds, i.e. a multiple
// of 10) so the Dart FILETIME->DateTime round-trip is lossless in the goldens.
// 132000000000000000 ≈ 2019-03-19T14:40:00Z.
static const uint64_t kMockFiletimeBase = 132000000000000000ull;

static void emitNotification(int fd, TransmitMode mode, size_t fragmentN,
                             std::vector<uint8_t>& coalesceBuf,
                             const AmsNetId& rTarget, uint16_t rTargetPort,
                             const AmsNetId& rSource, uint16_t rSourcePort,
                             const std::vector<NotifyStamp>& stamps)
{
    std::vector<uint8_t> p;
    putU32(p, 0); // length placeholder (backfilled below)
    putU32(p, static_cast<uint32_t>(stamps.size()));
    for (const NotifyStamp& st : stamps) {
        putU64(p, st.timestamp);
        putU32(p, static_cast<uint32_t>(st.samples.size()));
        for (const NotifySample& sm : st.samples) {
            putU32(p, sm.handle);
            putU32(p, static_cast<uint32_t>(sm.data.size()));
            p.insert(p.end(), sm.data.begin(), sm.data.end());
        }
    }
    // Backfill the self-describing length = all bytes following the length field.
    const uint32_t length = static_cast<uint32_t>(p.size() - 4);
    p[0] = static_cast<uint8_t>(length & 0xFF);
    p[1] = static_cast<uint8_t>((length >> 8) & 0xFF);
    p[2] = static_cast<uint8_t>((length >> 16) & 0xFF);
    p[3] = static_cast<uint8_t>((length >> 24) & 0xFF);

    Frame f(p.size(), p.data());
    // invokeId 0: unsolicited (Dart demuxes 0x08 on commandId before invokeId).
    std::vector<uint8_t> frame =
        wrapResponse(f, AoEHeader::DEVICE_NOTIFICATION, rTarget, rTargetPort,
                     rSource, rSourcePort, 0);
    sendResponse(fd, frame, mode, fragmentN, coalesceBuf);
}

// Emit ONE deliberately MALFORMED 0x08 notification frame. The AMS/TCP wrapper is
// well-formed (correct length), so the Dart FrameAssembler hands the whole frame
// to the notification parser as a complete frame; the PAYLOAD is internally
// inconsistent (a single sample declares size 0xFFFFFFFF, far past the payload
// end), so parseNotificationStream throws and the connection's 0x08 dispatch
// CONTAINS it (droppedNotifications++), never poisoning the assembler or killing
// other subscriptions (threat T-5-02). The self-describing `length` field is set
// consistent with the actual bytes so the failure is the sample-size overrun, not
// a trivially-detectable length mismatch.
static void emitHostileNotification(int fd, TransmitMode mode, size_t fragmentN,
                                    std::vector<uint8_t>& coalesceBuf,
                                    const AmsNetId& rTarget, uint16_t rTargetPort,
                                    const AmsNetId& rSource, uint16_t rSourcePort)
{
    std::vector<uint8_t> p;
    putU32(p, 0);                    // length placeholder (backfilled below)
    putU32(p, 1);                    // stamps = 1
    putU64(p, kMockFiletimeBase);    // stamp timestamp
    putU32(p, 1);                    // sampleCount = 1
    putU32(p, 0x1u);                 // sample handle
    putU32(p, 0xFFFFFFFFu);          // sample size: overruns the payload -> throws
    // No sample data bytes follow: the declared size cannot be satisfied.
    const uint32_t length = static_cast<uint32_t>(p.size() - 4);
    p[0] = static_cast<uint8_t>(length & 0xFF);
    p[1] = static_cast<uint8_t>((length >> 8) & 0xFF);
    p[2] = static_cast<uint8_t>((length >> 16) & 0xFF);
    p[3] = static_cast<uint8_t>((length >> 24) & 0xFF);

    Frame f(p.size(), p.data());
    std::vector<uint8_t> frame =
        wrapResponse(f, AoEHeader::DEVICE_NOTIFICATION, rTarget, rTargetPort,
                     rSource, rSourcePort, 0);
    sendResponse(fd, frame, mode, fragmentN, coalesceBuf);
}

// ---- Live accept loop (built in Phase 1; exercised over a socket in Phase 2) -
//
// delayMs > 0 (--delay-ms): defer the FIRST response of each connection and
//   flush it LAST (after usleep(delayMs ms)); later responses go immediately —
//   deterministically inverting the order of two pipelined requests.
// closeAfter > 0 (--close-after): close the connection on the Nth complete
//   inbound request frame WITHOUT answering it, leaving a pending request that
//   must fan out on the client. Both are thread-free and orthogonal to
//   --fragment/--coalesce (timing/lifecycle vs segmentation).
static int runServer(int fixedPort, TransmitMode mode, size_t fragmentN,
                     int delayMs, int closeAfter, int notifyBurst)
{
    const int listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) {
        perror("socket");
        return 1;
    }
    int yes = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<uint16_t>(fixedPort)); // 0 => ephemeral

    if (bind(listenFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("bind");
        close(listenFd);
        return 1;
    }
    if (listen(listenFd, 8) < 0) {
        perror("listen");
        close(listenFd);
        return 1;
    }

    // Resolve the actual (possibly ephemeral) port and announce readiness.
    sockaddr_in bound{};
    socklen_t boundLen = sizeof(bound);
    if (getsockname(listenFd, reinterpret_cast<sockaddr*>(&bound), &boundLen) < 0) {
        perror("getsockname");
        close(listenFd);
        return 1;
    }
    const uint16_t port = ntohs(bound.sin_port);
    printf("LISTENING %u\n", port);
    fflush(stdout);

    for (;;) {
        const int fd = accept(listenFd, nullptr, nullptr);
        if (fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            break;
        }
        int nodelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

        // Server-side reassembly: buffer inbound bytes until a full AMS/TCP
        // frame (6-byte wrapper length + 32-byte AMS header + payload) is
        // present, then answer. This mirrors the reassembly the Dart client
        // must perform, so the mock is faithful under real TCP segmentation.
        std::vector<uint8_t> inbuf;
        std::vector<uint8_t> coalesceBuf;
        // Connection-scoped data store + ADS state (research Pitfall 3 / T-3-01):
        // declared inside the per-connection block so each accepted connection —
        // i.e. each startMockServer() in each integration test — begins CLEAN and
        // write-back persists only "within a session", never leaking across tests.
        std::map<std::pair<uint32_t, uint32_t>, std::vector<uint8_t>> store;
        // Per-connection notification table: handle -> {group, offset, cbLength,
        // transMode}. Declared here (like `store`) so each accepted connection —
        // i.e. each integration test — starts CLEAN and handle numbers never leak
        // across tests. nextHandle starts at 1 and increments per successful ADD.
        std::map<uint32_t, std::array<uint32_t, 4>> notes;
        uint32_t nextHandle = 1;
        uint16_t curAdsState = static_cast<uint16_t>(ADSSTATE_RUN); // 5 — seed to RUN
        uint16_t curDeviceState = 0;
        // Seed one fixture matching the read_req golden key so a pure Read (with no
        // prior Write) returns meaningful bytes.
        store[{ 0xF005u, 0x123u }] = { 0x2A, 0x00, 0x00, 0x00 };
        uint8_t chunk[4096];
        bool dropConnection = false;
        // Connection-scoped --delay-ms state: hold response #1, flush it last.
        std::vector<uint8_t> deferred;
        bool haveDeferred = false;
        int respCount = 0;
        // Connection-scoped --close-after counter: complete inbound requests.
        int reqCount = 0;
        // Set once the --close-after path has already close(fd)'d this
        // connection, so the teardown below neither sends nor double-closes.
        bool closedByCloseAfter = false;
        for (;;) {
            const ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) {
                break; // peer closed or error
            }
            inbuf.insert(inbuf.end(), chunk, chunk + n);

            // Drain every complete frame currently buffered.
            for (;;) {
                if (inbuf.size() < sizeof(AmsTcpHeader)) {
                    break;
                }
                const AmsTcpHeader tcp(inbuf.data());
                if (tcp.length() > kMaxFrameBytes) {
                    // Hostile/corrupt length field: drop the connection
                    // rather than buffering an unbounded frame.
                    dropConnection = true;
                    break;
                }
                const size_t frameLen =
                    sizeof(AmsTcpHeader) + static_cast<size_t>(tcp.length());
                if (inbuf.size() < frameLen) {
                    break; // wait for the rest of this frame
                }
                // A complete inbound request frame is present. --close-after N:
                // on the Nth complete request, close WITHOUT answering it, so
                // the client is left with at least one pending request to fan
                // out. The outer accept loop keeps serving later connections.
                ++reqCount;
                if (closeAfter > 0 && reqCount >= closeAfter) {
                    close(fd);
                    closedByCloseAfter = true;
                    break; // leave this request unanswered
                }
                if (tcp.length() >= sizeof(AoEHeader)) {
                    const AoEHeader aoe(inbuf.data() + sizeof(AmsTcpHeader));
                    // Response addressing INVERTS the request's: target = request
                    // source (the client), source = request target (the PLC/us).
                    const AmsNetId rTarget = aoe.sourceAddr();
                    const uint16_t rTargetPort = aoe.sourcePort();
                    const AmsNetId rSource = aoe.targetAddr();
                    const uint16_t rSourcePort = aoe.targetPort();
                    const uint32_t rInvoke = aoe.invokeId();
                    // ADS request body (bounds-checked via bodyLen below).
                    const uint8_t* body =
                        inbuf.data() + sizeof(AmsTcpHeader) + sizeof(AoEHeader);
                    const size_t bodyLen =
                        static_cast<size_t>(tcp.length()) - sizeof(AoEHeader);

                    // A response is only emitted when haveRes becomes true; a
                    // malformed/short request leaves haveRes false (no answer),
                    // exactly like the Phase-1 "unknown command" default.
                    std::vector<uint8_t> res;
                    bool haveRes = false;

                    // --- Magic index-group error fixtures (both error levels) ---
                    // Intercept BEFORE the normal per-command dispatch: any request
                    // whose indexGroup == a magic sentinel injects a real ADS error
                    // whose value is the request's indexOffset (offset->code trick).
                    uint32_t magicGroup = 0, magicOffset = 0;
                    const bool isMagic =
                        getU32(body, bodyLen, 0, magicGroup) &&
                        getU32(body, bodyLen, 4, magicOffset) &&
                        (magicGroup == kErrResultGroup || magicGroup == kErrAmsGroup);
                    if (isMagic) {
                        std::vector<uint8_t> p;
                        // payload result: chosen code for the payload-level fixture,
                        // 0 for the AMS-level fixture (error lives in the AMS header).
                        putU32(p, magicGroup == kErrResultGroup ? magicOffset : 0u);
                        putU32(p, 0); // readLength = 0 (empty data — Read/ReadWrite shape)
                        Frame f(p.size(), p.data());
                        const uint32_t amsErr =
                            (magicGroup == kErrAmsGroup) ? magicOffset : 0u;
                        res = wrapResponse(f, aoe.cmdId(), rTarget, rTargetPort,
                                           rSource, rSourcePort, rInvoke, amsErr);
                        haveRes = true;
                    }

                    switch (isMagic ? AoEHeader::INVALID : aoe.cmdId()) {
                    case AoEHeader::READ_DEVICE_INFO: {
                        res = buildReadDeviceInfoRes(rTarget, rTargetPort,
                                                     rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::READ: {
                        // Read (0x02): group u32, offset u32, length u32.
                        uint32_t group, offset, length;
                        if (!getU32(body, bodyLen, 0, group) ||
                            !getU32(body, bodyLen, 4, offset) ||
                            !getU32(body, bodyLen, 8, length) ||
                            length > kMaxFrameBytes) {
                            break; // malformed/hostile: no response
                        }
                        // Magic active-handle-count group: return the current
                        // number of live notification handles as a u32 — the
                        // in-band leak proof (read 0 / N / 0 across the test).
                        if (group == kNotifyCountGroup) {
                            std::vector<uint8_t> p;
                            putU32(p, 0); // result = 0
                            putU32(p, 4); // readLength = 4
                            putU32(p, static_cast<uint32_t>(notes.size()));
                            Frame f(p.size(), p.data());
                            res = wrapResponse(f, AoEHeader::READ, rTarget,
                                               rTargetPort, rSource, rSourcePort,
                                               rInvoke);
                            haveRes = true;
                            break;
                        }
                        std::vector<uint8_t> data(length, 0);
                        const auto it = store.find({ group, offset });
                        if (it != store.end()) {
                            const size_t n = std::min(
                                static_cast<size_t>(length), it->second.size());
                            std::copy(it->second.begin(),
                                      it->second.begin() + n, data.begin());
                        }
                        std::vector<uint8_t> p;
                        putU32(p, 0);      // result = 0
                        putU32(p, length); // readLength
                        p.insert(p.end(), data.begin(), data.end());
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::READ, rTarget,
                                           rTargetPort, rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::WRITE: {
                        // Write (0x03): group u32, offset u32, length u32, data.
                        uint32_t group, offset, length;
                        // Subtraction form: `12 + length > bodyLen` would wrap
                        // on 32-bit size_t for a hostile length near 2^32 and
                        // bypass the rejection (heap overread).
                        if (!getU32(body, bodyLen, 0, group) ||
                            !getU32(body, bodyLen, 4, offset) ||
                            !getU32(body, bodyLen, 8, length) ||
                            bodyLen < 12 ||
                            static_cast<size_t>(length) > bodyLen - 12) {
                            break; // malformed/short: data not fully present
                        }
                        // Magic 2x2 group: emit ONE crafted frame with 2 stamps x
                        // 2 samples (distinct timestamps/handles/data) that proves
                        // the nested parser, then answer a normal WRITE result 0.
                        // Deliberately NOT stored — this group is a pure trigger.
                        if (group == kNotifyBurst2x2Group) {
                            emitNotification(fd, mode, fragmentN, coalesceBuf,
                                rTarget, rTargetPort, rSource, rSourcePort,
                                {
                                    { kMockFiletimeBase,
                                      { { 1u, { 0xAA, 0xBB } },
                                        { 2u, { 0xCC, 0xDD } } } },
                                    { kMockFiletimeBase + 100000000ull,
                                      { { 1u, { 0x11, 0x22 } },
                                        { 2u, { 0x33, 0x44 } } } },
                                });
                            std::vector<uint8_t> p;
                            putU32(p, 0); // result = 0
                            Frame f(p.size(), p.data());
                            res = wrapResponse(f, AoEHeader::WRITE, rTarget,
                                               rTargetPort, rSource, rSourcePort,
                                               rInvoke);
                            haveRes = true;
                            break;
                        }
                        // Magic hostile group: emit ONE malformed 0x08 frame the
                        // Dart parser must drop (connection stays alive), then a
                        // normal WRITE result 0. Not stored — a pure trigger.
                        if (group == kNotifyHostileGroup) {
                            emitHostileNotification(fd, mode, fragmentN, coalesceBuf,
                                rTarget, rTargetPort, rSource, rSourcePort);
                            std::vector<uint8_t> p;
                            putU32(p, 0); // result = 0
                            Frame f(p.size(), p.data());
                            res = wrapResponse(f, AoEHeader::WRITE, rTarget,
                                               rTargetPort, rSource, rSourcePort,
                                               rInvoke);
                            haveRes = true;
                            break;
                        }
                        store[{ group, offset }] =
                            std::vector<uint8_t>(body + 12, body + 12 + length);
                        // Write-triggered serverOnChange: emit ONE 1-stamp x
                        // 1-sample frame to every handle watching this exact
                        // (group, offset), carrying the written bytes truncated/
                        // padded to that handle's cbLength.
                        for (const auto& kv : notes) {
                            if (kv.second[0] == group && kv.second[1] == offset) {
                                const uint32_t h = kv.first;
                                const uint32_t cb = kv.second[2];
                                std::vector<uint8_t> data(cb, 0);
                                const size_t ncopy = std::min(
                                    static_cast<size_t>(cb),
                                    static_cast<size_t>(length));
                                std::copy(body + 12, body + 12 + ncopy,
                                          data.begin());
                                emitNotification(fd, mode, fragmentN, coalesceBuf,
                                                 rTarget, rTargetPort, rSource,
                                                 rSourcePort,
                                                 { { kMockFiletimeBase,
                                                     { { h, data } } } });
                            }
                        }
                        std::vector<uint8_t> p;
                        putU32(p, 0); // result = 0
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::WRITE, rTarget,
                                           rTargetPort, rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::READ_WRITE: {
                        // ReadWrite (0x09): group u32, offset u32, readLength u32,
                        // writeLength u32, writeData[writeLength].
                        uint32_t group, offset, readLength, writeLength;
                        // Subtraction form for writeLength (see WRITE above):
                        // the additive check wraps on 32-bit size_t.
                        if (!getU32(body, bodyLen, 0, group) ||
                            !getU32(body, bodyLen, 4, offset) ||
                            !getU32(body, bodyLen, 8, readLength) ||
                            !getU32(body, bodyLen, 12, writeLength) ||
                            readLength > kMaxFrameBytes ||
                            bodyLen < 16 ||
                            static_cast<size_t>(writeLength) > bodyLen - 16) {
                            break; // malformed/hostile
                        }
                        // Write-then-read the SAME key.
                        store[{ group, offset }] = std::vector<uint8_t>(
                            body + 16, body + 16 + writeLength);
                        std::vector<uint8_t> data(readLength, 0);
                        const auto it = store.find({ group, offset });
                        if (it != store.end()) {
                            const size_t n = std::min(
                                static_cast<size_t>(readLength), it->second.size());
                            std::copy(it->second.begin(),
                                      it->second.begin() + n, data.begin());
                        }
                        std::vector<uint8_t> p;
                        putU32(p, 0);          // result = 0
                        putU32(p, readLength); // readLength
                        p.insert(p.end(), data.begin(), data.end());
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::READ_WRITE, rTarget,
                                           rTargetPort, rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::READ_STATE: {
                        // ReadState (0x04): no request payload. Reflect the
                        // connection-scoped current state (stateful WriteControl).
                        std::vector<uint8_t> p;
                        putU32(p, 0);              // result = 0
                        putU16(p, curAdsState);    // adsState
                        putU16(p, curDeviceState); // deviceState
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::READ_STATE, rTarget,
                                           rTargetPort, rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::WRITE_CONTROL: {
                        // WriteControl (0x05): adsState u16, deviceState u16,
                        // length u32, data[length]. Stateful: a later ReadState
                        // observably returns the state set here.
                        uint16_t adsState, deviceState;
                        if (!getU16(body, bodyLen, 0, adsState) ||
                            !getU16(body, bodyLen, 2, deviceState)) {
                            break; // malformed/short
                        }
                        curAdsState = adsState;
                        curDeviceState = deviceState;
                        std::vector<uint8_t> p;
                        putU32(p, 0); // result = 0
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::WRITE_CONTROL, rTarget,
                                           rTargetPort, rSource, rSourcePort, rInvoke);
                        haveRes = true;
                        break;
                    }
                    case AoEHeader::ADD_DEVICE_NOTIFICATION: {
                        // AddDeviceNotification (0x06): 40-byte request —
                        // group u32, offset u32, cbLength u32, transMode u32,
                        // maxDelay u32, cycleTime u32, then 16 reserved bytes.
                        // Every field is bounds-checked; a short body yields no
                        // response (existing short-frame discipline, threat T-5-07).
                        uint32_t group, offset, cbLength, transMode, maxDelay, cycleTime;
                        if (!getU32(body, bodyLen, 0, group) ||
                            !getU32(body, bodyLen, 4, offset) ||
                            !getU32(body, bodyLen, 8, cbLength) ||
                            !getU32(body, bodyLen, 12, transMode) ||
                            !getU32(body, bodyLen, 16, maxDelay) ||
                            !getU32(body, bodyLen, 20, cycleTime)) {
                            break; // malformed/short: no response
                        }
                        // Cap cbLength (WR-02): it sizes EVERY later emission
                        // buffer (write-trigger + burst paths), so a hostile
                        // 0xFFFFFFFF would std::bad_alloc a 4 GiB vector on
                        // the next trigger and kill the whole harness — and
                        // even a "successful" giant frame would exceed the
                        // Dart assembler's 4 MiB cap and poison the client
                        // connection. Reject WITH a real ADS error (result
                        // 0x705 ADSERR_DEVICE_INVALIDSIZE, handle 0, nothing
                        // registered) so the client fails fast instead of
                        // timing out on silence.
                        if (cbLength > kMaxFrameBytes) {
                            std::vector<uint8_t> p;
                            putU32(p, 0x705u); // ADSERR_DEVICE_INVALIDSIZE
                            putU32(p, 0u);     // no handle assigned
                            Frame f(p.size(), p.data());
                            res = wrapResponse(f, AoEHeader::ADD_DEVICE_NOTIFICATION,
                                               rTarget, rTargetPort, rSource,
                                               rSourcePort, rInvoke);
                            haveRes = true;
                            break;
                        }
                        const uint32_t handle = nextHandle++;
                        notes[handle] = { group, offset, cbLength, transMode };
                        std::vector<uint8_t> p;
                        putU32(p, 0);      // result = 0 (success)
                        putU32(p, handle); // PLC-assigned notification handle
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::ADD_DEVICE_NOTIFICATION,
                                           rTarget, rTargetPort, rSource, rSourcePort,
                                           rInvoke);
                        // --notify-burst N: emit N single-sample frames for the new
                        // handle right AFTER the ADD response, back-to-back on the
                        // same connection so the response and the first notification
                        // coalesce into one inbound TCP chunk. This exercises the
                        // first-listen race the Dart client MUST win via synchronous
                        // handle registration (05-RESEARCH Pitfall 2 / Pattern 2A):
                        // the handle is only knowable from the response, so a
                        // notification can only be routed once the response has been
                        // correlated — emitting AFTER the response is the winnable
                        // same-chunk race (emitting BEFORE would be unroutable by any
                        // client, as the handle is not yet known). The response is
                        // sent here (not via the outer haveRes path) so the bursts
                        // provably follow it; --notify-burst is never combined with
                        // --delay-ms in the suite, so bypassing the deferral is safe.
                        if (notifyBurst > 0) {
                            sendResponse(fd, res, mode, fragmentN, coalesceBuf);
                            for (int b = 0; b < notifyBurst; ++b) {
                                const std::vector<uint8_t> data(cbLength, 0);
                                emitNotification(fd, mode, fragmentN, coalesceBuf,
                                                 rTarget, rTargetPort, rSource,
                                                 rSourcePort,
                                                 { { kMockFiletimeBase,
                                                     { { handle, data } } } });
                            }
                            haveRes = false; // already sent above
                        } else {
                            haveRes = true;
                        }
                        break;
                    }
                    case AoEHeader::DEL_DEVICE_NOTIFICATION: {
                        // DeleteDeviceNotification (0x07): handle u32 -> result u32.
                        // A known handle is erased (result 0); an unknown handle
                        // returns ADSERR_CLIENT_REMOVEHASH (0x752) and never frees
                        // an unrelated entry (threat T-5-08 / C++ parity).
                        uint32_t handle;
                        if (!getU32(body, bodyLen, 0, handle)) {
                            break; // malformed/short: no response
                        }
                        const uint32_t result = notes.erase(handle) ? 0u : 0x752u;
                        std::vector<uint8_t> p;
                        putU32(p, result);
                        Frame f(p.size(), p.data());
                        res = wrapResponse(f, AoEHeader::DEL_DEVICE_NOTIFICATION,
                                           rTarget, rTargetPort, rSource, rSourcePort,
                                           rInvoke);
                        haveRes = true;
                        break;
                    }
                    default:
                        // Unknown command: silently ignored; the command table
                        // grows in later phases.
                        break;
                    }

                    if (haveRes) {
                        // --delay-ms N: defer response #1, send #2..N now.
                        ++respCount;
                        if (delayMs > 0 && respCount == 1) {
                            deferred = res;
                            haveDeferred = true;
                        } else {
                            sendResponse(fd, res, mode, fragmentN, coalesceBuf);
                        }
                    }
                }
                inbuf.erase(inbuf.begin(), inbuf.begin() + frameLen);
            }
            if (dropConnection || closedByCloseAfter) {
                break;
            }
            // Once at least one later response has been sent, flush the deferred
            // first response LAST (after the delay) so two pipelined requests
            // provably receive out-of-order responses.
            if (haveDeferred && respCount >= 2) {
                usleep(static_cast<useconds_t>(delayMs) * 1000);
                sendResponse(fd, deferred, mode, fragmentN, coalesceBuf);
                haveDeferred = false;
            }
        }
        if (closedByCloseAfter) {
            // --close-after already closed the socket; nothing more to flush.
            continue;
        }
        // Only one request ever arrived: flush the still-deferred first
        // response so it is never lost at connection close.
        if (haveDeferred) {
            sendResponse(fd, deferred, mode, fragmentN, coalesceBuf);
            haveDeferred = false;
        }
        // Flush any single coalesced frame still pending at connection close.
        if (!coalesceBuf.empty()) {
            sendAll(fd, coalesceBuf.data(), coalesceBuf.size());
            coalesceBuf.clear();
        }
        close(fd);
    }

    close(listenFd);
    return 0;
}

// ---- argv parsing ----------------------------------------------------------
int main(int argc, char** argv)
{
    // A client that disconnects mid-send (test teardown, a crashed Dart test,
    // a timeout kill) must not kill the server: without this, send() to a
    // closed peer raises SIGPIPE, whose default disposition terminates the
    // whole process — listening socket included, so every later test hangs.
    // signal(SIGPIPE, SIG_IGN) is portable across Linux + macOS (macOS lacks
    // MSG_NOSIGNAL); with SIGPIPE ignored, send() fails with EPIPE and
    // sendAll's error path drops just that connection.
    signal(SIGPIPE, SIG_IGN);

    int fixedPort = 0; // 0 => ephemeral
    TransmitMode mode = TransmitMode::Normal;
    size_t fragmentN = 0;
    int delayMs = 0;   // 0 => no first-response deferral
    int closeAfter = 0; // 0 => never force-close mid-request
    int notifyBurst = 0; // 0 => no immediate emission on ADD
    bool selftest = false;
    std::string goldenPath = "test/golden/read_device_info_res.hex";

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--selftest") {
            selftest = true;
            // Optional explicit golden path as the next non-flag argument.
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                goldenPath = argv[++i];
            }
        } else if (arg == "--port") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--port requires a value\n");
                return 2;
            }
            fixedPort = std::atoi(argv[++i]);
        } else if (arg == "--fragment") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--fragment requires a value\n");
                return 2;
            }
            fragmentN = static_cast<size_t>(std::atoi(argv[++i]));
            mode = TransmitMode::Fragment;
        } else if (arg == "--coalesce") {
            mode = TransmitMode::Coalesce;
        } else if (arg == "--delay-ms") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--delay-ms requires a value\n");
                return 2;
            }
            delayMs = std::atoi(argv[++i]);
        } else if (arg == "--close-after") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--close-after requires a value\n");
                return 2;
            }
            closeAfter = std::atoi(argv[++i]);
        } else if (arg == "--notify-burst") {
            if (i + 1 >= argc) {
                fprintf(stderr, "--notify-burst requires a value\n");
                return 2;
            }
            notifyBurst = std::atoi(argv[++i]);
        } else {
            fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            return 2;
        }
    }

    if (selftest) {
        return runSelftest(goldenPath);
    }
    return runServer(fixedPort, mode, fragmentN, delayMs, closeAfter, notifyBurst);
}
