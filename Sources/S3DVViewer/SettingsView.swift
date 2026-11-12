import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Every streaming knob in one place. Changes that cannot be applied to a live
/// session are marked as such and applied on the next open (or via 再読み込み).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared
    @State private var tab: Tab = .stream

    enum Tab: String, CaseIterable, Identifiable {
        case stream = "配信"
        case rendering = "描画"
        case memory = "メモリ"
        case network = "ネットワーク"
        case advanced = "詳細"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .stream: return "dot.radiowaves.left.and.right"
            case .rendering: return "cube"
            case .memory: return "memorychip"
            case .network: return "network"
            case .advanced: return "gearshape.2"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .stream: streamTab
                    case .rendering: renderingTab
                    case .memory: memoryTab
                    case .network: networkTab
                    case .advanced: advancedTab
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .background(Palette.background)
    }

    // MARK: - stream

    private var streamTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("ソース") {
                Picker("入力", selection: $settings.v.sourceMode) {
                    ForEach(SourceMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                if settings.v.isRemote {
                    HStack {
                        TextField("ws://host:port", text: $settings.v.remoteURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("接続") { state.connectRemote() }
                    }
                    Text("リモート時はネイティブ再生を行いません（タイムラインは無効）。")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                }
            }

            group("再生") {
                row("速度") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.v.rate, in: 0.05...16)
                            .frame(width: 190)
                        Text(String(format: "%.2f×", settings.v.rate))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("ループ再生", isOn: $settings.v.loopPlayback)
                Toggle("開始時に一時停止", isOn: $settings.v.startPaused)
                row("ループ間隔") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.loopGapSeconds, format: .number.precision(.fractionLength(2)))
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("秒").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    }
                }
            }

            group("ペーシング") {
                row("最大待機") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.pacingCapSeconds,
                                  format: .number.precision(.fractionLength(2)))
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("秒（1パケットあたり）").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    }
                }
                Text("録画のタイムスタンプ間隔が大きい場合の上限です。既定は2秒（サーバー実装と同一）。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
            }

            group("制御チャネル") {
                Toggle("ページからの pause / step / seek / speed を許可", isOn: $settings.v.allowControlChannel)
                Toggle("切断時に自動再接続", isOn: $settings.v.autoReconnect)
                row("再接続の試行回数") {
                    HStack(spacing: 6) {
                        Stepper(value: $settings.v.reconnectAttempts, in: 0...20) {
                            Text("\(settings.v.reconnectAttempts) \(String(localized: "回"))")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 44, alignment: .leading)
                        }
                        .disabled(!settings.v.autoReconnect)
                        Text("待機は 0.5 秒から倍々（最大 8 秒）")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    }
                }
            }

            if state.phase == .studio {
                Button("いまのセッションに適用") { state.applyLiveSettings() }
            }
        }
    }

    // MARK: - rendering

    private var renderingTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("レンダラ") {
                Picker("", selection: $settings.v.renderer) {
                    ForEach(RendererMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.v.renderer.detail)
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("切り替えは「再読み込み」で反映されます。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.warning)
                Button("再読み込み") { state.reloadPage() }
                    .disabled(state.phase != .studio)
            }

            group("フレーム提示") {
                Picker("", selection: $settings.v.presentationMode) {
                    ForEach(PresentationMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.v.presentationMode.detail)
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.v.presentationMode == .frameComplete {
                    row("適用予算") {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.v.applyBudgetMs, format: .number)
                                .frame(width: 56).textFieldStyle(.roundedBorder)
                            Text("ms / 描画tick").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Text("1回の描画で適用に使える時間。大きいほど進みが速く、フレームは減ります。"
                         + "小さくするとロード時間を取って滑らかに表示します（1–50）。")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            group("表示") {
                Toggle("ワイヤーフレームで開始", isOn: $settings.v.wireframe)
                Toggle("グリッド床を表示", isOn: $settings.v.showGrid)
                Toggle("ビュー内HUDを表示", isOn: $settings.v.showViewerHUD)
                row("解像度上限") {
                    Picker("", selection: $settings.v.pixelRatioCap) {
                        Text("1×").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×（Retina）").tag(2.0)
                    }
                    .labelsHidden().frame(width: 140)
                }
                row("テクスチャ品質") {
                    Picker("", selection: $settings.v.textureQuality) {
                        Text("100%").tag(1.0)
                        Text("75%").tag(0.75)
                        Text("50%").tag(0.5)
                    }
                    .labelsHidden().frame(width: 140)
                }
            }
        }
    }

    // MARK: - memory

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("常駐ジオメトリ予算") {
                Picker("", selection: $settings.v.budget) {
                    ForEach(BudgetPreset.allCases) { preset in Text(preset.label).tag(preset) }
                }
                .pickerStyle(.radioGroup)
                Text("ビューアが保持する頂点・インデックスの上限。超えると古い／外側のチャンクから退避します。"
                     + "東京の 1.27 GB ストリーム（2,100万三角形）は「標準」で収まります。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.v.budget == .unlimited {
                    Text("無制限はクラッシュの危険があります（描画プロセスの上限は約4GB）。")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.critical)
                }
            }

            group("退避ポリシー") {
                Picker("", selection: $settings.v.evictionPolicy) {
                    ForEach(EvictionPolicy.allCases) { policy in Text(policy.label).tag(policy) }
                }
                .pickerStyle(.radioGroup)
                Text("空間的 = 中心から外側へ削り、塊として読める形を残します。LRU = 古い順。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
            }

            group("バッチング") {
                row("1アリーナの頂点数") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.arenaVertices, format: .number)
                            .frame(width: 110).textFieldStyle(.roundedBorder)
                        Text("（大きいほどドローコール減・メモリ増）")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    }
                }
                Toggle("メモリ圧迫時に予算を自動縮小", isOn: $settings.v.reduceOnMemoryPressure)
            }

            group("現状") {
                MetricRow(label: "アプリ使用", value: String(format: "%.0f MB", ProcessMemory.footprintMegabytes))
                MetricRow(label: "ビューア推定", value: String(format: "%.0f MB", state.metrics.arenaMegabytes))
                MetricRow(label: "退避 / 保留", value: "\(state.stats.evictions) / \(state.stats.deferred)")
            }
        }
    }

    // MARK: - network

    private var networkTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("ループバックサーバー") {
                row("HTTPポート") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.httpPort, format: .number)
                            .frame(width: 80).textFieldStyle(.roundedBorder)
                        Text("0 = 自動").font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    }
                }
                row("WebSocketポート") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.wsPort, format: .number)
                            .frame(width: 80).textFieldStyle(.roundedBorder)
                        Text("0 = 自動").font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    }
                }
                row("同時クライアント") {
                    TextField("", value: $settings.v.maxClients, format: .number)
                        .frame(width: 80).textFieldStyle(.roundedBorder)
                }
                Text("待ち受けは常に 127.0.0.1 です（外部公開しません）。ポート変更は次回オープン時に反映されます。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("このセッション") {
                MetricRow(label: "状態", value: NSLocalizedString(state.statusText, comment: "Localized status text"))
                MetricRow(label: "制御", value: settings.v.allowControlChannel ? NSLocalizedString("有効", comment: "Enabled") : NSLocalizedString("無効", comment: "Disabled"))
            }
        }
    }

    // MARK: - advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("診断") {
                Toggle("開くときに全レコードをCRC検証（大きいファイルは遅い）", isOn: $settings.v.deepVerifyOnOpen)
                Toggle("起動時に前回のファイルを復元", isOn: $settings.v.restoreLastSession)
                row("テレメトリ更新") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.v.telemetryHz,
                                  format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("Hz").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    }
                }
                HStack(spacing: 14) {
                    Button("ログを開く") { state.openLogFolder() }
                    Button("設定を初期化") {
                        settings.resetToDefaults()
                        state.applyLiveSettings()
                    }
                }
            }

            group("環境") {
                MetricRow(label: "バージョン", value: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                MetricRow(label: "描画プロセス復帰", value: state.recoveredFromCrash ? "あり" : "なし")
                MetricRow(label: "ファイル", value: state.document?.name ?? "—", mono: false)
            }

            group("研究用") {
                Text("このアプリは S3DV 研究キットのビューアです。パリティ描画は web/main.js をバイト一致で実行します。"
                     + " 東京の3Dデータは Project PLATEAU（CC BY 4.0 互換）に由来します。")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - chrome

    private var footer: some View {
        HStack(spacing: 10) {
            if let diagnostic = settings.loadDiagnostic {
                Label(diagnostic, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(Palette.warning).lineLimit(1)
            }
            Spacer()
            Button("閉じる") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Palette.surface)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: title)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Palette.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
