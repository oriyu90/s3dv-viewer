import XCTest
@testable import S3DVCore

/// Parity against the canonical Python implementation: fixtures are byte-exact
/// packet dumps produced by scripts/export_packets_json.py (Packet.encode round-trip).
final class ParityTests: XCTestCase {
    private func fixture(_ name: String) throws -> (metadata: String, packets: [(ts: UInt64, wire: Data)]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/parity"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let metadata = try XCTUnwrap(obj["metadata"] as? String)
        let rows = try XCTUnwrap(obj["packets"] as? [[String: Any]])
        return (metadata, try rows.map { row -> (UInt64, Data) in
            let ts = try XCTUnwrap(row["ts"] as? NSNumber).uint64Value
            let hexString = try XCTUnwrap(row["hex"] as? String)
            XCTAssertEqual(hexString.count % 2, 0)
            var bytes = [UInt8]()
            bytes.reserveCapacity(hexString.count / 2)
            var index = hexString.startIndex
            while index < hexString.endIndex {
                let hi = hexString[index].hexDigitValue!
                let next = hexString.index(after: index)
                let lo = hexString[next].hexDigitValue!
                bytes.append(UInt8(hi << 4 | lo))
                index = next
                if index < hexString.endIndex { index = hexString.index(after: index) }
            }
            return (ts, Data(bytes))
        })
    }

    func testCubeOrbitParity() throws {
        let fx = try fixture("cube_orbit")
        XCTAssertEqual(fx.packets.count, 34)
        // Metadata hashes must be byte-identical (raw metadata bytes, no re-serialization).
        let rec = try S3DVRecording(contentsOf: try XCTUnwrap(
            Bundle.module.url(forResource: "cube_orbit", withExtension: "s3dv", subdirectory: "Fixtures/recordings")))
        XCTAssertEqual(rec.metadataString, fx.metadata)
        // Swift reader must reproduce the exact wire bytes and timestamps.
        let read = try rec.readPackets()
        XCTAssertEqual(read.count, fx.packets.count)
        XCTAssertEqual(try rec.wireByteCount(), fx.packets.reduce(0) { $0 + Int($1.wire.count) })
        for (decoded, b) in zip(read, fx.packets) {
            XCTAssertEqual(decoded.timestampNS, b.ts)
            let fixturePacket = try S3DPPacket.decode(b.wire)
            XCTAssertTrue(fixturePacket.verifyCRC(in: b.wire), "CRC mismatch on fixture packet")
            XCTAssertEqual(decoded, fixturePacket)
        }
        // Field sanity on the first packet: SNAPSHOT_BEGIN, ts 0.
        XCTAssertEqual(try S3DPPacket.decode(fx.packets[0].wire).opcode, .snapshotBegin)
        XCTAssertEqual(fx.packets[0].ts, 0)
    }

    func testShapeAnimationParity() throws {
        let fx = try fixture("shape_animation")
        XCTAssertEqual(fx.packets.count, 38)
        let rec = try S3DVRecording(contentsOf: try XCTUnwrap(
            Bundle.module.url(forResource: "shape_animation", withExtension: "s3dv", subdirectory: "Fixtures/recordings")))
        let read = try rec.readPackets()
        XCTAssertEqual(read.count, fx.packets.count)
        // A well-formed recording closes with SNAPSHOT_END.
        XCTAssertEqual(read.last?.opcode, .snapshotEnd)
    }

    func testIndexRowsAreSnapshotFlaggedAndConsistent() throws {
        let rec = try S3DVRecording(contentsOf: try XCTUnwrap(
            Bundle.module.url(forResource: "cube_orbit", withExtension: "s3dv", subdirectory: "Fixtures/recordings")))
        XCTAssertEqual(rec.index.count, 34)
        XCTAssertTrue(rec.index.contains(where: { $0.isSnapshotBegin }))
        // All packet timestamps equal the indexed row timestamps (parity through the whole file).
        let packets = try rec.readPackets()
        for (p, row) in zip(packets, rec.index) { XCTAssertEqual(p.timestampNS, row.timestampNS) }
    }
}
