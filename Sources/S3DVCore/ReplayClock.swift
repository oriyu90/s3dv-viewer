// Pacing math mirroring src/s3dv/server.py: delay = (ts - prev)/1e9 / rate, capped at 2 s.
public enum ReplayClock {
    public static let maxDelay: Double = 2.0

    public static func pacingDelay(prevTS: UInt64, ts: UInt64, rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        let gap: Double
        if ts >= prevTS { gap = Double(ts - prevTS) / 1e9 } else { gap = -1 }
        return min(maxDelay, max(0, gap / rate))
    }
}
