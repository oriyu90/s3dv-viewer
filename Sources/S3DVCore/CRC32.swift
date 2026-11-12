// CRC32 identical to zlib.crc32 — reflected polynomial 0xEDB88320, init 0xFFFFFFFF.
// On-the-wire location: S3DP computes CRC32 over header+payload bytes, appended as u32 LE.
import Foundation

enum CRC32 {
    static let table: ContiguousArray<UInt32> = {
        var t = ContiguousArray<UInt32>()
        t.reserveCapacity(256)
        for k in 0..<256 {
            var x = UInt32(k)
            for _ in 0..<8 { x = (x & 1) != 0 ? (0xEDB88320 ^ (x >> 1)) : (x >> 1) }
            t.append(x)
        }
        return t
    }()

    /// CRC over a byte range of a Data buffer (avoids copying the slice).
    @inline(__always)
    static func digest(_ data: Data, in range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var i = range.lowerBound
            while i < range.upperBound {
                crc = table[Int((crc ^ UInt32(p[i])) & 0xFF)] ^ (crc >> 8)
                i += 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    @inline(__always)
    static func digest(_ data: Data) -> UInt32 {
        digest(data, in: data.startIndex..<data.endIndex)
    }
}
