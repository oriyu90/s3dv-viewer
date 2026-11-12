// S3DP v0.1 wire packets — decoding mirrors src/s3dv/protocol.py exactly.
// Layout: '<4sBBHQQQIIQ' 48 bytes; CRC32 zlib over header+payload, appended u32 LE.
import Foundation

public enum S3DPOpcode: UInt8, Equatable, Sendable {
    case hello = 1
    case snapshotBegin = 2
    case chunkAdd = 3
    case chunkReplace = 4
    case chunkRemove = 5
    case textureUpdate = 6
    case snapshotEnd = 7
    case stats = 8
    case resyncRequest = 9
    case heartbeat = 10

    public var isMeshEvent: Bool {
        self == .chunkAdd || self == .chunkReplace || self == .chunkRemove
    }
}

public enum S3DVError: LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        }
    }
}

public enum S3DP {
    public static let magic: [UInt8] = [0x53, 0x33, 0x44, 0x50] // "S3DP"
    public static let version: UInt8 = 1
    public static let headerSize = 48
    public static let maxPayload = 16 * 1024 * 1024
    public static let flagCRC32: UInt16 = 1
}

/// Decoded S3DP packet. `payload` is a private copy; safe to escape.
/// Decoded packet together with its original wire bytes (header+payload+CRC).
public struct S3DPFrame: Sendable {
    public let packet: S3DPPacket
    public let wire: Data
}

public struct S3DPPacket: Equatable, Sendable {
    public let opcode: S3DPOpcode
    public let flags: UInt16
    public let session: UInt64
    public let sequence: UInt64
    public let chunk: UInt64
    public let revision: UInt32
    public let payloadLength: UInt32
    public let timestampNS: UInt64
    /// Payload bytes only (48..<48+n of the wire form).
    public let payload: Data

    public static func == (a: S3DPPacket, b: S3DPPacket) -> Bool {
        a.opcode == b.opcode && a.flags == b.flags && a.session == b.session
            && a.sequence == b.sequence && a.chunk == b.chunk && a.revision == b.revision
            && a.payloadLength == b.payloadLength && a.timestampNS == b.timestampNS
            && a.payload == b.payload
    }
}

extension S3DPPacket {
    /// Decode one S3DP wire packet (header+payload+CRC). Mirrors S3DPPacket.decode().
    public static func decode(_ raw: Data) throws -> S3DPPacket {
        guard raw.count >= S3DP.headerSize else {
            throw S3DVError.invalid("Truncated packet header")
        }
        return try raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> S3DPPacket in
            guard p[0] == 0x53, p[1] == 0x33, p[2] == 0x44, p[3] == 0x50 else {
                throw S3DVError.invalid("Invalid packet magic/version")
            }
            let version = p[4]
            guard version == S3DP.version else { throw S3DVError.invalid("Unsupported S3DP version") }
            let opByte = p[5]
            guard let opcode = S3DPOpcode(rawValue: opByte) else {
                throw S3DVError.invalid("Unknown opcode \(opByte)")
            }
            let flags = LE.u16(p, 6)
            guard flags & ~S3DP.flagCRC32 == 0 else {
                throw S3DVError.invalid("Unsupported flags")
            }
            let session = LE.u64(p, 8)
            let sequence = LE.u64(p, 16)
            let chunk = LE.u64(p, 24)
            let revision = LE.u32(p, 32)
            let n = LE.u32(p, 36)
            let ts = LE.u64(p, 40)
            guard Int(n) <= S3DP.maxPayload else {
                throw S3DVError.invalid("Oversize payload")
            }
            if (opcode == .textureUpdate || opcode.isMeshEvent) && chunk == 0 {
                // Mirrors protocol.py: CHUNK_ADD/REPLACE/REMOVE + TEXTURE_UPDATE
                // all reject the reserved chunk ID 0.
                throw S3DVError.invalid("Mesh/texture event with reserved chunk ID 0")
            }
            let length = S3DP.headerSize + Int(n) + ((flags & S3DP.flagCRC32) != 0 ? 4 : 0)
            guard raw.count == length else { throw S3DVError.invalid("Invalid packet length") }
            if flags & S3DP.flagCRC32 != 0 {
                // Checksum over header+payload, exactly like zlib.crc32(raw[:-4]) in protocol.py.
                let expected = LE.u32(p, S3DP.headerSize + Int(n))
                let actual = CRC32.digest(raw, in: 0..<(S3DP.headerSize + Int(n)))
                guard actual == expected else { throw S3DVError.invalid("CRC mismatch") }
            }
            var payload = Data()
            if n > 0 {
                payload = raw.subdata(in: (raw.startIndex + S3DP.headerSize)
                    ..< (raw.startIndex + S3DP.headerSize + Int(n)))
            }
            return S3DPPacket(opcode: opcode, flags: flags, session: session, sequence: sequence,
                              chunk: chunk, revision: revision, payloadLength: n, timestampNS: ts,
                              payload: payload)
        }
    }

    /// CRC32 check against the appended u32 LE (call after decode; mirrors zlib.crc32 over header+payload).
    public func verifyCRC(in raw: Data) -> Bool {
        guard flags & S3DP.flagCRC32 != 0 else { return true }
        guard raw.count >= S3DP.headerSize + 4 else { return false }
        let expected = raw.le32(raw.count - 4)
        let actual = CRC32.digest(raw, in: 0..<(raw.count - 4))
        return actual == expected
    }
}
