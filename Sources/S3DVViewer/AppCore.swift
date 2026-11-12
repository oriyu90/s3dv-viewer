// Central coordinator: open a recording → embedded loopback servers → viewer
// page in WKWebView → native replay session → live telemetry back into SwiftUI.
//
// Memory/robustness contract
//  * the recording is memory-mapped and streamed lazily (ReplaySession), never
//    materialised as an array of packets;
//  * console entries are a bounded ring, JS telemetry is polled (never pushed
//    per packet) and every timer/socket/task is torn down by closeSession();
//  * a WebContent process crash is caught and recovered instead of killing the
//    app, and the crash is written to the log before recovery.
import Foundation
import AppKit
import WebKit
import Network
import UniformTypeIdentifiers
import S3DVCore
import S3DVControl

/// Everything the UI needs to know about the open stream.
struct StreamDocument: Equatable {
    var url: URL
    var name: String
    var byteCount: Int
    var packetCount: Int
    var durationSeconds: Double
    var snapshots: Int
    var chunks: Int
    var triangles: Int
    var textures: Int
    var residentMegabytes: Double
    var vertices: Int
    var isRemote: Bool
    var metadata: [String: String]

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// Live numbers read back from the page (all browser-side proxies).
struct ViewerMetrics: Equatable {
    var fps: Double = 0
    var frameMs: Double = 0
    var drawCalls: Double = 0
    var geometries: Double = 0
    var chunks: Int = 0
    var triangles: Int = 0
    var packets: Int = 0
    var evicted: Int = 0
    var deferred: Int = 0
    var arenaMegabytes: Double = 0
    // Frame-complete presentation counters (product renderer only; 0 otherwise).
    var presented: Int = 0
    var dropped: Int = 0
    var backlog: Int = 0
    var status: String = ""
}

@MainActor
final class AppState: NSObject, ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable { case home, studio }

    struct ConsoleEntry: Identifiable, Equatable {
        let id = UUID()
        var level: String
        var text: String
        var at = Date()
    }

    // MARK: - published state

    @Published var phase: Phase = .home
    @Published var statusText = "Ready"
    @Published var currentFile: URL?
    @Published var document: StreamDocument?
    @Published var recentURLs: [URL] = []
    @Published var consoleEntries: [ConsoleEntry] = []
    @Published var stats = ReplayStats.zero
    @Published var metrics = ViewerMetrics()
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var recoveredFromCrash = false
    @Published var pageReady = false

    let settings = AppSettings.shared
    let webView: WKWebView

    /// UNIX socket that lets `s3dvctl` drive the running app.
    private var controlServer: ControlServer?
    private var controlRouter: ControlRouter?
    var controlSocketPath: String { ControlPath.socketURL().path }
    var httpBoundPort: UInt16 { httpPort }
    var wsBoundPort: UInt16 { wsPort }

    // MARK: - internals

    private let bridge = ScriptBridge()
    private var recording: S3DVRecording?
    private var session: ReplaySession?
    private var httpServer: EmbeddedHTTPServer?
    private var wsServer: EmbeddedWSServer?
    private var wsPort: UInt16 = 0
    private var httpPort: UInt16 = 0
    private var metricsTimer: Timer?
    private var memorySource: DispatchSourceMemoryPressure?
    private var lastAutoOpened: (url: URL, at: TimeInterval)?
    private(set) var autotest: AutotestController?
    private var recoveryAttempts = 0
    /// Incremented by every open/close so a stale in-flight open can detect that
    /// it lost the race instead of installing its server pair and document.
    private var openGeneration = 0
    /// App Nap suspension token. Without it macOS throttles a replay whose window
    /// is hidden or off-screen: heartbeats showed 25 s gaps between packets that
    /// are 0.4 s apart at the configured rate.
    private var activityToken: NSObjectProtocol?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700), configuration: config)
        super.init()
        webView.underPageBackgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1)
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge.app = self
        controller.add(bridge, name: "s3dv")
        controller.add(bridge, name: "s3dvLog")
        recentURLs = Self.loadRecent()
        autotest = AutotestController.createIfRequested()
        autotest?.app = self
        autotest?.startWatchdog()
        observeMemoryPressure()
        if let diagnostic = settings.loadDiagnostic {
            recordConsole(level: "WARN", text: diagnostic)
        }
        startControlServer()
    }

    // MARK: - bundle assets

    static var webRoot: URL? { Bundle.main.resourceURL?.appendingPathComponent("web") }
    static var demoRecordingURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("demo/cube_orbit.s3dv")
    }

    // MARK: - opening

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("S3DV 録画を開く", comment: "File open panel title")
        panel.message = NSLocalizedString("S3DPパケットを含む .s3dv ファイルを選択してください", comment: "File open panel message")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let s3dv = UTType(filenameExtension: "s3dv", conformingTo: .data) {
            panel.allowedContentTypes = [s3dv, .data]
        } else {
            panel.allowedContentTypes = [.data]
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    func openDemo() async {
        guard let url = Self.demoRecordingURL, FileManager.default.fileExists(atPath: url.path) else {
            present(error: NSLocalizedString("同梱デモ (demo/cube_orbit.s3dv) が見つかりません。アプリを再ビルドしてください。", comment: "Bundled demo not found error"))
            return
        }
        await open(url)
    }

    func open(_ url: URL) async {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastAutoOpened,
           last.url == url.standardizedFileURL, now - last.at < 0.5 { return }
        lastAutoOpened = (url.standardizedFileURL, now)

        closeSession(keepWindow: true)
        openGeneration &+= 1
        let generation = openGeneration
        recoveryAttempts = 0
        isLoading = true
        errorMessage = nil
        statusText = NSLocalizedString("検証中…", comment: "Status while verifying recording")

        let deep = settings.v.deepVerifyOnOpen
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (S3DVRecording, S3DVStats) in
                let rec = try S3DVRecording(contentsOf: url)
                if deep { try rec.deepVerify() }
                let stats = rec.stats(includeResident: rec.packetCount < 400_000)
                return (rec, stats)
            }.value
            guard generation == self.openGeneration else { return }
            recording = loaded.0
            document = Self.makeDocument(url: url, recording: loaded.0, stats: loaded.1)
            currentFile = url
            addRecent(url)
            phase = .studio
            consoleEntries.removeAll()
            isLoading = false
            statusText = NSLocalizedString("埋め込みビューアを起動中…", comment: "Status while launching embedded viewer")
            try await ensureServersStarted()
            guard generation == self.openGeneration else { return }
            await loadPage()
        } catch {
            isLoading = false
            phase = .home
            statusText = "Ready"
            FileHandle.standardError.write(Data("[app] open failed: \(url.lastPathComponent): \(error)\n".utf8))
            CrashGuard.shared.log("open failed: \(url.path): \(error)")
            if autotest != nil {
                recordConsole(level: "ERROR", text: "open failed: \(error)")
                autotest?.failFast("open failed: \(error)")
                return
            }
            present(error: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func makeDocument(url: URL, recording: S3DVRecording,
                                     stats: S3DVStats) -> StreamDocument {
        var metadata: [String: String] = [:]
        if let dict = recording.metadataJSON as? [String: Any] {
            for key in ["creator", "representation", "stream_semantics", "source",
                        "fusion", "coordinate_unit", "frame_rate_nominal"] {
                if let value = dict[key] { metadata[key] = "\(value)" }
            }
        }
        return StreamDocument(url: url,
                              name: url.lastPathComponent,
                              byteCount: recording.bytesOnDisk,
                              packetCount: recording.packetCount,
                              durationSeconds: stats.durationSeconds,
                              snapshots: stats.snapshots,
                              chunks: stats.residentChunks,
                              triangles: stats.residentTriangles,
                              textures: stats.textures,
                              residentMegabytes: stats.residentMegabytes,
                              vertices: stats.residentVertices,
                              isRemote: false,
                              metadata: metadata)
    }

    /// Remote `s3dv serve` endpoint: no native replay, the page connects directly.
    func connectRemote() {
        let raw = settings.v.remoteURL
        guard let endpoint = URL(string: raw) else {
            present(error: String(format: NSLocalizedString("リモートURLが不正です: %@", comment: "Invalid remote URL error"), raw))
            return
        }
        Task {
            closeSession(keepWindow: true)
            errorMessage = nil
            phase = .studio
            recoveryAttempts = 0
            isLoading = false
            currentFile = nil
            document = StreamDocument(url: endpoint, name: endpoint.absoluteString, byteCount: 0,
                                      packetCount: 0, durationSeconds: 0, snapshots: 0,
                                      chunks: 0, triangles: 0, textures: 0,
                                      residentMegabytes: 0, vertices: 0,
                                      isRemote: true, metadata: [:])
            statusText = NSLocalizedString("リモートに接続中…", comment: "Status while connecting to remote")
            do {
                try await ensureServersStarted()
                await loadPage()
            } catch {
                present(error: error.localizedDescription)
            }
        }
    }

    func closeSession(keepWindow: Bool = false) {
        openGeneration &+= 1
        stopMetricsPolling()
        endPlaybackActivity()
        session?.cancel()
        session = nil
        httpServer?.stop()
        wsServer?.stop()
        httpServer = nil
        wsServer = nil
        recording = nil
        document = nil
        currentFile = nil
        stats = .zero
        metrics = ViewerMetrics()
        pageReady = false
        statusText = "Ready"
        // Blanking the page releases the WebGL scene, geometries and textures.
        webView.loadHTMLString("<body style=\"background:#0e131c\"></body>", baseURL: nil)
        if !keepWindow {
            phase = .home
        }
    }

    private func startControlServer() {
        let router = ControlRouter()
        router.app = self
        let server = ControlServer()
        server.onRequest = { [weak router] line in
            guard let request = ControlRequest.parse(line) else {
                return ControlJSON.error("malformed request: send one JSON object per line")
            }
            guard let router else { return ControlJSON.error("app is shutting down") }
            return await router.respond(to: request)
        }
        do {
            try server.start(path: ControlPath.socketURL().path)
            controlRouter = router
            controlServer = server
        } catch {
            // The viewer stays fully usable from the GUI; only the CLI is lost.
            CrashGuard.shared.log("control socket unavailable: \(error.localizedDescription)")
            recordConsole(level: "WARN", text: "CLI制御ソケットを開始できません: \(error.localizedDescription)")
        }
    }

    /// Evaluates JavaScript in the viewer page and returns the raw result.
    func evaluateJS(_ source: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(source) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    /// Screenshot of the viewer viewport (used by `s3dvctl screenshot`).
    func captureSnapshot(to url: URL) async -> Bool {
        guard pageReady else { return false }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try png.write(to: url)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func shutdown() {
        controlServer?.stop()
        controlServer = nil
        controlRouter = nil
        stopMetricsPolling()
        session?.cancel()
        session = nil
        settings.flush()
        httpServer?.stop()
        wsServer?.stop()
        httpServer = nil
        wsServer = nil
        memorySource?.cancel()
        memorySource = nil
    }

    // MARK: - servers

    private func ensureServersStarted() async throws {
        guard httpServer == nil else { return }
        guard let root = Self.webRoot else {
            throw S3DVError.invalid(NSLocalizedString("アプリバンドルに web リソースがありません（再ビルドしてください）", comment: "Missing web resources error"))
        }
        let http = EmbeddedHTTPServer()
        let ws = EmbeddedWSServer()
        http.metadataProvider = { [weak self] in
            guard let self, let doc = self.document else { return Data("{}".utf8) }
            let payload: [String: Any] = [
                "name": doc.name,
                "duration_ns": UInt64(doc.durationSeconds * 1e9),
                "packet_count": doc.packetCount,
                "chunks": doc.chunks,
                "triangles": doc.triangles,
                "bytes": doc.byteCount,
                "viewer": "S3DV viewer",
                "renderer": self.settings.v.renderer.rawValue,
                "budget_mb": self.settings.budgetMegabytes,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        }
        do {
            let boundHTTP = try await http.start(documentRoot: root,
                                                port: UInt16(clamping: settings.v.httpPort))
            ws.onConnection = { [weak self] connection in
                Task { @MainActor in self?.attach(connection) }
            }
            let boundWS = try await ws.start(port: UInt16(clamping: settings.v.wsPort),
                                             maxClients: settings.v.maxClients)
            httpServer = http
            wsServer = ws
            httpPort = boundHTTP
            wsPort = boundWS
        } catch {
            http.stop()
            ws.stop()
            throw error
        }
    }

    private func attach(_ connection: NWConnection) {
        // A fresh client always replays from the first packet (server.py parity).
        session?.cancel()
        guard document?.isRemote != true, let recording else {
            connection.cancel()
            return
        }
        let rc = ReplayConnection(connection: connection)
        let options = ReplayOptions(rate: settings.v.rate,
                                    pacingCap: settings.v.pacingCapSeconds,
                                    loop: settings.v.loopPlayback,
                                    loopGap: settings.v.loopGapSeconds,
                                    startPaused: settings.v.startPaused,
                                    allowControl: settings.v.allowControlChannel,
                                    budgetBytes: settings.budgetMegabytes * 1_048_576,
                                    evictionPolicy: settings.v.evictionPolicy,
                                    arenaVertices: settings.v.arenaVertices)
        let session = ReplaySession(recording: recording, connection: rc, options: options)
        session.onStats = { [weak self] stats in
            self?.apply(stats)
        }
        rc.onText = { [weak session] text in
            // Called on the socket's queue. Hop to the main actor instead of
            // assuming isolation (that assumption trapped the process), and
            // answer without waiting: the viewer ignores acks.
            Task { @MainActor in
                guard let session else { return }
                _ = session.handle(text: text)
            }
            return nil
        }
        rc.onRemoteClosed = { [weak self] in
            Task { @MainActor in self?.clientDisconnected() }
        }
        rc.startReceiving()
        self.session = session
        session.start()
        startMetricsPolling()
        beginPlaybackActivity()
    }

    private func beginPlaybackActivity() {
        endPlaybackActivity()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled],
            reason: "S3DV replay in progress")
    }

    private func endPlaybackActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func clientDisconnected() {
        guard stats.phase != .finished, stats.phase != .stopped else { return }
        stats.phase = .stopped
        statusText = NSLocalizedString("クライアントが切断しました", comment: "Status: client disconnected")
    }

    private var lastHeartbeat = Date.distantPast

    private func apply(_ stats: ReplayStats) {
        self.stats = stats
        if Date().timeIntervalSince(lastHeartbeat) > 5 {
            lastHeartbeat = Date()
            CrashGuard.shared.log("progress packets=\(stats.packetsSent)/\(stats.packetCount) "
                + "phase=\(stats.phase.rawValue) chunks=\(stats.residentChunks) "
                + "evict=\(stats.evictions) mb=\(String(format: "%.0f", ProcessMemory.footprintMegabytes))")
        }
        switch stats.phase {
        case .playing: statusText = NSLocalizedString("再生中", comment: "Status: playing")
        case .paused: statusText = NSLocalizedString("一時停止", comment: "Status: paused")
        case .seeking: statusText = NSLocalizedString("シーク中…", comment: "Status: seeking")
        case .finished:
            statusText = NSLocalizedString("完了", comment: "Status: finished")
            stopMetricsPolling()
            endPlaybackActivity()
            autotest?.streamFinished()
        case .failed:
            statusText = stats.errorText.isEmpty
                ? NSLocalizedString("エラー", comment: "Status: error")
                : String(format: NSLocalizedString("エラー: %@", comment: "Status: error with message"), stats.errorText)
        case .stopped: statusText = NSLocalizedString("停止", comment: "Status: stopped")
        case .idle: statusText = NSLocalizedString("待機", comment: "Status: idle")
        }
    }

    // MARK: - page

    private func loadPage() async {
        guard httpServer != nil, document != nil else { return }
        let renderer = settings.v.renderer
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let config: [String: Any] = [
            "renderer": renderer.rawValue,
            "budgetMB": settings.budgetMegabytes,
            "arenaVertices": settings.v.arenaVertices,
            "wireframe": settings.v.wireframe,
            "grid": settings.v.showGrid,
            "hud": settings.v.showViewerHUD,
            "pixelRatio": settings.v.pixelRatioCap,
            "textureQuality": settings.v.textureQuality,
            "autoReconnect": settings.v.autoReconnect,
            "reconnectAttempts": settings.v.reconnectAttempts,
            "telemetryHz": settings.v.telemetryHz,
            "isRemote": document?.isRemote == true,
            "noRender": ProcessInfo.processInfo.environment["S3DV_VIEWER_NO_RENDER"] == "1",
            "expectedVertices": document?.vertices ?? 0,
            "presentation": settings.v.presentationMode.rawValue,
            "applyBudgetMs": settings.v.applyBudgetMs,
        ]
        let wsOverride = (document?.isRemote == true)
            ? settings.v.remoteURL
            : "ws://127.0.0.1:\(wsPort)/ws"
        controller.addUserScript(WKUserScript(
            source: ViewerBootScript.source(wsURL: wsOverride, renderer: renderer, config: config),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        let page = renderer == .product ? "viewer.html" : "index.html"
        let url = URL(string: "http://127.0.0.1:\(httpPort)/\(page)")
        pageReady = false
        webView.load(URLRequest(url: url ?? URL(fileURLWithPath: "/")))
    }

    /// Re-applies settings that can change without a page reload.
    func applyLiveSettings() {
        guard webView.url != nil else { return }
        let config: [String: Any] = [
            "budgetMB": settings.budgetMegabytes,
            "arenaVertices": settings.v.arenaVertices,
            "wireframe": settings.v.wireframe,
            "grid": settings.v.showGrid,
            "hud": settings.v.showViewerHUD,
            "pixelRatio": settings.v.pixelRatioCap,
            "textureQuality": settings.v.textureQuality,
            "autoReconnect": settings.v.autoReconnect,
            "reconnectAttempts": settings.v.reconnectAttempts,
            "presentation": settings.v.presentationMode.rawValue,
            "applyBudgetMs": settings.v.applyBudgetMs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let json = String(data: data, encoding: .utf8) {
            webView.runJS("window.__s3dvHost && window.__s3dvHost.applyConfig(\(json))")
        }
        session?.updateOptions(rate: settings.v.rate,
                               loop: settings.v.loopPlayback,
                               budget: settings.budgetMegabytes * 1_048_576,
                               policy: settings.v.evictionPolicy)
    }

    func reloadPage() {
        Task { await loadPage() }
    }

    // MARK: - transport

    func togglePause() {
        session?.handle(stats.phase == .paused ? .resume : .pause)
        if settings.v.renderer == .parity {
            webView.runJS("window.__s3dvHost && window.__s3dvHost.click('pause')")
        }
    }

    func stepForward() { session?.handle(.step) }

    func seek(to seconds: Double) { session?.handle(.seek(seconds)) }

    func setRate(_ value: Double) {
        settings.set { $0.rate = value }
        session?.handle(.speed(value))
        if settings.v.renderer == .parity {
            webView.runJS("window.__s3dvHost && window.__s3dvHost.setSpeed(\(value))")
        }
    }

    func restart() { Task { await reloadPage() } }

    func toggleWireframe() {
        settings.set { $0.wireframe.toggle() }
        let js = settings.v.renderer == .product
            ? ViewerBootScript.toggleWireframeProduct
            : ViewerBootScript.toggleWireframeParity
        webView.runJS(js)
    }

    func resetView() {
        let js = settings.v.renderer == .product
            ? ViewerBootScript.resetViewProduct
            : ViewerBootScript.resetViewParity
        webView.runJS(js)
    }

    // MARK: - metrics polling

    private func startMetricsPolling() {
        stopMetricsPolling()
        let interval = max(0.1, 1.0 / max(0.5, settings.v.telemetryHz))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMetrics() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    private func stopMetricsPolling() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    private func pollMetrics() {
        guard pageReady else { return }
        webView.evaluateJavaScript(ViewerBootScript.telemetryJS) { [weak self] result, _ in
            guard let self, let text = result as? String, let data = text.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            func number(_ key: String) -> Double {
                if let n = dict[key] as? NSNumber { return n.doubleValue }
                return 0
            }
            var m = ViewerMetrics()
            m.fps = number("fps")
            m.frameMs = number("frameMs")
            m.drawCalls = number("drawCalls")
            m.geometries = number("geometries")
            m.chunks = Int(number("chunks"))
            m.triangles = Int(number("triangles"))
            m.packets = Int(number("packets"))
            m.evicted = Int(number("evicted"))
            m.deferred = Int(number("deferred"))
            m.arenaMegabytes = number("arenaBytes") / 1_048_576
            m.presented = Int(number("presented"))
            m.dropped = Int(number("dropped"))
            m.backlog = Int(number("backlog"))
            m.status = (dict["status"] as? String) ?? ""
            Task { @MainActor in self.metrics = m }
        }
    }

    // MARK: - crash + memory pressure

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.settings.v.reduceOnMemoryPressure else { return }
            let level = source.data.contains(.critical) ? "critical" : "warning"
            CrashGuard.shared.log("memory pressure: \(level)")
            self.recordConsole(level: "WARN", text: String(format: NSLocalizedString("メモリ圧迫 (%@) — 予算を縮小します", comment: "Memory pressure console warning"), level))
            let current = self.settings.budgetMegabytes
            guard current > 0 else { return }
            let reduced = max(512, Int(Double(current) * 0.6))
            self.session?.updateOptions(rate: self.settings.v.rate,
                                        loop: self.settings.v.loopPlayback,
                                        budget: reduced * 1_048_576,
                                        policy: self.settings.v.evictionPolicy)
            self.webView.runJS("window.__s3dv && window.__s3dv.trimTo(\(reduced))")
        }
        source.resume()
        memorySource = source
    }

    /// Called from WKWebView when its content process dies (OOM, GPU reset).
    func recoverFromWebContentTermination() {
        CrashGuard.shared.log("WebContent process terminated (attempt \(recoveryAttempts + 1))")
        recoveryAttempts += 1
        recoveredFromCrash = true
        pageReady = false
        stopMetricsPolling()
        guard recoveryAttempts <= 2, phase == .studio else {
            present(error: NSLocalizedString("ビューアの描画プロセスが繰り返し終了しました。設定でメモリ予算を下げるか、描画モードを「軽量」にしてください。", comment: "Repeated renderer process termination error"))
            return
        }
        if settings.budgetMegabytes > 1_024 { settings.set { $0.budget = .lean } }
        recordConsole(level: "WARN", text: String(format: NSLocalizedString("描画プロセスが終了しました。自動復帰します（%d/2）", comment: "Renderer process recovery console message"), recoveryAttempts))
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await loadPage()
        }
    }

    // MARK: - console

    func handleScriptMessage(name: String, body: Any) {
        if name == "s3dvLog", let dict = body as? [String: Any] {
            let level = (dict["level"] as? String) ?? "LOG"
            let text = (dict["text"] as? String) ?? ""
            recordConsole(level: level.uppercased(), text: text)
            return
        }
        if name == "s3dv", let dict = body as? [String: Any], let type = dict["type"] as? String {
            recordConsole(level: "INFO", text: "script event: \(type)")
        }
    }

    private func recordConsole(level: String, text: String) {
        // ERROR entries bypass the ring cap — they decide the autotest verdict.
        if level != "ERROR" {
            guard consoleEntries.count < 200 else { return }
        } else if consoleEntries.count > 400 {
            consoleEntries.removeFirst(200)
        }
        consoleEntries.append(ConsoleEntry(level: level, text: text))
    }

    // MARK: - recent files

    private static func loadRecent() -> [URL] {
        let raw = UserDefaults.standard.stringArray(forKey: "recent") ?? []
        return Array(raw.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(8))
    }

    private func addRecent(_ url: URL) {
        var list = recentURLs.filter { $0 != url }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(8))
        UserDefaults.standard.set(recentURLs.map { $0.absoluteString }, forKey: "recent")
    }

    // MARK: - alerting

    func present(error: String) { errorMessage = error }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: AppPaths.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppPaths.logsDirectory)
    }
}

// MARK: - WKWebView delegates

extension AppState: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        if stats.phase == .playing { statusText = NSLocalizedString("再生中", comment: "Status: playing") }
    }

    /// `loadHTMLString` used to blank the previous scene routinely cancels the
    /// pending navigation; that cancellation is not a failure.
    private func isBenignNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageReady = false
        guard !isBenignNavigationError(error) else { return }
        recordConsole(level: "ERROR", text: "page load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        pageReady = false
        guard !isBenignNavigationError(error) else { return }
        recordConsole(level: "ERROR", text: "page load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoverFromWebContentTermination()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        recordConsole(level: "ALERT", text: message)
        completionHandler()
    }
}

extension WKWebView {
    @MainActor
    func runJS(_ source: String) {
        evaluateJavaScript(source, completionHandler: nil)
    }
}

/// WKScriptMessageHandler hops to the main actor and forwards to AppState.
final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var app: AppState?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let app = self?.app else { return }
            app.handleScriptMessage(name: message.name, body: message.body)
        }
    }
}
