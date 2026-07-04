@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_ads/dart_ads.dart';
import 'package:test/test.dart';

import '../support/mock_server.dart';

/// Live symbol-browse (SYM-02) + typed round-trip (SYM-03) + raw escape-hatch
/// (SYM-04) proof against the C++ mock (07-03).
///
/// PARITY NOTE: No C++ AdsLibTest symbol scenario exists — flagged for the
/// Phase 9 parity audit; this is NOT TEST-05 coverage.
///
/// The mock serves a fixed 4-symbol table (MAIN.counter/flag/text/temp), all at
/// index group 0x4020. Its 0xF00B upload blob rounds entry 0's `entryLength` up
/// to a 4-byte boundary with trailing padding, so a correct browse of all four
/// entries proves the parser advances by `entryLength` (never by summed field
/// sizes) — the padded-entry evidence.
///
/// Each test starts its OWN mock + connection (connection-scoped value store),
/// so every typed write/read-back is isolated. A generous per-request timeout
/// makes any failure a real command result, never a timeout (threat T-3-07).
void main() {
  const requestTimeout = Duration(seconds: 10);

  AmsConnection newConnection() => AmsConnection(
        SocketTransport(),
        source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
        target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      );

  Future<AdsClient> connectClient() async {
    final server = await startMockServer();
    addTearDown(server.stop);

    final conn = newConnection();
    addTearDown(conn.close);
    await conn.connect('127.0.0.1', server.port);

    return AdsClient(
      conn,
      target: AmsAddr(AmsNetId.parse('192.168.0.1.1.1'), AmsPort.plcTc3),
      source: AmsAddr(AmsNetId.parse('192.168.0.100.1.1'), 40001),
    );
  }

  test('browseSymbols returns the 4-symbol table', () async {
    // SYM-02: SYM_UPLOADINFO (0xF00C) then SYM_UPLOAD (0xF00B), parsed into an
    // ordered List<AdsSymbolInfo>. Assert every field of every entry — the
    // padded entry 0 parsing correctly is the forward-compat proof.
    final client = await connectClient();

    final symbols = await client.browseSymbols(timeout: requestTimeout);
    expect(symbols, hasLength(4),
        reason: 'the mock serves exactly four symbols');

    // Expected table (07-03 mock_server.cpp kSymbolTable), in blob order.
    final expected = <AdsSymbolInfo>[
      const AdsSymbolInfo(
        name: 'MAIN.counter',
        typeName: 'DINT',
        comment: 'cycle counter',
        indexGroup: 0x4020,
        indexOffset: 0x00,
        size: 4,
        dataTypeId: 3, // ADST_INT32
        flags: 0,
      ),
      const AdsSymbolInfo(
        name: 'MAIN.flag',
        typeName: 'BOOL',
        comment: '',
        indexGroup: 0x4020,
        indexOffset: 0x04,
        size: 1,
        dataTypeId: 33, // ADST_BIT
        flags: 0,
      ),
      const AdsSymbolInfo(
        name: 'MAIN.text',
        typeName: 'STRING(80)',
        comment: '',
        indexGroup: 0x4020,
        indexOffset: 0x08,
        size: 81,
        dataTypeId: 30, // ADST_STRING
        flags: 0,
      ),
      const AdsSymbolInfo(
        name: 'MAIN.temp',
        typeName: 'LREAL',
        comment: 'temperature',
        indexGroup: 0x4020,
        indexOffset: 0x60,
        size: 8,
        dataTypeId: 5, // ADST_REAL64
        flags: 0,
      ),
    ];

    for (var i = 0; i < expected.length; i++) {
      final s = symbols[i];
      final e = expected[i];
      expect(s.name, equals(e.name), reason: 'entry $i name');
      expect(s.typeName, equals(e.typeName), reason: 'entry $i typeName');
      expect(s.comment, equals(e.comment), reason: 'entry $i comment');
      expect(s.indexGroup, equals(e.indexGroup), reason: 'entry $i iGroup');
      expect(s.indexOffset, equals(e.indexOffset), reason: 'entry $i iOffs');
      expect(s.size, equals(e.size), reason: 'entry $i size');
      expect(s.dataTypeId, equals(e.dataTypeId), reason: 'entry $i dataTypeId');
      expect(s.flags, equals(e.flags), reason: 'entry $i flags');
    }
  });

  test('typed round-trips DINT/BOOL/STRING/LREAL', () async {
    // SYM-03: each typed convenience method encodes, resolves+writes+releases,
    // then resolves+reads+releases, and the read-back equals the written value —
    // proving the codec + handle path agree with the mock store end-to-end.
    final client = await connectClient();

    // DINT (i32) — MAIN.counter.
    const dint = -1234567;
    await client.writeDintByName('MAIN.counter', dint, timeout: requestTimeout);
    expect(await client.readDintByName('MAIN.counter', timeout: requestTimeout),
        equals(dint));

    // BOOL — MAIN.flag.
    await client.writeBoolByName('MAIN.flag', true, timeout: requestTimeout);
    expect(await client.readBoolByName('MAIN.flag', timeout: requestTimeout),
        isTrue);
    await client.writeBoolByName('MAIN.flag', false, timeout: requestTimeout);
    expect(await client.readBoolByName('MAIN.flag', timeout: requestTimeout),
        isFalse);

    // STRING — MAIN.text: a short value that NUL-terminates well inside the
    // 81-byte buffer, proving decode stops at the first NUL and ignores padding.
    const text = 'hello plc';
    await client.writeStringByName('MAIN.text', text, 81,
        timeout: requestTimeout);
    expect(
        await client.readStringByName('MAIN.text', 81, timeout: requestTimeout),
        equals(text));

    // LREAL (f64) — MAIN.temp.
    const lreal = 21.375; // exactly representable in f64
    await client.writeLrealByName('MAIN.temp', lreal, timeout: requestTimeout);
    expect(await client.readLrealByName('MAIN.temp', timeout: requestTimeout),
        equals(lreal));
  });

  test('raw readByHandle returns unparsed LREAL bytes (SYM-04)', () async {
    // SYM-04 escape hatch: the raw read path returns the device's bytes with NO
    // codec applied. Write a known LREAL through the typed method, then resolve a
    // handle and read the raw 8-byte buffer — it must equal the LREAL encoding.
    final client = await connectClient();

    const value = 3.5; // exactly representable in f64
    await client.writeLrealByName('MAIN.temp', value, timeout: requestTimeout);

    final handle =
        await client.getHandleByName('MAIN.temp', timeout: requestTimeout);
    final raw = await client.readByHandle(handle, 8, timeout: requestTimeout);
    await client.releaseHandle(handle, timeout: requestTimeout);

    final expectedBytes = Uint8List(8);
    ByteData.sublistView(expectedBytes).setFloat64(0, value, Endian.little);

    expect(raw, isA<Uint8List>());
    expect(raw, equals(expectedBytes),
        reason: 'the raw hatch returns unparsed little-endian LREAL bytes');
  });
}
