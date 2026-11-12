// Chunk-id ↔ TSDF grid coordinates, mirroring src/s3dv/tsdf.py chunk_key().
//
//   key = 1 + ((ci + 32) + 64 * ((cj + 32) + 64 * (ck + 32)))   for ci,cj,ck ∈ [-32, 31]
//
// The viewer uses this to reason about chunk locality: a memory budget evicts a
// spatially coherent shell (rather than an arbitrary LRU set) so a cropped
// region still reads as a solid model.
import Foundation

public enum ChunkGrid {
    public static let span = 64
    public static let half = 32
    public static let maxChunks = span * span * span

    /// Grid coordinates for a chunk id, or nil for the reserved id 0 / ids
    /// outside the ±32 workspace (a v0.2 stream may carry others).
    public static func coords(of key: UInt64) -> (i: Int, j: Int, k: Int)? {
        guard key > 0 else { return nil }
        let v = Int(key - 1)
        guard v < maxChunks else { return nil }
        return (v % span - half, (v / span) % span - half, v / (span * span) - half)
    }

    /// Inverse of `coords(of:)`; nil outside the workspace.
    public static func key(i: Int, j: Int, k: Int) -> UInt64? {
        guard (-half..<half).contains(i), (-half..<half).contains(j), (-half..<half).contains(k) else {
            return nil
        }
        return UInt64(1 + ((i + half) + span * ((j + half) + span * (k + half))))
    }

    /// Chebyshev (shell) distance in chunk units from the workspace centre.
    public static func shellDistance(of key: UInt64) -> Int? {
        guard let c = coords(of: key) else { return nil }
        return max(abs(c.i), abs(c.j), abs(c.k))
    }
}
