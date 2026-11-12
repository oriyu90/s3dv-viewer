import XCTest
@testable import S3DVCore

/// Covers the streaming reader introduced for S3DV viewer 1.0: lazy record access,
/// wire re-encoding (used for budget evictions), statistics and seek checkpoints.
/// The invariant under test is that nothing the new fast path does can change what
/// a packet means on the wire.
final class StreamingTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "s3dv",
                                        subdirectory: "Fixtures/recordings"))
    }

    func testLazyAccessMatchesSequentialDecode() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        let frames = try rec.readFrames()
        XCTAssertEqual(rec.packetCount, frames.count)
        for i in 0..<frames.count {
            XCTAssertEqual(try rec.wire(at: i), frames[i].wire, "record \(i) differs")
            XCTAssertEqual(try rec.packet(at: i), frames[i].packet)
        }
    }

    func testWireByteCountMatchesSum() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        let frames = try rec.readFrames()
        XCTAssertEqual(try rec.wireByteCount(), frames.reduce(0) { $0 + $1.wire.count })
    }

    func testEncodeRoundTripsEveryPacketByteForByte() throws {
        for name in ["cube_orbit", "shape_animation"] {
            let rec = try S3DVRecording(contentsOf: fixtureURL(name))
            for frame in try rec.readFrames() {
                XCTAssertEqual(frame.packet.encode(), frame.wire, "\(name) packet \(frame.packet.sequence)")
            }
        }
    }

    func testRenumberedPacketKeepsAValidChecksum() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        let original = try rec.packet(at: 1)
        let moved = original.renumbered(sequence: 9_999_999)
        let wire = moved.encode()
        let decoded = try S3DPPacket.decode(wire)
        XCTAssertEqual(decoded.sequence, 9_999_999)
        XCTAssertEqual(decoded.opcode, original.opcode)
        XCTAssertEqual(decoded.chunk, original.chunk)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertTrue(decoded.verifyCRC(in: wire))
    }

    func testCheckedSummaryMatchesReference() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        let stats = rec.stats()
        var resident: [UInt64: (UInt32, Int, Int)] = [:]
        var events = 0
        var snapshots = 0
        for frame in try rec.readFrames() {
            let packet = frame.packet
            switch packet.opcode {
            case .snapshotBegin: snapshots += 1
            case .chunkAdd, .chunkReplace:
                events += 1
                let header = S3DVMeshHeader.parse(packet.payload)!
                let current = resident[packet.chunk]
                if current == nil || packet.revision > current!.0 {
                    resident[packet.chunk] = (packet.revision, header.vertexCount, header.indexCount / 3)
                }
            default: break
            }
        }
        XCTAssertEqual(stats.snapshots, snapshots)
        XCTAssertEqual(stats.chunkEvents, events)
        XCTAssertEqual(stats.residentChunks, resident.count)
        XCTAssertEqual(stats.residentVertices, resident.values.reduce(0) { $0 + $1.1 })
        XCTAssertEqual(stats.residentTriangles, resident.values.reduce(0) { $0 + $1.2 })
        XCTAssertEqual(stats.corruptRecords, 0)
    }

    func testSeekCheckpointLandsOnSnapshotBegin() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        let target = rec.durationNS / 2
        let offset = rec.checkpointOffset(atNS: target)
        let number = rec.packetNumber(atOffset: offset)
        let packet = try rec.packet(at: number)
        XCTAssertEqual(packet.opcode, .snapshotBegin)
        XCTAssertLessThanOrEqual(packet.timestampNS, target)
        // Seeking past the end still yields a valid checkpoint.
        let late = rec.checkpointOffset(atNS: rec.durationNS + 1_000_000_000)
        XCTAssertGreaterThanOrEqual(late, rec.startOffset)
        XCTAssertLessThan(late, rec.indexOffset)
    }

    func testDeepVerifyAcceptsIntactFixture() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        XCTAssertNoThrow(try rec.deepVerify())
    }

    func testChunkGridRoundTrip() {
        for key: UInt64 in [1, 2, 1_000, 42_424, UInt64(ChunkGrid.maxChunks)] {
            let coords = ChunkGrid.coords(of: key)
            XCTAssertNotNil(coords)
            XCTAssertEqual(ChunkGrid.key(i: coords!.i, j: coords!.j, k: coords!.k), key)
        }
        XCTAssertNil(ChunkGrid.coords(of: 0))
        XCTAssertNil(ChunkGrid.coords(of: UInt64(ChunkGrid.maxChunks) + 1))
        XCTAssertNil(ChunkGrid.key(i: 32, j: 0, k: 0))
        XCTAssertEqual(ChunkGrid.shellDistance(of: 1), 32) // (i,j,k) = (-32,-32,-32)
        XCTAssertEqual(ChunkGrid.shellDistance(of: ChunkGrid.key(i: 0, j: 0, k: 0)!), 0)
    }

    func testMeshHeaderRejectsTruncatedPayload() {
        let rec = try? S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        XCTAssertNotNil(rec)
        XCTAssertNil(S3DVMeshHeader.parse(Data([0, 0, 0, 0])))
        XCTAssertNil(S3DVMeshHeader.parse(Data(repeating: 0xFF, count: 8)))
    }

    func testOutOfRangeAccessThrows() throws {
        let rec = try S3DVRecording(contentsOf: fixtureURL("cube_orbit"))
        XCTAssertThrowsError(try rec.wire(at: -1))
        XCTAssertThrowsError(try rec.wire(at: rec.packetCount))
        XCTAssertThrowsError(try rec.wire(atOffset: 0))
    }
}
