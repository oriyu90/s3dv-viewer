// .s3dv container reader — byte-compatible mirror of src/s3dv/container.py Reader (v0.1/v0.2 read).
//
// Layout: 28B file header '<4sHHIQQ', metadata JSON (<=1 MB), records [u32 len][S3DP],
// trailing index: '<4sI' header 'IDX1', rows '<QQB7x' = [u64 ts][u64 offset][bool begin][pad].
//
// The reader is *lazy*: the file is memory-mapped and never materialised in RAM.
// `index` carries one row per packet, so random access is O(1) and the replay
// engine streams a multi-gigabyte recording with a resident cost of the index
// rows plus one in-flight packet. An earlier revision copied every record into
// an array of `S3DPFrame`, which doubled the footprint of large recordings
// (a 1.27 GB stream peaked at ~4.2 GB RSS and truncated the replay).
import Foundation

public struct S3DVIndexRow: Equatable, Sendable {
    public let timestampNS: UInt64
    /// File offset of the record's u32 length prefix (mirrors Writer.write()).
    public let offset: UInt64
    public let isSnapshotBegin: Bool
}

public enum S3DVFile {
    public static let magic: [UInt8] = [0x53, 0x33, 0x44, 0x56] // "S3DV"
    public static let major: UInt16 = 1
    public static let minor: UInt16 = 0        // writer default (v0.1)
    public static let supportedMinors: Set<UInt16> = [0, 2]  // v0.2 read-only (W13)
    public static let headerSize = 28
    public static let maxMeta = 1024 * 1024
    public static let indexHeadSize = 8
    public static let indexRowSize = 24
    public static let recordLengthFieldSize = 4
    public static let indexMagic: [UInt8] = [0x49, 0x44, 0x58, 0x31] // "IDX1"
}

/// Decoded mesh payload header (cheap: reads at most the first 44 bytes).
public struct S3DVMeshHeader: Equatable, Sendable {
    public enum Codec: Equatable, Sendable { case raw, quantised16, quantised32 }
    public let codec: Codec
    public let vertexCount: Int
    public let indexCount: Int

    /// Parses the mesh header exactly like protocol.decode_mesh / web/main.js
    /// without walking the geometry. Returns nil for a payload that is too short
    /// or whose declared sizes cannot fit the buffer (the viewer would reject it).
    public static func parse(_ payload: Data) -> S3DVMeshHeader? {
        let count = payload.count
        guard count >= 8 else { return nil }
        return payload.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> S3DVMeshHeader? in
            if LE.u32(p, 0) != 0xFFFF_FFFF {
                let n = Int(LE.u32(p, 0))
                let ni = Int(LE.u32(p, 4))
                guard n <= 400_000, ni <= 1_200_000, ni % 3 == 0,
                      count >= 8 + 12 * n + 4 * ni + 3 * n else { return nil }
                return S3DVMeshHeader(codec: .raw, vertexCount: n, indexCount: ni)
            }
            guard count >= 44 else { return nil }
            let codec = LE.u32(p, 4)
            let n = Int(LE.u32(p, 8))
            guard codec == 1, n > 0, n <= 400_000 else { return nil }
            let indexBits = Int(LE.u16(p, 36))
            guard indexBits == 16 || indexBits == 32 else { return nil }
            let width = indexBits == 32 ? 4 : 2
            let rest = count - 44 - 6 * n - 3 * n
            guard rest >= 0, rest % width == 0 else { return nil }
            let ni = rest / width
            guard ni % 3 == 0 else { return nil }
            return S3DVMeshHeader(codec: indexBits == 32 ? .quantised32 : .quantised16,
                                  vertexCount: n, indexCount: ni)
        }
    }

    /// Resident bytes the WebGL viewer needs for this chunk: position + linear
    /// colour + computed normal (3 floats each) + index. UVs (8 bytes/vertex) are
    /// only allocated for textured chunks and are added by the caller.
    public var residentBytes: Int { vertexCount * 36 + indexCount * 4 }
}

/// Validates the container structure on init (mirrors Reader.__init__), then
/// serves packets lazily from the mapping.
public final class S3DVRecording {
    public let metadataString: String
    public let metadataJSON: Any
    public let metadataLength: Int
    public let startOffset: Int
    public let indexOffset: Int
    public let index: [S3DVIndexRow]
    public let fileURL: URL
    public let bytesOnDisk: Int
    /// File-header wire minor (0 = v0.1, 2 = v0.2).
    public let wireMinor: UInt16

    private let data: Data

    public var packetCount: Int { index.count }

    public init(contentsOf url: URL) throws {
        fileURL = url
        // .alwaysMapped keeps the mapping and never read-ahead-copies the file;
        // the fallback covers filesystems where mapping is refused (some SMB/NFS
        // mounts answer EINVAL for mmap).
        if let mapped = try? Data(contentsOf: url, options: [.alwaysMapped]) {
            data = mapped
        } else {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        bytesOnDisk = data.count
        guard data.count >= S3DVFile.headerSize else {
            throw S3DVError.invalid("Truncated file header")
        }
        let magicOK = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            p[0] == S3DVFile.magic[0] && p[1] == S3DVFile.magic[1]
                && p[2] == S3DVFile.magic[2] && p[3] == S3DVFile.magic[3]
        }
        let major = data.le16(4)
        let minor = data.le16(6)
        let metaLen = Int(data.le32(8))
        let indexOff = Int(data.le64(12))
        let reserved = data.le64(20)
        guard magicOK, major == S3DVFile.major,
              S3DVFile.supportedMinors.contains(minor),
              reserved == 0, metaLen <= S3DVFile.maxMeta else {
            throw S3DVError.invalid("Invalid S3DV file header")
        }
        wireMinor = minor
        metadataLength = metaLen
        guard data.count >= S3DVFile.headerSize + metaLen else {
            throw S3DVError.invalid("Truncated metadata")
        }
        let metaBytes = data.subdata(in: S3DVFile.headerSize..<(S3DVFile.headerSize + metaLen))
        guard let metaText = String(data: metaBytes, encoding: .utf8),
              let json = try? JSONSerialization.jsonObject(with: metaBytes, options: [.fragmentsAllowed])
        else { throw S3DVError.invalid("Corrupt metadata") }
        metadataString = metaText
        metadataJSON = json
        let startOffsetLocal = S3DVFile.headerSize + metaLen
        startOffset = startOffsetLocal
        let end = data.count
        guard indexOff >= startOffset, indexOff <= end - S3DVFile.indexHeadSize else {
            throw S3DVError.invalid("Invalid index offset")
        }
        indexOffset = indexOff
        let mark = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            p[indexOff] == S3DVFile.indexMagic[0] && p[indexOff + 1] == S3DVFile.indexMagic[1]
                && p[indexOff + 2] == S3DVFile.indexMagic[2] && p[indexOff + 3] == S3DVFile.indexMagic[3]
        }
        let rows = Int(data.le32(indexOff + 4))
        guard mark, indexOff + S3DVFile.indexHeadSize + rows * S3DVFile.indexRowSize == end else {
            throw S3DVError.invalid("Invalid index")
        }
        var parsed: [S3DVIndexRow] = []
        parsed.reserveCapacity(rows)
        for r in 0..<rows {
            let base = indexOff + S3DVFile.indexHeadSize + r * S3DVFile.indexRowSize
            let ts = data.le64(base)
            let offset = data.le64(base + 8)
            let begin = data[base + 16]
            parsed.append(S3DVIndexRow(timestampNS: ts, offset: offset, isSnapshotBegin: begin != 0))
        }
        if parsed.contains(where: { Int($0.offset) < startOffsetLocal || Int($0.offset) >= indexOff }) {
            throw S3DVError.invalid("Invalid packet offset")
        }
        index = parsed
    }

    // MARK: - lazy record access

    /// Wire bytes (header + payload + CRC) of record `i`, copied out of the map.
    public func wire(at i: Int) throws -> Data {
        guard i >= 0, i < index.count else { throw S3DVError.invalid("Packet index out of range") }
        return try wire(atOffset: Int(index[i].offset))
    }

    /// Wire bytes at a raw record offset (used by seek, which anchors on a
    /// SNAPSHOT_BEGIN row rather than on a packet number).
    public func wire(atOffset pos: Int) throws -> Data {
        guard pos >= startOffset, pos + S3DVFile.recordLengthFieldSize <= indexOffset else {
            throw S3DVError.invalid("Record offset out of range")
        }
        let n = Int(data.le32(pos))
        guard n >= S3DP.headerSize,
              n <= S3DP.headerSize + S3DP.maxPayload + 4,
              pos + S3DVFile.recordLengthFieldSize + n <= indexOffset else {
            throw S3DVError.invalid("Invalid record size")
        }
        return data.subdata(in: (pos + S3DVFile.recordLengthFieldSize)
            ..< (pos + S3DVFile.recordLengthFieldSize + n))
    }

    public func packet(at i: Int) throws -> S3DPPacket {
        try S3DPPacket.decode(wire(at: i))
    }

    /// Byte length of record `i` without copying its payload.
    public func wireLength(at i: Int) throws -> Int {
        guard i >= 0, i < index.count else { throw S3DVError.invalid("Packet index out of range") }
        let pos = Int(index[i].offset)
        guard pos >= startOffset, pos + S3DVFile.recordLengthFieldSize <= indexOffset else {
            throw S3DVError.invalid("Record offset out of range")
        }
        return Int(data.le32(pos))
    }

    /// Deep validation: walks every record and checks length + CRC. Reads the
    /// whole file, so it is opt-in ("Deep verify on open").
    /// `progress` fires at most every 4096 records with (done, total).
    public func deepVerify(progress: ((Int, Int) -> Void)? = nil) throws {
        for i in 0..<index.count {
            let wire = try wire(at: i)
            guard let packet = try? S3DPPacket.decode(wire), packet.verifyCRC(in: wire) else {
                throw S3DVError.invalid("Corrupt record #\(i)")
            }
            if i % 4096 == 0 { progress?(i, index.count) }
        }
        progress?(index.count, index.count)
    }

    // MARK: - seek

    /// Mirrors Reader.checkpoint_at: the last SNAPSHOT_BEGIN whose timestamp is
    /// <= t, else the start of the record area.
    public func checkpointOffset(atNS t: UInt64) -> Int {
        var offset = startOffset
        for row in index {
            if row.isSnapshotBegin {
                if row.timestampNS <= t { offset = Int(row.offset) } else { break }
            }
        }
        return offset
    }

    /// Packet number of the first record at or after `offset` (index rows are in
    /// file order, so this is a binary search).
    public func packetNumber(atOffset offset: Int) -> Int {
        var lo = 0, hi = index.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(index[mid].offset) < offset { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, index.count)
    }

    public var durationNS: UInt64 { index.last?.timestampNS ?? 0 }

    // MARK: - statistics

    /// One pass over record headers + mesh headers (no payload copies).
    /// `includeResident` keeps a per-chunk revision table; disable it for
    /// million-packet streams where only event totals matter.
    public func stats(includeResident: Bool = true) -> S3DVStats {
        var s = S3DVStats()
        s.packetCount = index.count
        s.bytes = bytesOnDisk
        s.durationNS = durationNS
        var resident: [UInt64: (rev: UInt32, tri: Int, vert: Int)] = [:]
        resident.reserveCapacity(min(index.count, 65_536))
        var seen = Set<UInt64>()
        seen.reserveCapacity(min(index.count, 65_536))
        for i in 0..<index.count {
            guard let wire = try? wire(at: i), let p = try? S3DPPacket.decode(wire) else {
                s.corruptRecords += 1
                continue
            }
            s.wireBytes += wire.count
            s.maxPayload = max(s.maxPayload, Int(p.payloadLength))
            switch p.opcode {
            case .snapshotBegin:
                s.snapshots += 1
            case .chunkRemove:
                s.removals += 1
            case .chunkAdd, .chunkReplace:
                s.chunkEvents += 1
                seen.insert(p.chunk)
                guard let h = S3DVMeshHeader.parse(p.payload) else {
                    s.rejectedMeshPayloads += 1
                    continue
                }
                s.eventVertices += h.vertexCount
                s.eventTriangles += h.indexCount / 3
                if includeResident {
                    let cur = resident[p.chunk]
                    if cur == nil || p.revision > cur!.rev {
                        resident[p.chunk] = (p.revision, h.indexCount / 3, h.vertexCount)
                    }
                }
            case .textureUpdate:
                s.textures += 1
            default:
                break
            }
        }
        s.uniqueChunks = seen.count
        if includeResident {
            for entry in resident.values {
                s.residentTriangles += entry.tri
                s.residentVertices += entry.vert
            }
            s.residentChunks = resident.count
        }
        return s
    }

    /// Total bytes of every wire packet (for telemetry parity with the JS viewer).
    public func wireByteCount() throws -> Int {
        var total = 0
        for row in index { total += Int(data.le32(Int(row.offset))) }
        return total
    }

    /// Full decode of every record. Kept for tests and small fixtures only —
    /// the app streams through `wire(at:)` instead.
    public func readFrames() throws -> [S3DPFrame] {
        var frames: [S3DPFrame] = []
        frames.reserveCapacity(index.count)
        for i in 0..<index.count {
            let wire = try wire(at: i)
            frames.append(S3DPFrame(packet: try S3DPPacket.decode(wire), wire: wire))
        }
        return frames
    }

    public func readPackets() throws -> [S3DPPacket] { try readFrames().map { $0.packet } }
}

/// Aggregate properties of a recording, computed from headers only.
public struct S3DVStats: Equatable, Sendable {
    public var packetCount = 0
    public var snapshots = 0
    public var chunkEvents = 0
    public var uniqueChunks = 0
    public var textures = 0
    public var removals = 0
    public var corruptRecords = 0
    public var rejectedMeshPayloads = 0
    public var eventVertices = 0
    public var eventTriangles = 0
    public var residentChunks = 0
    public var residentVertices = 0
    public var residentTriangles = 0
    public var bytes = 0
    public var wireBytes = 0
    public var maxPayload = 0
    public var durationNS: UInt64 = 0

    public init() {}

    public var durationSeconds: Double { Double(durationNS) / 1e9 }
    /// Viewer-side resident estimate for the final scene (36 B/vertex + 4 B/index).
    public var residentMegabytes: Double {
        (Double(residentVertices) * 36 + Double(residentTriangles) * 12) / 1_048_576
    }
    public var densityTrianglesPerChunk: Double {
        residentChunks > 0 ? Double(residentTriangles) / Double(residentChunks) : 0
    }
}
