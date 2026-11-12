import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AppActions {
    /// The Settings scene answers to `showSettingsWindow:` on macOS 14+ and to
    /// `showPreferencesWindow:` on 13 — try both so ⌘, never dead-ends.
    static func openSettings() {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

// Shared visual language: one dark surface stack, one accent, monospaced digits.
enum Palette {
    static let background = Color(red: 0.047, green: 0.067, blue: 0.098)
    static let surface = Color(red: 0.071, green: 0.094, blue: 0.133)
    static let surfaceRaised = Color(red: 0.098, green: 0.125, blue: 0.176)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.365, green: 0.616, blue: 0.976)
    static let accentSoft = Color(red: 0.49, green: 0.827, blue: 0.988)
    static let positive = Color(red: 0.36, green: 0.82, blue: 0.6)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.35)
    static let critical = Color(red: 0.97, green: 0.44, blue: 0.42)
    static let textSecondary = Color.white.opacity(0.62)
}

/// Card container used by the landing screen and inspector sections.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.textSecondary)
    }
}

/// Metric row: label on the left, monospaced value on the right.
struct MetricRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var mono = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

struct StatusPill: View {
    let text: String
    var tint: Color = Palette.accent

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.8))
    }
}

// MARK: - root

struct RootView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        Group {
            switch state.phase {
            case .home: HomeView()
            case .studio: StudioView()
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onOpenURL { url in Task { await state.open(url) } }
        .alert("S3DV viewer", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
            Button("ログを表示") { state.openLogFolder() }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

// MARK: - home

struct HomeView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragActive = false
    @State private var remoteField = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    HStack(alignment: .top, spacing: 18) {
                        dropZone
                        VStack(spacing: 18) {
                            quickActions
                            remoteCard
                        }
                    }
                    if !state.recentURLs.isEmpty { recentCard }
                    limitsCard
                }
                .padding(28)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .onAppear { remoteField = settings.v.remoteURL }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.accentSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text("S3DV viewer")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("時系列3Dストリーム（.s3dv）をローカルで再生・検証するビューア")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if state.isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dragActive ? Palette.accent.opacity(0.16) : Palette.surfaceRaised)
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Palette.accentSoft)
                    Text(".s3dv をドロップ")
                        .font(.system(size: 15, weight: .medium))
                    Text("録画ファイルはメモリマップされ、必要なパケットだけを読みます")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(18)
            }
            .frame(height: 216)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [7, 5]))
                .foregroundStyle(dragActive ? Palette.accent : Color.white.opacity(0.22)))
            .onDrop(of: [.fileURL], isTargeted: $dragActive) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await state.open(url) }
                }
                return true
            }

            HStack(spacing: 10) {
                Button {
                    state.chooseAndOpen()
                } label: {
                    Label("録画を開く…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("o")

                Button {
                    Task { await state.openDemo() }
                } label: {
                    Label("デモ", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    private var quickActions: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "いまの設定")
                MetricRow(label: "描画", value: settings.v.renderer.label)
                MetricRow(label: "メモリ予算", value: settings.hasBudget
                          ? "\(settings.budgetMegabytes) MB" : "無制限",
                          tint: settings.hasBudget ? .primary : Palette.warning)
                MetricRow(label: "再生速度", value: String(format: "%.2f×", settings.v.rate))
                MetricRow(label: "ループ", value: settings.v.loopPlayback ? "有効" : "無効")
                Divider().opacity(0.3)
                Button {
                    AppActions.openSettings()
                } label: {
                    Label("設定を開く (⌘,)", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var remoteCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "リモートストリーム")
                Text("`s3dv serve` が立てたWebSocketへ直接接続します。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                HStack(spacing: 8) {
                    TextField("ws://127.0.0.1:8765", text: $remoteField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("接続") {
                        settings.set { $0.remoteURL = remoteField; $0.sourceMode = .remote }
                        state.connectRemote()
                    }
                    .disabled(!remoteField.hasPrefix("ws"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "最近開いたファイル")
                ForEach(state.recentURLs, id: \.self) { url in
                    Button {
                        Task { await state.open(url) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill").foregroundStyle(Palette.textSecondary)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(shortPath(url))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var limitsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "このアプリについて")
                Text("研究用キットです。東京の3Dデータは Project PLATEAU（CC BY 4.0 互換）に由来します。"
                     + " 描画は three.js r180 を同梱してオフラインで動作します。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("ログフォルダ") { state.openLogFolder() }.buttonStyle(.link)
                    Button("設定") { AppActions.openSettings() }
                        .buttonStyle(.link)
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.positive).frame(width: 6, height: 6)
            Text(state.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if state.recoveredFromCrash {
                Text("前回の描画プロセス異常終了から復帰済み")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.warning)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(Palette.surface)
        .overlay(Rectangle().fill(Palette.stroke).frame(height: 1), alignment: .top)
    }

    private func shortPath(_ url: URL) -> String {
        let parts = url.pathComponents
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : url.deletingLastPathComponent().lastPathComponent
    }
}
