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

// Per-item error sentinel for SUMUP batches — MUST match mock_server.cpp:124.
// A batch item whose inner indexGroup == kErrResultGroup fails: its result
// word carries the item's inner indexOffset (a real ADS error code) and it
// contributes ZERO data bytes. This 0-data-bytes-on-failure convention is the
// frozen mid-batch-alignment contract shared by mock + Dart decoder + goldens
// (06-RESEARCH A1).
static const uint32_t kErrResultGroup = 0xE7700000u;

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

static void putU64(std::vector<uint8_t>& v, uint64_t x)
{
    for (int i = 0; i < 8; ++i) {
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

    // --- SUMUP_READ 0xF080 (batched read) ----------------------------------
    // Outer ReadWrite (0x09) to group 0xF080, indexOffset = N = 3 (item count).
    // Inner write-buffer = 3 x 12B item headers (ig,io,len). Item[1] targets the
    // per-item error sentinel kErrResultGroup with io=0x703 (ADSERR_DEVICE_
    // INVALIDOFFSET) so its result word is non-zero and it emits 0 data bytes —
    // freezing the mid-batch-failure alignment (06-RESEARCH A1).
    //   item0: ig 0x4020, io 0x10, len 4
    //   item1: ig kErrResultGroup, io 0x703, len 2  (FAILS -> 0 data bytes)
    //   item2: ig 0x4020, io 0x20, len 8
    // req readLength = N*4 + Sum(len) = 12 + (4+2+8) = 26 (upper bound).
    {
        std::vector<uint8_t> wbuf;
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000010u); putU32(wbuf, 4u);
        putU32(wbuf, kErrResultGroup); putU32(wbuf, 0x00000703u); putU32(wbuf, 2u);
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000020u); putU32(wbuf, 8u);
        const uint32_t N = 3;
        const uint32_t readLength = N * 4 + (4 + 2 + 8); // 26
        Frame f = payloadFrame({});
        f.prepend(wbuf.data(), wbuf.size());               // [writeData]
        const AoEReadWriteReqHeader req(0x0000F080u, N, readLength,
                                        static_cast<uint32_t>(wbuf.size()));
        f.prepend<AoEReadWriteReqHeader>(req);             // [rwHdr][writeData]
        ok &= writeHex(dir, "sum_read_req",
                 "SUMUP_READ req: group 0xF080, N 3, readLength 26; items "
                 "[0x4020:0x10 len4] [kErrResultGroup:0x703 len2 (fails)] "
                 "[0x4020:0x20 len8]",
                 wrap(f, AoEHeader::READ_WRITE, false));
    }
    // res: outer result 0, inner readLength = errRegion(3*4=12) + data(4+0+8=12)
    //      = 24. errRegion: [0, 0x703, 0]; data: item0 4B then item2 8B (item1
    //      failed -> contributes 0 bytes). This is the frozen mid-batch failure.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);          // outer ADS result = 0
        putU32(p, 24);         // inner readLength = sumData.size()
        // error region (N x u32)
        putU32(p, 0);          // item0 err = 0
        putU32(p, 0x00000703u);// item1 err = its inner io (FAILED)
        putU32(p, 0);          // item2 err = 0
        // data region (successful items only, at requested lengths)
        p.push_back(0x11); p.push_back(0x22); p.push_back(0x33); p.push_back(0x44); // item0 4B
        // item1: 0 data bytes (failed)
        p.push_back(0xaa); p.push_back(0xbb); p.push_back(0xcc); p.push_back(0xdd);
        p.push_back(0xee); p.push_back(0xff); p.push_back(0x01); p.push_back(0x02); // item2 8B
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "sum_read_res",
                 "SUMUP_READ res: result 0, readLength 24; errs [0,0x703,0]; "
                 "data item0 11223344, item1 (failed, 0B), item2 aabbccddeeff0102",
                 wrap(f, AoEHeader::READ_WRITE, true));
    }

    // --- SUMUP_WRITE 0xF081 (batched write) --------------------------------
    // Outer ReadWrite to group 0xF081, indexOffset = N = 3. Inner write-buffer =
    // 3 x 12B headers (ig,io,len) THEN concatenated distinct write payloads.
    //   item0: ig 0x4020, io 0x10, len 4, data deadbeef
    //   item1: ig 0x4020, io 0x20, len 2, data 1234
    //   item2: ig 0x4020, io 0x30, len 3, data 556677
    // req readLength = N*4 = 12 (one result word per item, nothing else back).
    {
        std::vector<uint8_t> wbuf;
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000010u); putU32(wbuf, 4u);
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000020u); putU32(wbuf, 2u);
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000030u); putU32(wbuf, 3u);
        // concatenated write payloads (item order)
        wbuf.push_back(0xde); wbuf.push_back(0xad); wbuf.push_back(0xbe); wbuf.push_back(0xef);
        wbuf.push_back(0x12); wbuf.push_back(0x34);
        wbuf.push_back(0x55); wbuf.push_back(0x66); wbuf.push_back(0x77);
        const uint32_t N = 3;
        const uint32_t readLength = N * 4; // 12
        Frame f = payloadFrame({});
        f.prepend(wbuf.data(), wbuf.size());
        const AoEReadWriteReqHeader req(0x0000F081u, N, readLength,
                                        static_cast<uint32_t>(wbuf.size()));
        f.prepend<AoEReadWriteReqHeader>(req);
        ok &= writeHex(dir, "sum_write_req",
                 "SUMUP_WRITE req: group 0xF081, N 3, readLength 12; items "
                 "[0x4020:0x10 len4 deadbeef] [0x4020:0x20 len2 1234] "
                 "[0x4020:0x30 len3 556677]",
                 wrap(f, AoEHeader::READ_WRITE, false));
    }
    // res: outer result 0, inner readLength = N*4 = 12; error region = 3 x u32,
    //      all 0 (no data region for WRITE).
    {
        std::vector<uint8_t> p;
        putU32(p, 0);   // outer ADS result = 0
        putU32(p, 12);  // inner readLength = N*4
        putU32(p, 0);   // item0 err
        putU32(p, 0);   // item1 err
        putU32(p, 0);   // item2 err
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "sum_write_res",
                 "SUMUP_WRITE res: result 0, readLength 12; errs [0,0,0]",
                 wrap(f, AoEHeader::READ_WRITE, true));
    }

    // --- SUMUP_READWRITE 0xF082 (batched read-write) -----------------------
    // Outer ReadWrite to group 0xF082, indexOffset = N = 3. Inner write-buffer =
    // 3 x 16B headers (ig,io,rLen,wLen) THEN concatenated write payloads.
    // Item[1] requests rLen 8 but writes only 2 bytes, so the mock reads back
    // min(rLen, stored)=2 -> its RETURNED length (2) < requested (8), pinning the
    // returned-length slicing rule.
    //   item0: ig 0x4020, io 0x10, rLen 4, wLen 4, data 01020304
    //   item1: ig 0x4020, io 0x20, rLen 8, wLen 2, data aabb   (retLen 2 < 8)
    //   item2: ig 0x4020, io 0x30, rLen 3, wLen 3, data 778899
    // req readLength = N*8 + Sum(rLen) = 24 + (4+8+3) = 39.
    {
        std::vector<uint8_t> wbuf;
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000010u); putU32(wbuf, 4u); putU32(wbuf, 4u);
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000020u); putU32(wbuf, 8u); putU32(wbuf, 2u);
        putU32(wbuf, 0x00004020u); putU32(wbuf, 0x00000030u); putU32(wbuf, 3u); putU32(wbuf, 3u);
        // concatenated write payloads (item order)
        wbuf.push_back(0x01); wbuf.push_back(0x02); wbuf.push_back(0x03); wbuf.push_back(0x04);
        wbuf.push_back(0xaa); wbuf.push_back(0xbb);
        wbuf.push_back(0x77); wbuf.push_back(0x88); wbuf.push_back(0x99);
        const uint32_t N = 3;
        const uint32_t readLength = N * 8 + (4 + 8 + 3); // 39
        Frame f = payloadFrame({});
        f.prepend(wbuf.data(), wbuf.size());
        const AoEReadWriteReqHeader req(0x0000F082u, N, readLength,
                                        static_cast<uint32_t>(wbuf.size()));
        f.prepend<AoEReadWriteReqHeader>(req);
        ok &= writeHex(dir, "sum_readwrite_req",
                 "SUMUP_READWRITE req: group 0xF082, N 3, readLength 39; items "
                 "[0x4020:0x10 rLen4 wLen4 01020304] "
                 "[0x4020:0x20 rLen8 wLen2 aabb (retLen 2<8)] "
                 "[0x4020:0x30 rLen3 wLen3 778899]",
                 wrap(f, AoEHeader::READ_WRITE, false));
    }
    // res: outer result 0, inner readLength = errRegion(3*(err+retLen)=24) +
    //      data(4+2+3=9) = 33. Headers: (0,4)(0,2)(0,3) — item1 returns 2 < the
    //      requested 8. Data at RETURNED lengths, item order.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);   // outer ADS result = 0
        putU32(p, 33);  // inner readLength = sumData.size()
        // error+returnedLength region (N x (err u32, retLen u32))
        putU32(p, 0); putU32(p, 4); // item0: err 0, retLen 4
        putU32(p, 0); putU32(p, 2); // item1: err 0, retLen 2 (< requested 8)
        putU32(p, 0); putU32(p, 3); // item2: err 0, retLen 3
        // data region at RETURNED lengths
        p.push_back(0x01); p.push_back(0x02); p.push_back(0x03); p.push_back(0x04); // item0 4B
        p.push_back(0xaa); p.push_back(0xbb);                                       // item1 2B
        p.push_back(0x77); p.push_back(0x88); p.push_back(0x99);                    // item2 3B
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "sum_readwrite_res",
                 "SUMUP_READWRITE res: result 0, readLength 33; headers "
                 "(0,4)(0,2)(0,3); data item0 01020304, item1 aabb, item2 778899",
                 wrap(f, AoEHeader::READ_WRITE, true));
    }

    // --- AddDeviceNotification 0x06 ----------------------------------------
    // req: the 40-byte AdsAddDeviceNotificationRequest layout (AmsHeader.h:92),
    //      written as explicit LE scalars in the SAME field order as the pure
    //      Dart buildAddNotificationPayload. Uses the C++ parity attribs
    //      {cbLength=1, nTransMode=SERVERCYCLE(3), nMaxDelay=0,
    //      nCycleTime=1000000 (100ns = 100ms)} from 05-RESEARCH so this golden
    //      doubles as the parity anchor. group 0x4020, offset 4.
    {
        std::vector<uint8_t> p;
        putU32(p, 0x00004020u); // indexGroup
        putU32(p, 4u);          // indexOffset
        putU32(p, 1u);          // cbLength
        putU32(p, 3u);          // nTransMode = ADSTRANS_SERVERCYCLE
        putU32(p, 0u);          // nMaxDelay (100ns)
        putU32(p, 1000000u);    // nCycleTime (100ns) = 100 ms
        for (int i = 0; i < 16; ++i) {
            p.push_back(0); // reserved[16] — the classic off-by-16 guard
        }
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "add_notification_req",
                 "AddDeviceNotification req: group 0x4020, offset 4, cbLength 1, "
                 "transMode 3 (SERVERCYCLE), maxDelay 0, cycleTime 1000000, reserved[16]=0",
                 wrap(f, AoEHeader::ADD_DEVICE_NOTIFICATION, false));
    }
    // res: result 0, notificationHandle 0x0A0B0C0D (a distinctive handle).
    {
        std::vector<uint8_t> p;
        putU32(p, 0);           // result
        putU32(p, 0x0A0B0C0Du); // notificationHandle
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "add_notification_res",
                 "AddDeviceNotification res: result 0, handle 0x0A0B0C0D",
                 wrap(f, AoEHeader::ADD_DEVICE_NOTIFICATION, true));
    }

    // --- DeleteDeviceNotification 0x07 -------------------------------------
    // req: notificationHandle 0x0A0B0C0D (matches the Add response handle).
    {
        std::vector<uint8_t> p;
        putU32(p, 0x0A0B0C0Du); // notificationHandle
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "del_notification_req",
                 "DeleteDeviceNotification req: handle 0x0A0B0C0D",
                 wrap(f, AoEHeader::DEL_DEVICE_NOTIFICATION, false));
    }
    // res: result 0.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);           // result
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "del_notification_res",
                 "DeleteDeviceNotification res: result 0",
                 wrap(f, AoEHeader::DEL_DEVICE_NOTIFICATION, true));
    }

    // --- Device notification stream 0x08 (unsolicited) — nested 2x2 --------
    // A doubly-nested frame (NotificationDispatcher.cpp:56) that proves the
    // full stamp x sample loop: 2 stamps, each with distinct FILETIME and 2
    // samples of distinct handle/size/data.
    //   stamp0 @ ts=132000000000000000: {h1,4B: 11 22 33 44} {h2,2B: aa bb}
    //   stamp1 @ ts=132000000010000000: {h1,1B: 55}          {h3,0B: (none)}
    // Both timestamps are whole-microsecond FILETIMEs (multiples of 10) so the
    // FILETIME->DateTime round-trip is lossless. The leading `length` is
    // backfilled to the byte count AFTER it.
    {
        std::vector<uint8_t> p;
        putU32(p, 0);           // length (backfilled below)
        putU32(p, 2);           // stamps = 2
        // stamp 0
        putU64(p, 132000000000000000ULL); // timestamp (FILETIME)
        putU32(p, 2);           // sampleCount
        putU32(p, 1); putU32(p, 4);       // sample0: handle 1, size 4
        p.push_back(0x11); p.push_back(0x22); p.push_back(0x33); p.push_back(0x44);
        putU32(p, 2); putU32(p, 2);       // sample1: handle 2, size 2
        p.push_back(0xaa); p.push_back(0xbb);
        // stamp 1
        putU64(p, 132000000010000000ULL); // timestamp (1s later)
        putU32(p, 2);           // sampleCount
        putU32(p, 1); putU32(p, 1);       // sample0: handle 1, size 1
        p.push_back(0x55);
        putU32(p, 3); putU32(p, 0);       // sample1: handle 3, size 0 (no data)
        // Backfill the leading length = bytes following the length field.
        const uint32_t len = static_cast<uint32_t>(p.size() - 4);
        p[0] = static_cast<uint8_t>(len & 0xFF);
        p[1] = static_cast<uint8_t>((len >> 8) & 0xFF);
        p[2] = static_cast<uint8_t>((len >> 16) & 0xFF);
        p[3] = static_cast<uint8_t>((len >> 24) & 0xFF);
        Frame f = payloadFrame(p);
        ok &= writeHex(dir, "notification_stream",
                 "DeviceNotification stream: 2 stamps x 2 samples "
                 "(stamp0 ts=132000000000000000 {h1:11223344}{h2:aabb}, "
                 "stamp1 ts=132000000010000000 {h1:55}{h3:})",
                 wrap(f, AoEHeader::DEVICE_NOTIFICATION, true));
    }

    return ok ? 0 : 1;
}
