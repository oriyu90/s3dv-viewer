import SwiftUI
import AppKit
import WebKit

// MARK: - studio

struct StudioView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = state.errorMessage { banner(error) }
            if state.recoveredFromCrash { recoveryBanner }
            HStack(spacing: 0) {
                stage
                if showInspector {
                    Divider().overlay(Palette.stroke)
                    InspectorView()
                        .frame(width: 302)
                        .transition(.move(edge: .trailing))
                }
            }
            TransportBar()
        }
        .background(Palette.background)
        .toolbar { toolbarContent }
        .animation(.easeInOut(duration: 0.18), value: showInspector)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.transparent.fill")
                .foregroundStyle(Palette.accentSoft)
            Text(state.document?.name ?? "S3DV viewer")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let doc = state.document {
                Text(doc.isRemote ? "REMOTE" : doc.sizeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Palette.surfaceRaised))
            }
            Spacer()
            if state.stats.renumbered {
                StatusPill(text: "予算モード（連番正規化）", tint: Palette.warning)
            }
            if state.stats.phase == .paused {
                StatusPill(text: "一時停止", tint: Palette.warning)
            } else if state.stats.phase == .finished {
                StatusPill(text: "完了", tint: Palette.positive)
            } else {
                StatusPill(text: state.stats.phase == .playing ? "再生中" : state.statusText)
            }
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("インスペクタの表示切替")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.surface)
    }

    private var stage: some View {
        ZStack {
            WebViewHost(webView: state.webView)
                .clipShape(RoundedRectangle(cornerRadius: 0))
            if !state.pageReady {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("ビューアを準備しています…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.9)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            Text(text).font(.system(size: 11.5)).lineLimit(2)
            Spacer()
            Button("閉じる") { state.errorMessage = nil }.buttonStyle(.link)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Palette.warning.opacity(0.12))
    }

    private var recoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Palette.warning)
            Text("描画プロセスが終了したため自動復帰しました。予算を下げると再発しにくくなります。")
                .font(.system(size: 11.5))
            Spacer()
            Button("設定") { AppActions.openSettings() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Palette.warning.opacity(0.12))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await state.openDemo() }
            } label: { Image(systemName: "play.rectangle") }
                .help("同梱デモを再生")

            Button {
                state.chooseAndOpen()
            } label: { Image(systemName: "folder") }
                .help("録画を開く (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.toggleWireframe()
            } label: {
                Image(systemName: settings.v.wireframe ? "square.grid.3x3.fill" : "square.grid.3x3")
            }
            .help("ワイヤーフレーム (⇧⌘W)")

            Button {
                state.resetView()
            } label: { Image(systemName: "viewfinder") }
                .help("視点をリセット (⇧⌘V)")

            Button {
                state.closeSession()
            } label: { Image(systemName: "xmark.circle") }
                .help("閉じる (⌘W)")
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}

// MARK: - transport

struct TransportBar: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var scrub: Double?

    private var duration: Double { max(state.stats.duration, state.document?.durationSeconds ?? 0) }
    private var position: Double { scrub ?? state.stats.currentTime }
    private var canScrub: Bool { duration > 0.01 }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.togglePause()
            } label: {
                Image(systemName: state.stats.phase == .paused ? "play.fill" : "pause.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .help("再生 / 一時停止 (Space)")

            Button { state.stepForward() } label: { Image(systemName: "forward.frame.fill") }
                .disabled(state.stats.phase != .paused)
                .help("1パケット進む (.)")

            Button { state.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("先頭から再生し直す (⌘R)")

            Text(timeLabel(position))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 58, alignment: .trailing)

            Slider(value: Binding(get: { position },
                                  set: { scrub = $0 }),
                   in: 0...max(duration, 0.01)) { editing in
                if !editing, let target = scrub {
                    state.seek(to: target)
                    scrub = nil
                }
            }
            .disabled(!canScrub)
            .help(canScrub ? "シーク" : "このストリームはシーク情報を持ちません")

            Text(timeLabel(duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 58, alignment: .leading)

            Menu {
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                    Button(rateLabel(value)) { state.setRate(value) }
                }
                Divider()
                Button("カスタム…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Text(rateLabel(settings.v.rate))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 64)

            Toggle(isOn: Binding(get: { settings.v.loopPlayback },
                                 set: { value in
                                     settings.set { $0.loopPlayback = value }
                                     state.applyLiveSettings()
                                 })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("ループ再生")

            Spacer()

            Text("\(state.stats.packetsSent)/\(state.stats.packetCount) pkt")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
            if state.stats.evictions > 0 {
                Text("\(String(localized: "退避")) \(state.stats.evictions)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.warning)
            }
            Text(String(format: "%.1f MB/s", state.stats.megabytesPerSecond))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.surface)
        .overlay(Rectangle().fill(Palette.stroke).frame(height: 1), alignment: .top)
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    private func rateLabel(_ value: Double) -> String {
        value >= 1 ? String(format: "%.0f×", value) : String(format: "%.2g×", value)
    }
}

// MARK: - inspector

struct InspectorView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                streamSection
                performanceSection
                budgetSection
                if let doc = state.document, !doc.metadata.isEmpty { metadataSection(doc) }
                consoleSection
            }
            .padding(14)
        }
        .background(Palette.surface)
    }

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "ストリーム")
            MetricRow(label: "パケット", value: "\(state.stats.packetCount)")
            MetricRow(label: "受信", value: formatInteger(state.metrics.packets))
            MetricRow(label: "チャンク", value: formatInteger(state.metrics.chunks))
            MetricRow(label: "三角形", value: formatInteger(state.metrics.triangles))
            MetricRow(label: "時間", value: String(format: "%.3f s", state.stats.currentTime))
            MetricRow(label: "転送", value: ByteCountFormatter.string(
                fromByteCount: Int64(state.stats.bytesSent), countStyle: .memory))
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "描画（ブラウザ側 proxy）")
            MetricRow(label: "fps", value: state.metrics.fps > 0
                      ? String(format: "%.0f", state.metrics.fps) : "—",
                      tint: state.metrics.fps > 30 ? Palette.positive : Palette.warning)
            MetricRow(label: "フレーム", value: state.metrics.frameMs > 0
                      ? String(format: "%.1f ms", state.metrics.frameMs) : "—")
            MetricRow(label: "ドローコール", value: formatInteger(state.metrics.drawCalls))
            MetricRow(label: "ジオメトリ", value: formatInteger(state.metrics.geometries))
            if state.metrics.presented > 0 || state.metrics.dropped > 0 || state.metrics.backlog > 0 {
                MetricRow(label: "提示 / 落としたフレーム",
                          value: "\(formatInteger(state.metrics.presented)) / \(formatInteger(state.metrics.dropped))")
                MetricRow(label: "未適用バックログ", value: formatInteger(state.metrics.backlog))
            }
        }
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "メモリ予算")
            if settings.hasBudget {
                let limit = Double(settings.budgetMegabytes)
                let used = state.metrics.arenaMegabytes > 0
                    ? state.metrics.arenaMegabytes : state.document?.residentMegabytes ?? 0
                ProgressView(value: min(1, used / max(limit, 1.0)))
                    .tint(used / max(limit, 1.0) > 0.9 ? Palette.critical : Palette.accent)
                MetricRow(label: "推定使用", value: String(format: "%.0f / %d MB", used, settings.budgetMegabytes))
            } else {
                Text("無制限（巨大ストリームでは描画プロセスが落ちる可能性があります）")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
            }
            MetricRow(label: "退避チャンク", value: "\(state.stats.evictions)")
            MetricRow(label: "保留（予算超過）", value: "\(state.stats.deferred)")
            MetricRow(label: "アプリ使用メモリ", value: String(format: "%.0f MB",
                                                          ProcessMemory.footprintMegabytes))
        }
    }

    private func metadataSection(_ doc: StreamDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "ソース")
            ForEach(doc.metadata.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 1) {
                    Text(key).font(.system(size: 9.5)).foregroundStyle(Palette.textSecondary)
                    Text(doc.metadata[key] ?? "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "コンソール")
                Spacer()
                Text("\(state.consoleEntries.count)").font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
            }
            if state.consoleEntries.isEmpty {
                Text("エラーなし").font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(state.consoleEntries.suffix(12)) { entry in
                    HStack(alignment: .top, spacing: 5) {
                        Text(entry.level)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(entry.level == "ERROR" ? Palette.critical : Palette.warning)
                        Text(entry.text)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func formatInteger(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: Int(value)), number: .decimal)
    }

    private func formatInteger(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
