// Maps a control request onto AppState. Every operation the GUI exposes is
// reachable here, so the app can be driven entirely from a shell:
//
//   s3dvctl status
//   s3dvctl open ~/runs/tdt_fuse/prod_gt.s3dv
//   s3dvctl pause && s3dvctl step && s3dvctl seek 12.5 && s3dvctl play
//   s3dvctl set rate 0.5
//   s3dvctl set budget 384
//   s3dvctl bench 20
//   s3dvctl wait --timeout 600
//   s3dvctl quit
import Foundation
import AppKit
import S3DVCore
import S3DVControl

@MainActor
final class ControlRouter {
    weak var app: AppState?

    static let commands: [[String: String]] = [
        ["cmd": "help", "usage": "help", "desc": "この一覧"],
        ["cmd": "ping", "usage": "ping", "desc": "生存確認"],
        ["cmd": "status", "usage": "status", "desc": "再生状態・統計・サーバーポート"],
        ["cmd": "metrics", "usage": "metrics", "desc": "描画側の実測（fps / draw calls / メモリ）"],
        ["cmd": "open", "usage": "open path=<file.s3dv>", "desc": "録画を開く"],
        ["cmd": "demo", "usage": "demo", "desc": "同梱デモを開く"],
        ["cmd": "remote", "usage": "remote url=ws://host:port", "desc": "リモート s3dv serve へ接続"],
        ["cmd": "close", "usage": "close", "desc": "セッションを閉じてホームへ"],
        ["cmd": "play", "usage": "play", "desc": "再生"],
        ["cmd": "pause", "usage": "pause", "desc": "一時停止"],
        ["cmd": "toggle", "usage": "toggle", "desc": "再生/一時停止の切替"],
        ["cmd": "step", "usage": "step", "desc": "1パケット進む"],
        ["cmd": "seek", "usage": "seek t=<秒>", "desc": "シーク"],
        ["cmd": "rate", "usage": "rate <倍率>", "desc": "再生速度"],
        ["cmd": "loop", "usage": "loop on|off", "desc": "ループ再生"],
        ["cmd": "wireframe", "usage": "wireframe [on|off]", "desc": "ワイヤーフレーム"],
        ["cmd": "reset-view", "usage": "reset-view", "desc": "視点をリセット"],
        ["cmd": "reload", "usage": "reload", "desc": "ビューアを再読み込み"],
        ["cmd": "restart", "usage": "restart", "desc": "先頭から再生し直す"],
        ["cmd": "budget", "usage": "budget <MB>|off", "desc": "常駐ジオメトリ予算"],
        ["cmd": "renderer", "usage": "renderer product|parity", "desc": "描画モード（再読み込みを伴う）"],
        ["cmd": "presentation", "usage": "presentation framecomplete|immediate", "desc": "提示モード（フレーム完全/即時）"],
        ["cmd": "settings", "usage": "settings [set <key> <value>]", "desc": "設定の表示・変更"],
        ["cmd": "recent", "usage": "recent", "desc": "最近開いたファイル"],
        ["cmd": "logs", "usage": "logs [n]", "desc": "コンソールの末尾"],
        ["cmd": "bench", "usage": "bench [frames]", "desc": "GPU同期のフレームコスト計測"],
        ["cmd": "screenshot", "usage": "screenshot path=<png>", "desc": "ビューをPNG保存"],
        ["cmd": "wait", "usage": "wait [timeout=<秒>]", "desc": "再生完了まで待つ"],
        ["cmd": "quit", "usage": "quit", "desc": "アプリを終了"],
    ]

    func respond(to request: ControlRequest) async -> String {
        guard let app else { return ControlJSON.error("app not ready") }
        let command = request.cmd
        do {
            switch command {
            case "ping":
                return ok(["pong": true, "pid": Int(ProcessInfo.processInfo.processIdentifier)])
            case "help", "commands":
                return ok(["commands": Self.commands])
            case "status":
                return ok(statusPayload(app))
            case "metrics":
                return ok(await metricsPayload(app))
            case "open":
                return try await open(request, app)
            case "demo":
                await app.openDemo()
                return ok(statusPayload(app))
            case "remote":
                return try remote(request, app)
            case "close":
                app.closeSession()
                return ok(["phase": app.phase == .home ? "home" : "studio"])
            case "play", "resume":
                if app.stats.phase == .paused { app.togglePause() }
                return ok(["phase": app.stats.phase.rawValue])
            case "pause":
                if app.stats.phase != .paused { app.togglePause() }
                return ok(["phase": app.stats.phase.rawValue])
            case "toggle":
                app.togglePause()
                return ok(["phase": app.stats.phase.rawValue])
            case "step":
                if app.stats.phase == .finished || app.stats.phase == .stopped {
                    return ControlJSON.error("replay finished — use restart (or seek) first")
                }
                app.stepForward()
                return ok(["framesSent": app.stats.framesSent])
            case "seek":
                guard let target = request.double("t") ?? request.double("arg0") else {
                    return ControlJSON.error("seek needs t=<seconds>")
                }
                if app.stats.phase == .finished || app.stats.phase == .stopped {
                    // End of stream closes the socket, so a seek has to re-open the
                    // page first and apply the position to the fresh session.
                    app.restart()
                    for _ in 0..<100 where app.stats.phase != .playing {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                app.seek(to: target)
                return ok(["requested": target, "phase": app.stats.phase.rawValue])
            case "rate":
                guard let value = request.double("arg0") ?? request.double("rate"), value > 0 else {
                    return ControlJSON.error("rate needs a positive number")
                }
                app.setRate(value)
                return ok(["rate": app.settings.v.rate])
            case "loop":
                let want = request.flag("arg0") ?? request.flag("on") ?? !app.settings.v.loopPlayback
                app.settings.set { $0.loopPlayback = want }
                app.applyLiveSettings()
                return ok(["loop": want])
            case "wireframe":
                let want = request.flag("arg0") ?? request.flag("on")
                if let want { if want != app.settings.v.wireframe { app.toggleWireframe() } }
                else { app.toggleWireframe() }
                return ok(["wireframe": app.settings.v.wireframe])
            case "reset-view":
                app.resetView()
                return ok(["reset": true])
            case "reload":
                app.reloadPage()
                return ok(["reloading": true])
            case "restart":
                app.restart()
                return ok(["restarting": true])
            case "budget":
                return try budget(request, app)
            case "renderer":
                return try renderer(request, app)
            case "presentation":
                return try presentation(request, app)
            case "settings", "set":
                return try settings(request, app)
            case "recent":
                return ok(["recent": app.recentURLs.map { $0.path }])
            case "logs":
                let limit = max(1, min(500, request.int("n") ?? request.int("arg0") ?? 20))
                return ok(["logs": app.consoleEntries.suffix(limit).map { "\($0.level) \($0.text)" }])
            case "bench":
                let frames = max(1, min(200, request.int("arg0") ?? request.int("frames") ?? 10))
                let value = await app.evaluateJS(
                    "(window.__s3dv && window.__s3dv.benchmark) ? window.__s3dv.benchmark(\(frames)) : -1")
                guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else {
                    return ControlJSON.error("benchmark unavailable (product renderer required)")
                }
                return ok(["msPerFrame": ms, "frames": frames, "estimatedFPS": 1000.0 / ms])
            case "screenshot":
                guard let path = request.string("path") ?? request.string("arg0") else {
                    return ControlJSON.error("screenshot needs path=<png>")
                }
                let url = Self.expand(path)
                let saved = await app.captureSnapshot(to: url)
                return saved ? ok(["path": url.path]) : ControlJSON.error("screenshot failed")
            case "wait":
                return await wait(request, app)
            case "quit":
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    NSApp.terminate(nil)
                }
                return ok(["quitting": true])
            default:
                return ControlJSON.error("unknown command '\(command)' (try: help)")
            }
        } catch {
            return ControlJSON.error(error.localizedDescription)
        }
    }

    // MARK: - commands

    private func open(_ request: ControlRequest, _ app: AppState) async throws -> String {
        guard let raw = request.string("path") ?? request.string("file") ?? request.string("arg0") else {
            return ControlJSON.error("open needs path=<file.s3dv>")
        }
        let url = Self.expand(raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ControlJSON.error("no such file: \(url.path)")
        }
        await app.open(url)
        if let message = app.errorMessage {
            app.errorMessage = nil
            return ControlJSON.error(message)
        }
        return ok(statusPayload(app))
    }

    private func remote(_ request: ControlRequest, _ app: AppState) throws -> String {
        guard let raw = request.string("url") ?? request.string("arg0"),
              raw.hasPrefix("ws://") || raw.hasPrefix("wss://") else {
            return ControlJSON.error("remote needs url=ws://host:port")
        }
        app.settings.set { $0.remoteURL = raw; $0.sourceMode = .remote }
        app.connectRemote()
        return ok(["remote": raw])
    }

    private func budget(_ request: ControlRequest, _ app: AppState) throws -> String {
        guard let raw = (request.string("arg0") ?? request.string("mb"))?.lowercased() else {
            return ControlJSON.error("budget needs <MB> or off")
        }
        if raw == "off" || raw == "unlimited" || raw == "0" {
            app.settings.budgetMegabytesOverride = 0
            app.settings.set { $0.budget = .unlimited }
        } else {
            guard let megabytes = Int(raw), megabytes >= 128 else {
                return ControlJSON.error("budget must be >= 128 MB (or 'off')")
            }
            // Known presets stay persistent; anything else is a session override.
            if let preset = BudgetPreset.allCases.first(where: { $0.megabytes == megabytes && megabytes > 0 }) {
                app.settings.budgetMegabytesOverride = nil
                app.settings.set { $0.budget = preset }
            } else {
                app.settings.budgetMegabytesOverride = megabytes
            }
        }
        app.applyLiveSettings()
        return ok(["budgetMB": app.settings.budgetMegabytes])
    }

    private func renderer(_ request: ControlRequest, _ app: AppState) throws -> String {
        guard let raw = (request.string("arg0") ?? request.string("mode"))?.lowercased(),
              let mode = RendererMode(rawValue: raw) else {
            return ControlJSON.error("renderer needs product|parity")
        }
        app.settings.set { $0.renderer = mode }
        app.reloadPage()
        return ok(["renderer": mode.rawValue, "reloading": true])
    }

    /// Switches how received frames become visible ones. Live (no reload):
    /// the page flushes its queue when leaving frame-complete mode.
    private func presentation(_ request: ControlRequest, _ app: AppState) throws -> String {
        let raw = (request.string("arg0") ?? request.string("mode"))?.lowercased()
        if let raw {
            guard let mode = PresentationMode.allCases.first(where: { $0.rawValue.lowercased() == raw }) else {
                return ControlJSON.error("presentation needs framecomplete|immediate")
            }
            app.settings.set { $0.presentationMode = mode }
            app.applyLiveSettings()
        }
        return ok(["presentation": app.settings.v.presentationMode.rawValue,
                   "applyBudgetMs": app.settings.v.applyBudgetMs])
    }

    private func settings(_ request: ControlRequest, _ app: AppState) throws -> String {
        let subcommand = request.string("arg0")?.lowercased()
        let isSet = request.cmd == "set" || subcommand == "set" || request.string("key") != nil
        if isSet {
            // `set key value` → arg0/arg1, `settings set key value` → arg1/arg2.
            let offset = (request.cmd == "set" || request.string("key") != nil) ? 0 : 1
            guard let key = request.string("key") ?? request.string("arg\(offset)"),
                  let value = request.string("value") ?? request.string("arg\(offset + 1)") else {
                return ControlJSON.error("usage: settings set <key> <value>")
            }
            try Self.apply(key: key, value: value, to: app)
            app.applyLiveSettings()
            return ok(["key": key, "value": value, "settings": Self.snapshot(app)])
        }
        return ok(Self.snapshot(app))
    }

    private func wait(_ request: ControlRequest, _ app: AppState) async -> String {
        let timeout = max(1, min(900, request.int("timeout") ?? request.int("arg0") ?? 600))
        let deadline = Date().addingTimeInterval(Double(timeout))
        let start = app.stats.packetsSent
        while Date() < deadline {
            let phase = app.stats.phase
            if phase == .finished || phase == .stopped || phase == .failed { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let phase = app.stats.phase
        let finished = phase == .finished || phase == .stopped || phase == .failed
        return ok([
            "finished": finished,
            "phase": phase.rawValue,
            "packetsSent": app.stats.packetsSent,
            "framesSent": app.stats.framesSent,
            "advanced": app.stats.packetsSent - start,
            "timedOut": !finished,
        ])
    }

    // MARK: - payloads

    private func statusPayload(_ app: AppState) -> [String: Any] {
        var payload: [String: Any] = [
            "phase": app.stats.phase.rawValue,
            "pagePhase": app.phase == .home ? "home" : "studio",
            "pageReady": app.pageReady,
            "status": app.statusText,
            "packetsSent": app.stats.packetsSent,
            "packetCount": app.stats.packetCount,
            "framesSent": app.stats.framesSent,
            "bytesSent": app.stats.bytesSent,
            "time": app.stats.currentTime,
            "duration": app.stats.duration,
            "chunks": app.stats.residentChunks,
            "triangles": app.stats.residentTriangles,
            "evictions": app.stats.evictionsTotal,
            "rate": app.settings.v.rate,
            "loop": app.settings.v.loopPlayback,
            "renderer": app.settings.v.renderer.rawValue,
            "presentation": app.settings.v.presentationMode.rawValue,
            "applyBudgetMs": app.settings.v.applyBudgetMs,
            "budgetMB": app.settings.budgetMegabytes,
            "httpPort": Int(app.httpBoundPort),
            "wsPort": Int(app.wsBoundPort),
            "control": ControlPath.socketURL().path,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let document = app.document {
            payload["file"] = document.url.path
            payload["remote"] = document.isRemote
            payload["fileBytes"] = document.byteCount
            payload["mode"] = document.isRemote ? "remote" : "local"
        }
        if !app.stats.errorText.isEmpty { payload["error"] = app.stats.errorText }
        return payload
    }

    private func metricsPayload(_ app: AppState) async -> [String: Any] {
        var payload: [String: Any] = [:]
        if let text = await app.evaluateJS(ViewerBootScript.telemetryJS) as? String,
           let data = text.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in dict where !(value is NSNull) { payload[key] = value }
        }
        payload["fps"] = app.metrics.fps
        payload["frameMs"] = app.metrics.frameMs
        payload["drawCalls"] = app.metrics.drawCalls
        payload["arenaMB"] = app.metrics.arenaMegabytes
        payload["appFootprintMB"] = ProcessMemory.footprintMegabytes
        return payload
    }

    private func ok(_ payload: [String: Any]) -> String {
        var merged = payload
        merged["ok"] = true
        return ControlJSON.encode(merged)
    }

    // MARK: - settings

    static func snapshot(_ app: AppState) -> [String: Any] {
        let v = app.settings.v
        return [
            "sourceMode": v.sourceMode.rawValue,
            "remoteURL": v.remoteURL,
            "restoreLastSession": v.restoreLastSession,
            "rate": v.rate,
            "loop": v.loopPlayback,
            "startPaused": v.startPaused,
            "pacingCap": v.pacingCapSeconds,
            "loopGap": v.loopGapSeconds,
            "autoReconnect": v.autoReconnect,
            "reconnectAttempts": v.reconnectAttempts,
            "allowControl": v.allowControlChannel,
            "renderer": v.renderer.rawValue,
            "wireframe": v.wireframe,
            "grid": v.showGrid,
            "hud": v.showViewerHUD,
            "pixelRatio": v.pixelRatioCap,
            "textureQuality": v.textureQuality,
            "presentation": v.presentationMode.rawValue,
            "applyBudgetMs": v.applyBudgetMs,
            "budget": v.budget.rawValue,
            "budgetMB": app.settings.budgetMegabytes,
            "evictionPolicy": v.evictionPolicy.rawValue,
            "arenaVertices": v.arenaVertices,
            "reduceOnMemoryPressure": v.reduceOnMemoryPressure,
            "httpPort": v.httpPort,
            "wsPort": v.wsPort,
            "maxClients": v.maxClients,
            "deepVerify": v.deepVerifyOnOpen,
            "telemetryHz": v.telemetryHz,
        ]
    }

    /// One place that knows how a text value maps onto SettingsSnapshot.
    static func apply(key: String, value: String, to app: AppState) throws {
        let lowered = value.lowercased()
        func boolean() throws -> Bool {
            switch lowered {
            case "1", "on", "true", "yes", "y": return true
            case "0", "off", "false", "no", "n": return false
            default: throw S3DVError.invalid("\(key) expects on|off")
            }
        }
        func number() throws -> Double {
            guard let parsed = Double(value), parsed.isFinite else {
                throw S3DVError.invalid("\(key) expects a number")
            }
            return parsed
        }
        func integer() throws -> Int {
            guard let parsed = Int(value) else { throw S3DVError.invalid("\(key) expects an integer") }
            return parsed
        }

        switch key.lowercased() {
        case "rate": let v = try number(); app.settings.set { $0.rate = v }
        case "loop", "loopplayback": let v = try boolean(); app.settings.set { $0.loopPlayback = v }
        case "startpaused": let v = try boolean(); app.settings.set { $0.startPaused = v }
        case "pacingcap", "pacingcapseconds": let v = try number(); app.settings.set { $0.pacingCapSeconds = v }
        case "loopgap", "loopgapseconds": let v = try number(); app.settings.set { $0.loopGapSeconds = v }
        case "autoreconnect": let v = try boolean(); app.settings.set { $0.autoReconnect = v }
        case "reconnectattempts": let v = try integer(); app.settings.set { $0.reconnectAttempts = v }
        case "allowcontrol", "allowcontrolchannel": let v = try boolean(); app.settings.set { $0.allowControlChannel = v }
        case "wireframe": let v = try boolean(); app.settings.set { $0.wireframe = v }
        case "grid", "showgrid": let v = try boolean(); app.settings.set { $0.showGrid = v }
        case "hud", "showviewerhud": let v = try boolean(); app.settings.set { $0.showViewerHUD = v }
        case "pixelratio": let v = try number(); app.settings.set { $0.pixelRatioCap = v }
        case "texturequality": let v = try number(); app.settings.set { $0.textureQuality = v }
        case "arenavertices": let v = try integer(); app.settings.set { $0.arenaVertices = v }
        case "httpport": let v = try integer(); app.settings.set { $0.httpPort = v }
        case "wsport": let v = try integer(); app.settings.set { $0.wsPort = v }
        case "maxclients": let v = try integer(); app.settings.set { $0.maxClients = v }
        case "deepverify", "deepverifyonopen": let v = try boolean(); app.settings.set { $0.deepVerifyOnOpen = v }
        case "telemetryhz": let v = try number(); app.settings.set { $0.telemetryHz = v }
        case "restorelastsession": let v = try boolean(); app.settings.set { $0.restoreLastSession = v }
        case "reduceonmemorypressure": let v = try boolean(); app.settings.set { $0.reduceOnMemoryPressure = v }
        case "remoteurl", "remote":
            guard lowered.hasPrefix("ws://") || lowered.hasPrefix("wss://") else {
                throw S3DVError.invalid("remoteURL expects ws://host:port")
            }
            app.settings.set { $0.remoteURL = value }
        case "renderer":
            guard let mode = RendererMode(rawValue: lowered) else {
                throw S3DVError.invalid("renderer expects product|parity")
            }
            app.settings.set { $0.renderer = mode }
        case "presentation", "presentationmode":
            guard let mode = PresentationMode.allCases.first(where: { $0.rawValue.lowercased() == lowered }) else {
                throw S3DVError.invalid("presentation expects framecomplete|immediate")
            }
            app.settings.set { $0.presentationMode = mode }
        case "applybudgetms", "applybudget":
            let v = try integer()
            guard (1...50).contains(v) else { throw S3DVError.invalid("applyBudgetMs expects 1...50") }
            app.settings.set { $0.applyBudgetMs = v }
        case "evictionpolicy", "eviction":
            guard let policy = EvictionPolicy(rawValue: lowered) else {
                throw S3DVError.invalid("evictionPolicy expects spatial|lru")
            }
            app.settings.set { $0.evictionPolicy = policy }
        case "sourcemode":
            guard let mode = SourceMode(rawValue: lowered) else {
                throw S3DVError.invalid("sourceMode expects local|demo|remote")
            }
            app.settings.set { $0.sourceMode = mode }
        case "budget":
            if lowered == "off" || lowered == "unlimited" || lowered == "0" {
                app.settings.budgetMegabytesOverride = 0
                app.settings.set { $0.budget = .unlimited }
            } else if let preset = BudgetPreset(rawValue: lowered) {
                app.settings.budgetMegabytesOverride = nil
                app.settings.set { $0.budget = preset }
            } else {
                let megabytes = try integer()
                guard megabytes >= 128 else { throw S3DVError.invalid("budget expects >= 128 MB or off") }
                if let preset = BudgetPreset.allCases.first(where: { $0.megabytes == megabytes && megabytes > 0 }) {
                    app.settings.budgetMegabytesOverride = nil
                    app.settings.set { $0.budget = preset }
                } else {
                    app.settings.budgetMegabytesOverride = megabytes
                }
            }
        default:
            throw S3DVError.invalid("unknown setting '\(key)' (try: settings)")
        }
    }

    private static func expand(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: (expanded as NSString).standardizingPath)
    }
}
