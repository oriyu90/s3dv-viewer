// Shared constants and line protocol for the S3DV viewer control socket.
//
// The app listens on a UNIX domain socket in the user's Application Support
// directory; `s3dvctl` (and anything that can write a line to a socket) sends
// one request per connection and reads one JSON line back. Both the app and the
// CLI link this module so the path and the framing can never drift apart.
import Foundation

public enum ControlPath {
    /// Override for tests and for an app started with a custom container.
    public static let socketEnvironmentKey = "S3DV_CONTROL_SOCKET"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("S3DV viewer", isDirectory: true)
    }

    public static var defaultSocketURL: URL {
        supportDirectory.appendingPathComponent("control.sock")
    }

    /// Honours `S3DV_CONTROL_SOCKET`, otherwise the per-user default.
    public static func socketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment[socketEnvironmentKey], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return defaultSocketURL
    }

    /// UNIX socket paths are limited to 104 bytes on Darwin (`sun_path`).
    public static let maxPathBytes = 103
}
