// Little-endian primitive readers over a Data buffer — mirrors struct '<…' layouts.
// Bytes are assembled explicitly so behaviour is correct on any host byte order.
import Foundation

enum LE {
    @inline(__always)
    static func u16(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        UInt16(p[o]) | UInt16(p[o + 1]) << 8
    }

    @inline(__always)
    static func u32(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
    }

    @inline(__always)
    static func u64(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(p[o + i]) << (8 * UInt64(i)) }
        return v
    }
}

extension Data {
    @inline(__always)
    func le16(_ o: Int) -> UInt16 { withUnsafeBytes { LE.u16($0, o) } }

    @inline(__always)
    func le32(_ o: Int) -> UInt32 { withUnsafeBytes { LE.u32($0, o) } }

    @inline(__always)
    func le64(_ o: Int) -> UInt64 { withUnsafeBytes { LE.u64($0, o) } }
}
