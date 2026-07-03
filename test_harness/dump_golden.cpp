// SPDX-License-Identifier: MIT
//
// dump_golden — emits byte-authoritative ADS reference frames as committed hex
// fixtures for the pure-Dart codec to validate against.
//
// The frames are authoritative BY CONSTRUCTION: the AMS header (AoEHeader, 32 B)
// and the AMS/TCP wrapper (AmsTcpHeader, 6 B) are layered with the SAME
// #pragma pack(1) structs and Frame::prepend serialization the reference
// Beckhoff C++ AdsLib puts on the wire — never hand-typed. Request ADS payloads
// that map onto an AmsHeader.h struct (AoERequestHeader, AoEReadWriteReqHeader,
// AdsWriteCtrlRequest) are also built from those structs via Frame::prepend.
//
// Fixture values are DETERMINISTIC so the goldens are reproducible and diffs are
// meaningful:
//   target NetId 192.168.0.1.1.1   port 851   (AMSPORT_R0_PLC_TC3 / 0x0353)
//   source NetId 192.168.0.100.1.1 port 40001 (0x9c41)
//   invokeId 1
//   stateFlags 0x0004 (request) / 0x0005 (response)
//
// The AoEHeader constructor hardcodes AMS_REQUEST in leStateFlags; response
// frames therefore have that one field patched to AMS_RESPONSE after layering
// (the struct offers no public way to set it, and upstream only ever builds
// requests). Everything else is produced by the structs directly.
//
// Usage: dump_golden [output_dir]   (default output_dir = "test/golden/")
// No sockets, no threads.

#include "AmsHeader.h"
#include "AdsDef.h"
#include "Frame.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// ---- Deterministic fixture identities -------------------------------------
static const AmsNetId kTarget(192, 168, 0, 1, 1, 1);
static const uint16_t kTargetPort = AMSPORT_R0_PLC_TC3; // 851 = 0x0353
static const AmsNetId kSource(192, 168, 0, 100, 1, 1);
static const uint16_t kSourcePort = 40001; // 0x9c41
static const uint32_t kInvokeId = 1;

// ---- Little-endian scalar helpers for building response ADS payloads -------
// (Responses are not produced by upstream's send path, so their body fields are
// written as explicit LE scalars; the AMS/TCP + AMS headers still come from the
// structs below via Frame::prepend.)
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

// Offset of AoEHeader::leStateFlags within the 32-byte AMS header:
//   targetNetId[6] leTargetPort[2] sourceNetId[6] leSourcePort[2] leCmdId[2] => 18
static const size_t kStateFlagsInAms = 18;

// Wrap an ADS-payload Frame in the 32-byte AoEHeader and 6-byte AmsTcpHeader
// (exactly mirroring AmsConnection::Write: prepend<AoEHeader> then
// prepend<AmsTcpHeader>{frame.size()} so the wrapper length = 32 + payload).
//
// A real ADS response inverts the request's addressing: it travels TO the
// original source (the client) FROM the original target (the PLC). Requests
// are addressed target=kTarget/source=kSource; responses swap the pair.
static std::vector<uint8_t> wrap(Frame& f, uint16_t cmdId, bool isResponse)
{
    const AoEHeader aoe = isResponse
        ? AoEHeader(kSource, kSourcePort, kTarget, kTargetPort, cmdId,
                    static_cast<uint32_t>(f.size()), kInvokeId)
        : AoEHeader(kTarget, kTargetPort, kSource, kSourcePort, cmdId,
                    static_cast<uint32_t>(f.size()), kInvokeId);
    f.prepend<AoEHeader>(aoe);
    f.prepend<AmsTcpHeader>(AmsTcpHeader{ static_cast<uint32_t>(f.size()) });

    std::vector<uint8_t> bytes(f.data(), f.data() + f.size());
    if (isResponse) {
        // Patch the single stateFlags field (offset 6 for AmsTcpHeader + 18).
        const size_t off = sizeof(AmsTcpHeader) + kStateFlagsInAms;
        bytes[off] = static_cast<uint8_t>(AoEHeader::AMS_RESPONSE & 0xFF);
        bytes[off + 1] = static_cast<uint8_t>((AoEHeader::AMS_RESPONSE >> 8) & 0xFF);
    }
    return bytes;
}

// Build a Frame from a raw payload byte vector (empty vector => empty frame).
static Frame payloadFrame(const std::vector<uint8_t>& p)
{
    return Frame(p.size(), p.empty() ? nullptr : p.data());
}

// ---- Hex file writer -------------------------------------------------------
// Returns false (and reports on stderr) when the fixture cannot be written.
// Silent write failures must not exit 0: CI's "goldens are reproducible" gate
// is `dump_golden && git diff --exit-code` — if nothing were written, the
// committed files would be untouched, the diff clean, and the gate would
// false-pass without a single byte having been reproduced.
static bool writeHex(const std::string& dir, const std::string& name,
                     const std::string& comment, const std::vector<uint8_t>& bytes)
{
    std::string path = dir;
    if (!path.empty() && path.back() != '/') {
        path += '/';
    }
    path += name + ".hex";

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << "# " << comment << "\n";
    static const char* kHex = "0123456789abcdef";
    std::string h;
    h.reserve(bytes.size() * 2);
    for (uint8_t b : bytes) {
        h.push_back(kHex[b >> 4]);
        h.push_back(kHex[b & 0x0F]);
    }
    out << h << "\n";
    out.flush();
    if (!out) {
        fprintf(stderr, "dump_golden: failed to write %s\n", path.c_str());
        return false;
    }
    return true;
}

int main(int argc, char** argv)
{
    const std::string dir = (argc > 1) ? argv[1] : "test/golden/";

    // Any failed fixture write must produce a non-zero exit so the CI
    // reproducibility gate cannot false-pass on a silent I/O error.
    bool ok = true;

    // --- ReadDeviceInfo 0x01 ------------------------------------------------
    // req: no ADS payload (the verified 38-byte anchor).
    {
        Frame f = payloadFrame({});
        ok &= writeHex(dir, "read_device_info_req",
                 "ReadDeviceInfo req: 192.168.0.1.1.1:851 <- 192.168.0.100.1.1:40001, invokeId 1, no payload",
                 wrap(f, AoEHeader::READ_DEVICE_INFO, false));
    }
    // res: result u32=0, version=3, revision=1, build=4024, name[16]="Dart ADS Mock".
    {
        std::vector<uint8_t> p;
        putU32(p, 0);              // result = 0 (success)
        p.push_back(3);            // version
        p.push_back(1);            // revision
        putU16(p, 4024);           // build = 0x0FB8
        const char name[16] = "Dart ADS Mock"; // 13 chars + NUL padding to 16
        for (int i = 0; i < 16; ++i) {
            p.push_back(static_cast<uint8_t>(name[i]));
        }
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "read_device_info_res",
                 "ReadDeviceInfo res: result 0, v3.1 build 4024, name 'Dart ADS Mock'",
                 wrap(f, AoEHeader::READ_DEVICE_INFO, true));
    }

    // --- Read 0x02 ----------------------------------------------------------
    // req: group 0xF005 (SYM_VALBYHND), offset 0x00000123 (handle), length 4.
    {
        Frame f = payloadFrame({});
        const AoERequestHeader req(0x0000F005u, 0x00000123u, 4u);
        f.prepend<AoERequestHeader>(req);
        ok &= writeHex(dir, "read_req",
                 "Read req: group 0xF005, offset 0x123, length 4",
                 wrap(f, AoEHeader::READ, false));
    }
    // res: result 0, readLength 4, data = 42 (0x0000002A LE).
    {
        std::vector<uint8_t> p;
        putU32(p, 0);          // result
        putU32(p, 4);          // readLength
        putU32(p, 42);         // 4-byte value payload
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "read_res",
                 "Read res: result 0, readLength 4, data 42",
                 wrap(f, AoEHeader::READ, true));
    }

    // --- Write 0x03 ---------------------------------------------------------
    // req: group 0xF005, offset 0x123, length 4, data = 42.
    {
        std::vector<uint8_t> data;
        putU32(data, 42);
        Frame f = payloadFrame({});
        f.prepend(data.data(), data.size());               // [data]
        const AoERequestHeader req(0x0000F005u, 0x00000123u,
                                   static_cast<uint32_t>(data.size()));
        f.prepend<AoERequestHeader>(req);                  // [reqHdr][data]
        ok &= writeHex(dir, "write_req",
                 "Write req: group 0xF005, offset 0x123, length 4, data 42",
                 wrap(f, AoEHeader::WRITE, false));
    }
    // res: result 0.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "write_res", "Write res: result 0",
                 wrap(f, AoEHeader::WRITE, true));
    }

    // --- ReadState 0x04 -----------------------------------------------------
    // req: no payload.
    {
        Frame f = payloadFrame({});
        ok &= writeHex(dir, "read_state_req", "ReadState req: no payload",
                 wrap(f, AoEHeader::READ_STATE, false));
    }
    // res: result 0, adsState 5 (RUN), deviceState 0.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);          // result
        putU16(p, 5);          // adsState = ADSSTATE_RUN
        putU16(p, 0);          // deviceState
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "read_state_res",
                 "ReadState res: result 0, adsState 5 (RUN), deviceState 0",
                 wrap(f, AoEHeader::READ_STATE, true));
    }

    // --- WriteControl 0x05 --------------------------------------------------
    // req: adsState 5 (RUN), devState 0, length 0 (no trailing data).
    {
        Frame f = payloadFrame({});
        const AdsWriteCtrlRequest req(5u, 0u, 0u);
        f.prepend<AdsWriteCtrlRequest>(req);
        ok &= writeHex(dir, "write_control_req",
                 "WriteControl req: adsState 5 (RUN), devState 0, length 0",
                 wrap(f, AoEHeader::WRITE_CONTROL, false));
    }
    // res: result 0.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "write_control_res", "WriteControl res: result 0",
                 wrap(f, AoEHeader::WRITE_CONTROL, true));
    }

    // --- ReadWrite 0x09 -----------------------------------------------------
    // req: group 0xF003 (GET_SYMHANDLE_BYNAME), offset 0, readLen 4, writeLen 8,
    //      writeData = "MAIN.foo".
    {
        const char* sym = "MAIN.foo";
        std::vector<uint8_t> writeData(sym, sym + 8);
        Frame f = payloadFrame({});
        f.prepend(writeData.data(), writeData.size());     // [writeData]
        const AoEReadWriteReqHeader req(0x0000F003u, 0x00000000u, 4u,
                                        static_cast<uint32_t>(writeData.size()));
        f.prepend<AoEReadWriteReqHeader>(req);             // [rwHdr][writeData]
        ok &= writeHex(dir, "read_write_req",
                 "ReadWrite req: group 0xF003, offset 0, readLen 4, writeLen 8, writeData 'MAIN.foo'",
                 wrap(f, AoEHeader::READ_WRITE, false));
    }
    // res: result 0, readLength 4, data = handle 0x80000001 (LE 01 00 00 80).
    {
        std::vector<uint8_t> p;
        putU32(p, 0);              // result
        putU32(p, 4);              // readLength
        putU32(p, 0x80000001u);    // returned symbol handle
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "read_write_res",
                 "ReadWrite res: result 0, readLength 4, data 0x80000001",
                 wrap(f, AoEHeader::READ_WRITE, true));
    }

    return ok ? 0 : 1;
}
