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
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
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

// Inbound max-frame guard, mirroring the Dart FrameAssembler's 4 MiB cap: a
// single hostile 6-byte wrapper declaring a multi-GiB length must not make
// the server buffer everything the peer sends. The cap also keeps
// `sizeof(AmsTcpHeader) + length` well inside size_t on 32-bit builds, where
// 6 + 0xFFFFFFFF would otherwise wrap and cause a heap overread.
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

// Wrap an ADS-payload Frame in the 32-byte AoEHeader and the 6-byte AmsTcpHeader,
// exactly mirroring AmsConnection::Write: prepend<AoEHeader> then
// prepend<AmsTcpHeader>{frame.size()} so the wrapper length = 32 + payload.
// The AoEHeader ctor hardcodes AMS_REQUEST in leStateFlags (upstream only ever
// builds requests), so for a response we patch that single field to AMS_RESPONSE
// after layering — the struct exposes no public setter.
static std::vector<uint8_t> wrapResponse(Frame& f, uint16_t cmdId,
                                         const AmsNetId& target, uint16_t targetPort,
                                         const AmsNetId& source, uint16_t sourcePort,
                                         uint32_t invokeId)
{
    const AoEHeader aoe(target, targetPort, source, sourcePort, cmdId,
                        static_cast<uint32_t>(f.size()), invokeId);
    f.prepend<AoEHeader>(aoe);
    f.prepend<AmsTcpHeader>(AmsTcpHeader{ static_cast<uint32_t>(f.size()) });

    std::vector<uint8_t> bytes(f.data(), f.data() + f.size());
    const size_t off = sizeof(AmsTcpHeader) + kStateFlagsInAms;
    bytes[off] = static_cast<uint8_t>(AoEHeader::AMS_RESPONSE & 0xFF);
    bytes[off + 1] = static_cast<uint8_t>((AoEHeader::AMS_RESPONSE >> 8) & 0xFF);
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

// ---- Live accept loop (built in Phase 1; exercised over a socket in Phase 2) -
static int runServer(int fixedPort, TransmitMode mode, size_t fragmentN)
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
        uint8_t chunk[4096];
        bool dropConnection = false;
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
                if (tcp.length() >= sizeof(AoEHeader)) {
                    const AoEHeader aoe(inbuf.data() + sizeof(AmsTcpHeader));
                    switch (aoe.cmdId()) {
                    case AoEHeader::READ_DEVICE_INFO: {
                        // Response addressing INVERTS the request's:
                        // target = request source (the client),
                        // source = request target (the PLC/us).
                        const std::vector<uint8_t> res = buildReadDeviceInfoRes(
                            aoe.sourceAddr(), aoe.sourcePort(), aoe.targetAddr(),
                            aoe.targetPort(), aoe.invokeId());
                        sendResponse(fd, res, mode, fragmentN, coalesceBuf);
                        break;
                    }
                    default:
                        // Unknown command: silently ignored in Phase 1; the
                        // command table grows in later phases.
                        break;
                    }
                }
                inbuf.erase(inbuf.begin(), inbuf.begin() + frameLen);
            }
            if (dropConnection) {
                break;
            }
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
        } else {
            fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            return 2;
        }
    }

    if (selftest) {
        return runSelftest(goldenPath);
    }
    return runServer(fixedPort, mode, fragmentN);
}
