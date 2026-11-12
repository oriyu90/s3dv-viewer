// S3DP wire encoding — mirrors src/s3dv/protocol.py Packet.encode() byte for byte.
// Decoding lives in Packet.swift; this file exists so the replay engine can
// renumber packets (budgeted mode) and synthesise CHUNK_REMOVE evictions without
// leaving the validated wire format.
import Foundation

extension S3DPPacket {
    /// Header fields in wire order; shared by encode() and the sequence rewrite.
    public func encode() -> Data {
        var out = Data(capacity: S3DP.headerSize + payload.count + 4)
        out.append(contentsOf: S3DP.magic)
        out.append(S3DP.version)
        out.append(opcode.rawValue)
        appendLE(&out, flags, 2)
        appendLE(&out, session, 8)
        appendLE(&out, sequence, 8)
        appendLE(&out, chunk, 8)
        appendLE(&out, revision, 4)
        appendLE(&out, payloadLength, 4)
        appendLE(&out, timestampNS, 8)
        out.append(payload)
        if flags & S3DP.flagCRC32 != 0 { appendLE(&out, CRC32.digest(out), 4) }
        return out
    }

    /// Same packet with a new sequence number (and optionally timestamp).
    /// Only the 8 header bytes change; the CRC is recomputed over the result.
    public func renumbered(sequence newSequence: UInt64, timestampNS newTS: UInt64? = nil) -> S3DPPacket {
        S3DPPacket(opcode: opcode, flags: flags, session: session, sequence: newSequence,
                   chunk: chunk, revision: revision, payloadLength: payloadLength,
                   timestampNS: newTS ?? timestampNS, payload: payload)
    }

    /// Synthesises a packet the container never stored (budget evictions).
    public static func make(opcode: S3DPOpcode, session: UInt64, sequence: UInt64,
                            chunk: UInt64, revision: UInt32, timestampNS: UInt64,
                            payload: Data = Data()) -> S3DPPacket {
        S3DPPacket(opcode: opcode, flags: S3DP.flagCRC32, session: session, sequence: sequence,
                   chunk: chunk, revision: revision, payloadLength: UInt32(payload.count),
                   timestampNS: timestampNS, payload: payload)
    }

    private func appendLE(_ out: inout Data, _ value: UInt64, _ width: Int) {
        for i in 0..<width { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
    }

    private func appendLE(_ out: inout Data, _ value: UInt32, _ width: Int) {
        appendLE(&out, UInt64(value), width)
    }

    private func appendLE(_ out: inout Data, _ value: UInt16, _ width: Int) {
        appendLE(&out, UInt64(value), width)
    }
}
