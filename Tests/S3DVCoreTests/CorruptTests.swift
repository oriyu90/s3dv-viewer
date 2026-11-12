import XCTest
@testable import S3DVCore

/// The native reader/decoder must reject exactly what the Python Reader and Packet.decode reject.
final class CorruptTests: XCTestCase {
    private var sample: Data!

    override func setUpWithError() throws {
        sample = try Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "cube_orbit", withExtension: "s3dv", subdirectory: "Fixtures/recordings")))
    }

    // MARK: container-level rejections (mirror Reader.__init__)

    func testTruncatedTailRejectedAsBadIndexOffset() throws {
        // The index offset itself stays within the truncated file, so the reader
        // (like Python's) fails at the index-row count instead of the offset.
        try withTempFile(Data(sample.dropLast(5))) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Invalid index"), "\(err)")
            }
        }
    }

    func testBadMagicRejected() throws {
        try withTempFile(self.sampleFlipped(0)) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Invalid S3DV file header"), "\(err)")
            }
        }
    }

    func testReservedFieldRejected() throws {
        try withTempFile(self.sampleFlipped(20)) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Invalid S3DV file header"), "\(err)")
            }
        }
    }

    func testOversizeMetadataRejected() throws {
        var d = sample!
        setLE32(UInt32(2_000_000), &d, 8) // meta_len > MAX_META
        try withTempFile(d) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Invalid S3DV file header"), "\(err)")
            }
        }
    }

    func testTruncatedMetadataRejected() throws {
        var d = sample!
        setLE32(UInt32(1024 * 1024), &d, 8) // passes header check, then the metadata read fails
        try withTempFile(d) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Truncated metadata"), "\(err)")
            }
        }
    }

    func testBadIndexMagicRejected() throws {
        var d = sample!
        let indexOff = Int(d.le64(12))
        d[indexOff] = 0x58 // 'IDX1' -> 'XDIX"-ish'
        try withTempFile(d) { url in
            XCTAssertThrowsError(try S3DVRecording(contentsOf: url)) { err in
                XCTAssertTrue(String(describing: err).contains("Invalid index"), "\(err)")
            }
        }
    }

    func testCorruptedPacketRejectedWithCRCMessage() throws {
        var d = sample!
        let start = firstPacketRecordStart(d)
        d[start + 4 + 48 + 3] ^= 0x01 // flip payload byte 3 of the first packet
        try withTempFile(d) { url in
            let rec = try S3DVRecording(contentsOf: url)
            XCTAssertThrowsError(try rec.readPackets()) { err in
                XCTAssertTrue(String(describing: err).contains("CRC mismatch"), "\(err)")
            }
        }
    }

    // MARK: packet-level rejections (mirror Packet.decode)

    func testPacketTruncatedHeaderRejected() throws {
        let stub = Data("S3DP".utf8) + writeLE(UInt16(0)) // 6 bytes << 48
        XCTAssertThrowsError(try S3DPPacket.decode(stub)) { err in
            XCTAssertTrue(String(describing: err).contains("Truncated packet header"), "\(err)")
        }
    }

    func testPacketInvalidVersionRejected() throws {
        XCTAssertThrowsError(try S3DPPacket.decode(craftPacket(version: 2, op: 10, chunk: 5))) { err in
            XCTAssertTrue(String(describing: err).contains("version"), "\(err)")
        }
    }

    func testPacketUnknownOpcodeRejected() throws {
        XCTAssertThrowsError(try S3DPPacket.decode(craftPacket(version: 1, op: 11, chunk: 5))) { err in
            XCTAssertTrue(String(describing: err).contains("opcode"), "\(err)")
        }
    }

    func testPacketBadFlagsRejected() throws {
        XCTAssertThrowsError(try S3DPPacket.decode(craftPacket(version: 1, op: 10, chunk: 0, flags: 0x0002))) { err in
            XCTAssertTrue(String(describing: err).contains("flags"), "\(err)")
        }
    }

    func testPacketOversizePayloadRejected() throws {
        let p = craftPacket(version: 1, op: 10, chunk: 0, n: UInt32(16 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try S3DPPacket.decode(p)) { err in
            XCTAssertTrue(String(describing: err).contains("payload"), "\(err)")
        }
    }

    func testMeshEventWithZeroChunkRejected() throws {
        XCTAssertThrowsError(try S3DPPacket.decode(craftPacket(version: 1, op: 3, chunk: 0))) { err in
            XCTAssertTrue(String(describing: err).contains("chunk ID 0"), "\(err)")
        }
    }

    func testTextureUpdateWithZeroChunkRejected() throws {
        // op 6 rejects the reserved chunk ID 0 exactly like the mesh events (protocol.py parity).
        XCTAssertThrowsError(try S3DPPacket.decode(craftPacket(version: 1, op: 6, chunk: 0))) { err in
            XCTAssertTrue(String(describing: err).contains("chunk ID 0"), "\(err)")
        }
    }

    func testPacketLengthMismatchRejected() throws {
        let wire = craftPacket(version: 1, op: 10, chunk: 5)
        XCTAssertThrowsError(try S3DPPacket.decode(wire.dropLast())) { err in
            XCTAssertTrue(String(describing: err).contains("Invalid packet length"), "\(err)")
        }
    }

    func testPacketCRCMismatchRejected() throws {
        var wire = craftPacket(version: 1, op: 10, chunk: 5)
        wire[47] ^= 0x01 // mutate a header byte covered by the CRC (payload empty)
        XCTAssertThrowsError(try S3DPPacket.decode(wire)) { err in
            XCTAssertTrue(String(describing: err).contains("CRC mismatch"), "\(err)")
        }
    }

    // MARK: helpers

    private func withTempFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).s3dv")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try body(url)
    }

    private func sampleFlipped(_ byteIndex: Int) -> Data {
        var d = sample!
        d[byteIndex] ^= 0x01
        return d
    }

    private func firstPacketRecordStart(_ data: Data) -> Int {
        28 + Int(data.le32(8))
    }

    private func setLE32(_ v: UInt32, _ data: inout Data, _ offset: Int) {
        data.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            p[offset + 0] = UInt8(truncatingIfNeeded: v)
            p[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
            p[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
            p[offset + 3] = UInt8(truncatingIfNeeded: v >> 24)
        }
    }

    private func writeLE<T>(_ v: T) -> Data {
        withUnsafeBytes(of: v) { Data($0) }
    }

    /// Minimal wire packet: '<4sBBHQQQIIQ' + CRC32(body) for empty payload.
    private func craftPacket(version: UInt8, op: UInt8, chunk: UInt64,
                             flags: UInt16 = 1, session: UInt64 = 1, seq: UInt64 = 0,
                             revision: UInt32 = 1, ts: UInt64 = 0, n: UInt32 = 0) -> Data {
        var body = Data("S3DP".utf8)
        body += [version, op]
        body += writeLE(flags)
        body += writeLE(session) + writeLE(seq) + writeLE(chunk)
        body += writeLE(revision) + writeLE(n) + writeLE(ts)
        if flags & 1 == 1 { body += writeLE(CRC32.digest(body)) }
        return body
    }
}
