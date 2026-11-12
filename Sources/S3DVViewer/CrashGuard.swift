// Crash safety + diagnostics.
//
// What this deliberately does NOT do: install SIGSEGV/SIGBUS handlers that try
// to allocate or take locks on a corrupted stack. Apple's guidance (and bitter
// experience) is that those handlers deadlock or corrupt the report. Instead:
//   * uncaught Objective-C/Swift exceptions are logged, then the default
//     termination path runs;
//   * a "session in progress" sentinel is written on launch and removed on a
//     clean quit, so an unclean exit is detectable and reported next launch;
//   * the log lives in ~/Library/Logs/S3DV viewer and is size-capped;
//   * WKWebView content-process death is a recoverable event, handled in AppState.
import Foundation
import Darwin

final class CrashGuard {
    static let shared = CrashGuard()

    private let lock = NSLock()
    private let sentinel: URL
    private let maxLogBytes = 1_048_576

    private init() {
        sentinel = AppPaths.logsDirectory.appendingPathComponent("running.marker")
        try? FileManager.default.createDirectory(at: AppPaths.logsDirectory, withIntermediateDirectories: true)
        notePreviousRunIfUnclean()
        install()
    }

    var logURL: URL { AppPaths.logsDirectory.appendingPathComponent("session.log") }

    // MARK: - public

    /// Appends one line. Never throws, never blocks for long, never allocates a
    /// lot (called from failure paths).
    func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [pid \(getpid())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    func markCleanExit() {
        try? FileManager.default.removeItem(at: sentinel)
    }

    // MARK: - internals

    private func rotateIfNeeded() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int) ?? 0
        guard size > maxLogBytes else { return }
        let old = AppPaths.logsDirectory.appendingPathComponent("session.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    private func install() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let symbols = exception.callStackSymbols.prefix(24).joined(separator: " | ")
            CrashGuard.shared.log("UNCAUGHT \(name): \(reason) :: \(symbols)")
            CrashGuard.shared.flushSentinel()
        }
        // Written before the handler can run, so a hard kill still leaves a trace.
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: sentinel)
        log("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") "
            + "build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private func flushSentinel() {
        // Leave the sentinel in place: the exception path is not a clean exit.
        let marker = AppPaths.logsDirectory.appendingPathComponent("CRASHED")
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: marker)
    }

    private func notePreviousRunIfUnclean() {
        let crashed = AppPaths.logsDirectory.appendingPathComponent("CRASHED")
        if FileManager.default.fileExists(atPath: crashed.path) {
            let when = (try? String(contentsOf: crashed, encoding: .utf8)) ?? "unknown"
            log("previous run terminated abnormally at epoch \(when)")
            try? FileManager.default.removeItem(at: crashed)
        }
        if FileManager.default.fileExists(atPath: sentinel.path) {
            log("previous run did not exit cleanly (sentinel present)")
        }
    }
}

// MARK: - process memory

enum ProcessMemory {
    /// Physical footprint in bytes — the number Activity Monitor shows and the
    /// one that matters for jetsam/WebContent termination.
    static var footprintBytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    static var footprintMegabytes: Double { Double(footprintBytes) / 1_048_576 }

    /// Peak sampled footprint, refreshed by `PeakSampler`.
    final class PeakSampler {
        private(set) var peakBytes = 0
        private var timer: Timer?

        func start(interval: TimeInterval = 0.5) {
            stop()
            peakBytes = ProcessMemory.footprintBytes
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.peakBytes = max(self.peakBytes, ProcessMemory.footprintBytes)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        var peakMegabytes: Double { Double(peakBytes) / 1_048_576 }
    }
}
