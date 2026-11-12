import SwiftUI
import AppKit

@main
struct S3DVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("S3DV viewer") {
            RootView()
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { ViewerCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Direct executable launches (autotest, `open -a ... file`) start here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Direct-exec launches do not activate the app; without activation WebKit
        // marks the page hidden and pauses requestAnimationFrame, freezing the
        // replay. Bring the window up front in every case.
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }

        let state = AppState.shared
        if let autotest = state.autotest {
            if let rate = autotest.rate { state.settings.setTransient { $0.rate = rate } }
            if let renderer = autotest.rendererOverride {
                state.settings.setTransient { $0.renderer = renderer }
            }
            if let budget = autotest.budgetOverride {
                state.settings.budgetMegabytesOverride = budget
            }
            if let file = ProcessInfo.processInfo.arguments.first(where: { $0.hasSuffix(".s3dv") }) {
                Task { await state.open(URL(fileURLWithPath: file)) }
            }
            return
        }

        // A path on the command line wins over the restored session.
        if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasSuffix(".s3dv") }) {
            Task { await state.open(URL(fileURLWithPath: path)) }
            return
        }

        if state.settings.v.restoreLastSession,
           let last = state.recentURLs.first,
           FileManager.default.fileExists(atPath: last.path) {
            Task { await state.open(last) }
        }
    }

    func application(_ application: NSApplication, openFiles urls: [String]) {
        guard let first = urls.first else { return }
        Task { await AppState.shared.open(URL(fileURLWithPath: first, isDirectory: false)) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { await AppState.shared.open(URL(fileURLWithPath: filename, isDirectory: false)) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
        CrashGuard.shared.log("clean exit")
        CrashGuard.shared.markCleanExit()
        let code = AutotestController.pendingExitCode
        if code != 0 { exit(code) }
    }
}

// MARK: - menus

struct ViewerCommands: Commands {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("録画を開く…") { state.chooseAndOpen() }
                .keyboardShortcut("o")
            Button("同梱デモを再生") { Task { await state.openDemo() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("再読み込み") { state.restart() }
                .keyboardShortcut("r")
                .disabled(state.phase != .studio)
            Button("閉じる") { state.closeSession() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(state.phase != .studio)
        }

        CommandGroup(replacing: .appInfo) {
            Button("S3DV viewer について") { showAbout() }
        }

        CommandMenu("再生") {
            Button(state.stats.phase == .paused ? "再生" : "一時停止") { state.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(state.phase != .studio)
            Button("1パケット進む") { state.stepForward() }
                .keyboardShortcut(".", modifiers: [])
                .disabled(state.stats.phase != .paused)
            Divider()
            Menu("速度") {
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                    Button(value >= 1 ? "\(Int(value))×" : "\(value)×") { state.setRate(value) }
                }
            }
            Toggle("ループ再生", isOn: Binding(
                get: { settings.v.loopPlayback },
                set: { value in
                    settings.set { $0.loopPlayback = value }
                    state.applyLiveSettings()
                }))
        }

        CommandMenu("表示") {
            Button("ワイヤーフレーム") { state.toggleWireframe() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("視点をリセット") { state.resetView() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("ログフォルダを開く") { state.openLogFolder() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: """
            S3DV viewer — 時系列3Dストリームの再生・検証用ビューア

            東京の3Dデータ: Project PLATEAU（東京都デジタルツイン基盤）
            CC BY 4.0 互換。原典: https://www.mlit.go.jp/plateau/
            描画: three.js r180 (MIT)
            研究キット: S3DV (S3DP wire protocol)
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "S3DV viewer",
        ])
    }
}
