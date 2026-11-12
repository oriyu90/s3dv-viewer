// Environment-driven self test for the app bundle.
//
// It exists so every claim in the README/report can be re-measured on this
// machine without a human watching the window:
//
//   S3DV_VIEWER_AUTOTEST=1     enable
//   S3DV_VIEWER_REPORT=<path>  where the JSON report goes
//   S3DV_VIEWER_EXPECT=<json>  expected {"packets":..,"chunks":..,"triangles":..,"bytes":..}
//   S3DV_VIEWER_RATE=<double>  replay speed
//   S3DV_VIEWER_MODE=product|parity            renderer override
//   S3DV_VIEWER_BUDGET_MB=<int>                memory budget override (0 = unlimited)
//   S3DV_VIEWER_SETTLE_MS=<int>                wait after end-of-stream before probing (default 3000)
//   S3DV_VIEWER_SOAK_SECONDS=<double>          run for N s then report (leak/soak mode)
//   S3DV_VIEWER_SHOT / _SHOT2                  PNG screenshot destinations
//   S3DV_VIEWER_TIMEOUT=<seconds>              watchdog (default 75)
//
// Exit codes: 0 = match, 3 = mismatch/config error/open failure, 4 = timeout.
import Foundation
import AppKit
import WebKit
import S3DVCore

@MainActor
final class AutotestController {
    weak var app: AppState?

    private let reportPath: URL?
    private let expected: [String: Any]?
    private let filePath: String
    private let shotPath: URL?
    private let shot2Path: URL?
    private let settleMilliseconds: Int
    private let soakSeconds: Double?
    let rate: Double?
    let rendererOverride: RendererMode?
    let budgetOverride: Int?

    private var cycles = 0
    private var baselineMB: Double = 0
    private let repeatCount: Int
    private var finishing = false
    private var reportWritten = false
    private var watchdogFired = false
    private var startedAt = Date()
    private var peak: ProcessMemory.PeakSampler?
    /// Packets the host drained from the page's apply queue via flushInbox
    /// (frame-complete mode); recorded so a stall is visible in the report.
    private var flushedPackets = 0

    private init(reportPath: URL?, expected: [String: Any]?, rate: Double?, filePath: String,
                 shotPath: URL?, shot2Path: URL?, settle: Int, soak: Double?,
                 renderer: RendererMode?, budget: Int?, repeatCount: Int) {
        self.reportPath = reportPath
        self.expected = expected
        self.rate = rate
        self.filePath = filePath
        self.shotPath = shotPath
        self.shot2Path = shot2Path
        self.settleMilliseconds = settle
        self.soakSeconds = soak
        self.rendererOverride = renderer
        self.budgetOverride = budget
        self.repeatCount = repeatCount
    }

    // MARK: - factory

    static func createIfRequested() -> AutotestController? {
        let env = ProcessInfo.processInfo.environment
        guard env["S3DV_VIEWER_AUTOTEST"] == "1" else { return nil }
        let reportPath = env["S3DV_VIEWER_REPORT"].map { URL(fileURLWithPath: $0) }
        var expected: [String: Any]?
        if let raw = env["S3DV_VIEWER_EXPECT"], !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            expected = parsed
        }
        var rate: Double?
        if let raw = env["S3DV_VIEWER_RATE"], let parsed = Double(raw), parsed > 0 { rate = parsed }
        var renderer: RendererMode?
        if let raw = env["S3DV_VIEWER_MODE"], let parsed = RendererMode(rawValue: raw) { renderer = parsed }
        var budget: Int?
        if let raw = env["S3DV_VIEWER_BUDGET_MB"], let parsed = Int(raw), parsed >= 0 { budget = parsed }
        var soak: Double?
        if let raw = env["S3DV_VIEWER_SOAK_SECONDS"], let parsed = Double(raw), parsed > 0 { soak = parsed }
        let fileArg = ProcessInfo.processInfo.arguments.first { $0.hasSuffix(".s3dv") } ?? ""
        return AutotestController(reportPath: reportPath, expected: expected, rate: rate,
                                  filePath: fileArg,
                                  shotPath: env["S3DV_VIEWER_SHOT"].map { URL(fileURLWithPath: $0) },
                                  shot2Path: env["S3DV_VIEWER_SHOT2"].map { URL(fileURLWithPath: $0) },
                                  settle: Int(env["S3DV_VIEWER_SETTLE_MS"] ?? "") ?? 3000,
                                  soak: soak, renderer: renderer, budget: budget,
                                  repeatCount: Int(env["S3DV_VIEWER_REPEAT"] ?? "") ?? 0)
    }

    // MARK: - lifecycle

    func startWatchdog() {
        let timeout = Double(ProcessInfo.processInfo.environment["S3DV_VIEWER_TIMEOUT"] ?? "") ?? 75
        let sampler = ProcessMemory.PeakSampler()
        sampler.start()
        peak = sampler
        startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.watchdogFired, !self.reportWritten else { return }
            self.watchdogFired = true
            self.writeReport(verdict: "timeout", mismatch: "watchdog fired after \(timeout) s")
        }
        if ProcessInfo.processInfo.environment["S3DV_VIEWER_CONTROL_SMOKE"] == "1" {
            let steps: [(Double, String)] = [
                (6.0, "window.__s3dv && window.__s3dv.pause()"),
                (7.0, "window.__s3dv && window.__s3dv.step()"),
                (8.0, "window.__s3dv && window.__s3dv.seek(0)"),
                (9.0, "window.__s3dv && window.__s3dv.resume()"),
            ]
            for (delay, js) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.app?.webView.runJS(js)
                }
            }
        }
        if let soakSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + soakSeconds) { [weak self] in
                self?.finishSoak()
            }
        }
    }

    /// Called by AppState when the replay reaches a clean end of stream.
    func streamFinished() {
        guard !finishing, soakSeconds == nil else { return }
        finishing = true
        Task { @MainActor in
            if cycles == 0 { baselineMB = ProcessMemory.footprintMegabytes }
            if cycles < repeatCount, let url = app?.document?.url, app?.document?.isRemote == false {
                cycles += 1
                CrashGuard.shared.log("leak cycle \(cycles)/\(repeatCount) footprint=\(String(format: "%.1f", ProcessMemory.footprintMegabytes)) MB")
                try? await Task.sleep(nanoseconds: 400_000_000)
                finishing = false
                await app?.open(url)
                return
            }
            await drainAndProbe()
        }
    }

    /// Waits until the page has applied every packet the engine sent (or stops
    /// moving), so the parity check measures the stream, not the probe timing.
    /// Frame-complete presentation adds a second queue inside the page: packets
    /// arrive before they are applied, so after the arrival counter settles the
    /// presenter still needs ticks to catch up — and if the page is hidden or
    /// otherwise stalled, the host drains the queue via `__s3dv.flushInbox`.
    private func drainAndProbe() async {
        guard let app else { return }
        let wantsApplyWait = app.settings.v.renderer == .product
            && app.settings.v.presentationMode == .frameComplete
        let deadline = Date().addingTimeInterval(120)
        var last = -1
        var stable = 0
        while Date() < deadline {
            let applied = await appliedPackets()
            var backlog = 0
            if wantsApplyWait, applied == app.stats.framesSent {
                backlog = await backlogPackets()
                if backlog <= 0 { break }
            } else if applied == app.stats.framesSent {
                break
            }
            if applied == last { stable += 1 } else { stable = 0 }
            last = applied
            if stable >= 3 {
                stable = 0
                if wantsApplyWait && backlog > 0 {
                    flushedPackets += await flushInbox()
                } else {
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await probeAndReport()
    }

    private func appliedPackets() async -> Int {
        guard let text = await evaluate(ViewerBootScript.telemetryJS),
              let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = (dict["packets"] as? NSNumber)?.intValue else { return -1 }
        return n
    }

    /// Packets received by the page but not yet applied to the scene
    /// (frame-complete mode only; the telemetry probe reports it).
    private func backlogPackets() async -> Int {
        guard let text = await evaluate(ViewerBootScript.telemetryJS),
              let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = (dict["backlog"] as? NSNumber)?.intValue else { return 0 }
        return n
    }

    /// Host-side drain of the page's apply queue. Returns how many packets the
    /// page applied in response (0 when the API is unavailable, e.g. parity).
    private func flushInbox() async -> Int {
        let n = await evaluateNumber(
            "(window.__s3dv && window.__s3dv.flushInbox) ? window.__s3dv.flushInbox(4000) : -1")
        return n > 0 ? Int(n) : 0
    }

    func failFast(_ reason: String) {
        guard !reportWritten else { return }
        writeReport(verdict: "fail", mismatch: reason, extra: ["statusText": app?.statusText ?? ""])
    }

    private func finishSoak() {
        guard !finishing, !reportWritten else { return }
        finishing = true
        Task { @MainActor in
            await probeAndReport(soak: true)
        }
    }

    // MARK: - probe

    private func probeAndReport(soak: Bool = false) async {
        guard let app else { return }
        var viewer: [String: Any] = [:]
        if let text = await evaluate(ViewerBootScript.telemetryJS),
           let data = text.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            viewer = dict
        }
        // Real frame cost (GPU-synchronised) plus whether the window was even
        // visible: a backgrounded window throttles rAF, which invalidates any
        // fps number taken from the render loop.
        let benchMS = await evaluateNumber("(window.__s3dv && window.__s3dv.benchmark) ? window.__s3dv.benchmark(8) : -1")
        let hidden = await evaluate("JSON.stringify({hidden: document.hidden, state: document.visibilityState})") ?? "{}"
        if let shotPath { await snapshot(to: shotPath, wireframe: false) }
        if let shot2Path { await snapshot(to: shot2Path, wireframe: true) }

        let nativePackets = app.document?.packetCount ?? 0
        let nativeBytes = app.document?.byteCount ?? 0
        var mismatch: [String] = []

        if let expected {
            for (key, raw) in expected {
                guard let want = (raw as? NSNumber)?.doubleValue else { continue }
                let got: Double?
                switch key {
                case "packets": got = (viewer["packets"] as? NSNumber)?.doubleValue
                case "chunks": got = (viewer["chunks"] as? NSNumber)?.doubleValue
                case "triangles": got = (viewer["triangles"] as? NSNumber)?.doubleValue
                case "bytes":
                    let label = (viewer["bytesLabel"] as? String) ?? ""
                    got = Double(label.replacingOccurrences(of: "[^0-9.]", with: "",
                                                            options: .regularExpression))
                        .map { $0 * 1024 } // label is KB
                default: got = nil
                }
                guard let got else {
                    mismatch.append("\(key): missing")
                    continue
                }
                if abs(got - want) > 0.5 { mismatch.append("\(key): js=\(got) native=\(want)") }
            }
        }

        // Stream integrity: every packet the engine sent must have been applied by
        // the page. This is the regression test for the truncation bug where a
        // 1.27 GB replay lost 28 % of its packets to an early socket teardown.
        // Every packet the engine put on the wire must have been applied by the
        // page. Compared against packetsSent, not the file's packet count, because
        // budgeted replay legitimately skips chunks (reported as `deferred`).
        // Compare against frames, not packets: budgeted replay injects
        // CHUNK_REMOVE frames, and the page counts every frame it receives.
        if let applied = (viewer["packets"] as? NSNumber)?.intValue, app.stats.framesSent > 0 {
            if applied != app.stats.framesSent, !soak {
                mismatch.append("packetParity: js=\(applied) frames=\(app.stats.framesSent) "
                    + "(packets=\(app.stats.packetsSent), evicted=\(app.stats.evictions))")
            }
        }

        // Frame-complete presentation (product renderer): the presenter must
        // have surfaced the stream. A hidden or noRender page still applies
        // everything, so `dropped` (applied states that were folded into a
        // later complete frame) carries the signal; presented==dropped==0 with
        // packets applied means the presentation loop never ran at all.
        if app.settings.v.renderer == .product, !soak {
            let presented = (viewer["presented"] as? NSNumber)?.intValue ?? -1
            let dropped = (viewer["dropped"] as? NSNumber)?.intValue ?? -1
            let backlog = (viewer["backlog"] as? NSNumber)?.intValue ?? -1
            if presented == -1 && dropped == -1 {
                mismatch.append("presentation counters missing (product renderer)")
            } else {
                let appliedNow = (viewer["packets"] as? NSNumber)?.intValue ?? 0
                if appliedNow > 0 && presented == 0 && dropped == 0 {
                    mismatch.append("presentation idle: presented=0 dropped=0 applied=\(appliedNow)")
                }
                if backlog > 0 {
                    mismatch.append("presentation backlog: \(backlog) packets never applied")
                }
            }
        }
        let errorCount = app.consoleEntries.filter { $0.level == "ERROR" }.count
        if errorCount > 0 { mismatch.append("console errors: \(errorCount)") }

        peak?.stop()
        var extra: [String: Any] = [
            "statusText": app.statusText,
            "mode": app.settings.v.renderer.rawValue,
            "budgetMB": app.settings.budgetMegabytes,
            "nativePackets": nativePackets,
            "nativeBytes": nativeBytes,
            "peakMB": round((peak?.peakMegabytes ?? 0) * 10) / 10,
            "currentMB": round(ProcessMemory.footprintMegabytes * 10) / 10,
            "elapsedSeconds": round(Date().timeIntervalSince(startedAt) * 100) / 100,
            "console": app.consoleEntries.suffix(40).map { "\($0.level) \($0.text)" },
            "viewer": viewer,
            "leakMBPerCycle": repeatCount > 0 && cycles > 0
                ? round(((ProcessMemory.footprintMegabytes - baselineMB) / Double(cycles)) * 100) / 100 : nil,
            "benchFrameMS": benchMS,
            "visibility": hidden,
            "presentation": [
                "presented": (viewer["presented"] as? NSNumber)?.intValue ?? -1,
                "dropped": (viewer["dropped"] as? NSNumber)?.intValue ?? -1,
                "backlog": (viewer["backlog"] as? NSNumber)?.intValue ?? -1,
                "mode": app.settings.v.presentationMode.rawValue,
                "applyBudgetMs": app.settings.v.applyBudgetMs,
                "flushedByHost": flushedPackets,
            ],
            "stats": [
                "packetsSent": app.stats.packetsSent,
                "framesSent": app.stats.framesSent,
                "bytesSent": app.stats.bytesSent,
                "residentChunks": app.stats.residentChunks,
                "residentTriangles": app.stats.residentTriangles,
                "evictions": app.stats.evictions,
                "evictionsTotal": app.stats.evictionsTotal,
                "deferred": app.stats.deferred,
            ],
        ]
        if repeatCount > 0 {
            let slope = cycles > 0
                ? (ProcessMemory.footprintMegabytes - baselineMB) / Double(cycles) : 0
            if cycles >= 3 && slope > 5 {
                mismatch.append("leak: \(String(format: "%.1f", slope)) MB/cycle over \(cycles) cycles")
            }
            extra["cycles"] = cycles
            extra["baselineMB"] = round(baselineMB * 10) / 10
            extra["mbPerCycle"] = cycles > 0
                ? round(((ProcessMemory.footprintMegabytes - baselineMB) / Double(cycles)) * 10) / 10 : 0
        }
        if soak {
            extra["soakSeconds"] = soakSeconds ?? 0
            extra["soakPeakMB"] = round((peak?.peakMegabytes ?? 0) * 10) / 10
        }
        writeReport(verdict: mismatch.isEmpty ? "pass" : "fail",
                    mismatch: mismatch.joined(separator: "; "), extra: extra)
    }

    private func evaluateNumber(_ js: String) async -> Double {
        guard let app else { return -1 }
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            app.webView.evaluateJavaScript(js) { result, _ in continuation.resume(returning: result) }
        }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        return -1
    }

    private func evaluate(_ js: String) async -> String? {
        guard let app else { return nil }
        return await withCheckedContinuation { continuation in
            app.webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func snapshot(to url: URL, wireframe: Bool) async {
        guard let app else { return }
        if wireframe {
            app.webView.runJS(ViewerBootScript.toggleWireframeProduct)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let config = WKSnapshotConfiguration()
        config.rect = app.webView.bounds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            app.webView.takeSnapshot(with: config) { image, _ in
                if let image, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
                continuation.resume()
            }
        }
    }

    // MARK: - report

    private func writeReport(verdict: String, mismatch: String?, extra: [String: Any] = [:]) {
        guard !reportWritten else { return }
        reportWritten = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var report: [String: Any] = [
            "app": "S3DV viewer",
            "version": version,
            "file": filePath,
            "rate": rate ?? app?.settings.v.rate ?? 1,
            "verdict": verdict,
            "timedOut": watchdogFired,
        ]
        if let mismatch, !mismatch.isEmpty { report["mismatch"] = mismatch }
        if let app {
            report["state"] = [
                "phase": app.stats.phase.rawValue,
                "pageReady": app.pageReady,
                "recovered": app.recoveredFromCrash,
                "packetsSent": app.stats.packetsSent,
                "framesSent": app.stats.framesSent,
                "packetCount": app.stats.packetCount,
                "chunks": app.stats.residentChunks,
                "evictions": app.stats.evictions,
                "evictionsTotal": app.stats.evictionsTotal,
            ]
        }
        for (key, value) in extra { report[key] = value }
        if let reportPath,
           let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportPath)
        }
        if verdict != "pass" {
            FileHandle.standardError.write(Data("[autotest] \(verdict): \(mismatch ?? "")\n".utf8))
        }
        let code: Int32 = verdict == "pass" ? 0 : (verdict == "timeout" ? 4 : 3)
        AutotestController.pendingExitCode = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// Consumed by AppDelegate.applicationWillTerminate so the process exits with
    /// the verdict code while still running the clean-shutdown path.
    nonisolated(unsafe) static var pendingExitCode: Int32 = 0
}
