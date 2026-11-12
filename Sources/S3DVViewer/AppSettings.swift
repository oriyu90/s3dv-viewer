// Persisted, user-facing configuration. Every streaming knob in the app lives
// here and is editable from Settings (⌘,) — the file is the single source of
// truth for both the native replay engine and the injected viewer page.
//
// Corruption safety: the snapshot is decoded from JSON with per-field clamping
// and a schema version. A malformed or older blob is migrated field by field
// onto the defaults instead of throwing the user's settings away, and a blob
// that cannot be decoded at all is archived next to the log for diagnosis.
import Foundation
import AppKit
import Combine

// MARK: - enums

enum RendererMode: String, Codable, CaseIterable, Identifiable {
    /// Batched renderer owned by this app: one draw call per arena, chunk budget.
    case product
    /// Byte-identical research renderer (`web/main.js`, pinned by sync_web.sh).
    case parity
    var id: String { rawValue }
    var label: String {
        switch self {
        case .product: return "Standard (batched)"
        case .parity: return "Research parity (unbatched)"
        }
    }
    var detail: String {
        switch self {
        case .product:
            return "1ドローコール/アリーナで大量チャンクを描画。巨大モデル向け（既定）。"
        case .parity:
            return "キット同梱の main.js をバイト一致で実行。研究再現用。"
        }
    }
}

enum SourceMode: String, Codable, CaseIterable, Identifiable {
    /// Local .s3dv recording streamed through the embedded loopback servers.
    case local
    /// Bundled demo recording.
    case demo
    /// Remote `s3dv serve` instance (the page connects straight to it).
    case remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "ローカル録画 (.s3dv)"
        case .demo: return "同梱デモ"
        case .remote: return "リモート s3dv serve"
        }
    }
}

enum EvictionPolicy: String, Codable, CaseIterable, Identifiable {
    /// Keep a solid core: evict the chunks farthest from the stream centre.
    case spatial
    /// Evict the chunks that have been resident the longest.
    case lru
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spatial: return "空間的（中心から外側へ）"
        case .lru: return "LRU（古い順）"
        }
    }
}

enum BudgetPreset: String, Codable, CaseIterable, Identifiable {
    case lean, balanced, generous, unlimited
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lean: return "軽量 (1.0 GB)"
        case .balanced: return "標準 (2.0 GB)"
        case .generous: return "高品質 (4.0 GB)"
        case .unlimited: return "無制限（危険）"
        }
    }
    var megabytes: Int {
        switch self {
        case .lean: return 1_024
        case .balanced: return 2_048
        case .generous: return 4_096
        case .unlimited: return 0
        }
    }
}

/// How received packets become visible frames.
enum PresentationMode: String, Codable, CaseIterable, Identifiable {
    /// Packets queue and are applied inside the render tick, so every presented
    /// frame is the complete scene state at a packet boundary. Heavy loads
    /// extend the apply time and fold intermediate frames instead of tearing.
    case frameComplete
    /// Research-kit behaviour: apply on arrival, render whatever exists at
    /// rAF time (kept for A/B comparison and debugging).
    case immediate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frameComplete: return "フレーム完全（既定）"
        case .immediate: return "即時（従来動作）"
        }
    }
    var detail: String {
        switch self {
        case .frameComplete:
            return "受信フレームを描画tick内で完全適用してから提示します。負荷時は中間フレームを落として、必ず完全な状態だけを表示します。"
        case .immediate:
            return "受信したフレームを即座に適用し、rAFのタイミングで描画します（研究キットと同じ動作）。"
        }
    }
}

// MARK: - snapshot

struct SettingsSnapshot: Codable, Equatable {
    static let schemaVersion = 1
    var schema = SettingsSnapshot.schemaVersion

    // Source
    var sourceMode: SourceMode = .local
    var remoteURL: String = "ws://127.0.0.1:8765"
    var restoreLastSession = true

    // Playback / streaming
    var rate: Double = 1.0
    var loopPlayback = false
    var startPaused = false
    var pacingCapSeconds: Double = 2.0
    var loopGapSeconds: Double = 0.75
    var autoReconnect = true
    var reconnectAttempts = 3
    var allowControlChannel = true

    // Rendering
    var renderer: RendererMode = .product
    var wireframe = false
    var showGrid = true
    var pixelRatioCap: Double = 2.0
    var showViewerHUD = true
    var textureQuality = 1.0
    // Frame-complete presentation (see PresentationMode) and the per-tick
    // budget the page may spend applying queued packets before presenting.
    var presentationMode: PresentationMode = .frameComplete
    var applyBudgetMs: Int = 6

    // Memory
    var budget: BudgetPreset = .balanced
    var evictionPolicy: EvictionPolicy = .spatial
    var arenaVertices: Int = 4_000_000
    var reduceOnMemoryPressure = true

    // Network
    var httpPort: Int = 0        // 0 = ephemeral
    var wsPort: Int = 0          // 0 = ephemeral
    var maxClients = 1

    // Advanced / diagnostics
    var deepVerifyOnOpen = false
    var telemetryHz: Double = 4

    // MARK: clamping

    /// Coerces every field into a range the engine can actually honour. Applied
    /// after decoding so a hand-edited or bit-rotted file still boots.
    mutating func clamp() {
        schema = SettingsSnapshot.schemaVersion
        if !remoteURL.hasPrefix("ws://") && !remoteURL.hasPrefix("wss://") {
            remoteURL = "ws://127.0.0.1:8765"
        }
        if !(remoteURL.count > 7 && remoteURL.count < 2048) { remoteURL = "ws://127.0.0.1:8765" }
        rate = min(max(rate.isFinite ? rate : 1, 0.05), 64)
        pacingCapSeconds = min(max(pacingCapSeconds.isFinite ? pacingCapSeconds : 2, 0.05), 60)
        loopGapSeconds = min(max(loopGapSeconds.isFinite ? loopGapSeconds : 0.75, 0), 30)
        reconnectAttempts = min(max(reconnectAttempts, 0), 20)
        pixelRatioCap = min(max(pixelRatioCap.isFinite ? pixelRatioCap : 2, 0.5), 3)
        textureQuality = min(max(textureQuality.isFinite ? textureQuality : 1, 0.25), 1)
        arenaVertices = min(max(arenaVertices, 500_000), 16_000_000)
        httpPort = (1...65_535).contains(httpPort) ? httpPort : 0
        wsPort = (1...65_535).contains(wsPort) ? wsPort : 0
        maxClients = min(max(maxClients, 1), 8)
        telemetryHz = min(max(telemetryHz.isFinite ? telemetryHz : 4, 0.5), 30)
        applyBudgetMs = min(max(applyBudgetMs, 1), 50)
    }

    /// True when the source needs a remote endpoint.
    var isRemote: Bool { sourceMode == .remote }

    // MARK: tolerant decoding
    //
    // Synthesized Decodable throws when a stored key is missing, so growing
    // this struct would make every previously saved settings blob fail to
    // decode and silently reset the user's preferences. Every key is read with
    // decodeIfPresent and falls back to the memberwise default instead; unknown
    // extra keys are ignored and every field is re-clamped afterwards.

    private enum Keys: String, CodingKey {
        case schema, sourceMode, remoteURL, restoreLastSession, rate
        case loopPlayback, startPaused, pacingCapSeconds, loopGapSeconds
        case autoReconnect, reconnectAttempts, allowControlChannel
        case renderer, wireframe, showGrid, pixelRatioCap, showViewerHUD
        case textureQuality, presentationMode, applyBudgetMs
        case budget, evictionPolicy, arenaVertices, reduceOnMemoryPressure
        case httpPort, wsPort, maxClients, deepVerifyOnOpen, telemetryHz
    }

    init() {}

    /// Reads a string-raw-value enum tolerantly: a missing or unknown raw value
    /// yields nil so the caller can keep the memberwise default.
    private static func decodeEnum<E: RawRepresentable & Decodable>(
        _ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> E? where E.RawValue == String {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return E(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? SettingsSnapshot.schemaVersion
        sourceMode = Self.decodeEnum(c, .sourceMode) ?? .local
        remoteURL = (try? c.decodeIfPresent(String.self, forKey: .remoteURL)) ?? "ws://127.0.0.1:8765"
        restoreLastSession = (try? c.decodeIfPresent(Bool.self, forKey: .restoreLastSession)) ?? true
        rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? 1.0
        loopPlayback = (try? c.decodeIfPresent(Bool.self, forKey: .loopPlayback)) ?? false
        startPaused = (try? c.decodeIfPresent(Bool.self, forKey: .startPaused)) ?? false
        pacingCapSeconds = (try? c.decodeIfPresent(Double.self, forKey: .pacingCapSeconds)) ?? 2.0
        loopGapSeconds = (try? c.decodeIfPresent(Double.self, forKey: .loopGapSeconds)) ?? 0.75
        autoReconnect = (try? c.decodeIfPresent(Bool.self, forKey: .autoReconnect)) ?? true
        reconnectAttempts = (try? c.decodeIfPresent(Int.self, forKey: .reconnectAttempts)) ?? 3
        allowControlChannel = (try? c.decodeIfPresent(Bool.self, forKey: .allowControlChannel)) ?? true
        renderer = Self.decodeEnum(c, .renderer) ?? .product
        wireframe = (try? c.decodeIfPresent(Bool.self, forKey: .wireframe)) ?? false
        showGrid = (try? c.decodeIfPresent(Bool.self, forKey: .showGrid)) ?? true
        pixelRatioCap = (try? c.decodeIfPresent(Double.self, forKey: .pixelRatioCap)) ?? 2.0
        showViewerHUD = (try? c.decodeIfPresent(Bool.self, forKey: .showViewerHUD)) ?? true
        textureQuality = (try? c.decodeIfPresent(Double.self, forKey: .textureQuality)) ?? 1.0
        presentationMode = Self.decodeEnum(c, .presentationMode) ?? .frameComplete
        applyBudgetMs = (try? c.decodeIfPresent(Int.self, forKey: .applyBudgetMs)) ?? 6
        budget = Self.decodeEnum(c, .budget) ?? .balanced
        evictionPolicy = Self.decodeEnum(c, .evictionPolicy) ?? .spatial
        arenaVertices = (try? c.decodeIfPresent(Int.self, forKey: .arenaVertices)) ?? 4_000_000
        reduceOnMemoryPressure = (try? c.decodeIfPresent(Bool.self, forKey: .reduceOnMemoryPressure)) ?? true
        httpPort = (try? c.decodeIfPresent(Int.self, forKey: .httpPort)) ?? 0
        wsPort = (try? c.decodeIfPresent(Int.self, forKey: .wsPort)) ?? 0
        maxClients = (try? c.decodeIfPresent(Int.self, forKey: .maxClients)) ?? 1
        deepVerifyOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .deepVerifyOnOpen)) ?? false
        telemetryHz = (try? c.decodeIfPresent(Double.self, forKey: .telemetryHz)) ?? 4
    }
}

// MARK: - store

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Bumped when the store layout changes; unknown/older blobs are migrated.
    private static let storageKey = "settings.v1"
    private let defaults: UserDefaults
    private var saveWork: DispatchWorkItem?
    /// Set when the stored blob had to be replaced wholesale (surfaced in the UI
    /// once, so a user whose settings vanished knows why).
    private(set) var loadDiagnostic: String?

    /// Automation overrides (autotest) change the session without touching the
    /// user's saved preferences.
    private var suppressSave = false
    private var transientBaseline: SettingsSnapshot?

    @Published var v: SettingsSnapshot {
        didSet { if v != oldValue, !suppressSave { scheduleSave() } }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        v = Self.load(from: defaults, diagnostic: { _ in })
        if let data = defaults.data(forKey: Self.storageKey),
           (try? JSONDecoder().decode(SettingsSnapshot.self, from: data)) == nil {
            loadDiagnostic = "settings could not be decoded; defaults restored (previous blob archived)"
        }
        // One-time migration of the pre-1.0 single "rate" preference.
        if let legacyRate = defaults.object(forKey: "rate") as? Double, legacyRate > 0 {
            if defaults.data(forKey: Self.storageKey) == nil {
                v.rate = min(max(legacyRate, 0.05), 64)
            }
            defaults.removeObject(forKey: "rate")
        }
    }

    private static func load(from defaults: UserDefaults,
                             diagnostic: (String) -> Void) -> SettingsSnapshot {
        guard let data = defaults.data(forKey: storageKey) else { return SettingsSnapshot() }
        let decoder = JSONDecoder()
        guard var decoded = try? decoder.decode(SettingsSnapshot.self, from: data) else {
            Self.archiveCorrupt(data)
            diagnostic("decode failed")
            return SettingsSnapshot()
        }
        if decoded.schema != SettingsSnapshot.schemaVersion {
            // Forward migration point: every field has a default, so decoding a
            // newer blob with unknown keys keeps what it understands.
            decoded.schema = SettingsSnapshot.schemaVersion
        }
        decoded.clamp()
        return decoded
    }

    private static func archiveCorrupt(_ data: Data) {
        let dir = AppPaths.logsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? data.write(to: dir.appendingPathComponent("settings-corrupt-\(stamp).json"))
    }

    // MARK: convenience

    /// Test/automation override (never persisted).
    var budgetMegabytesOverride: Int?
    var budgetMegabytes: Int { budgetMegabytesOverride ?? v.budget.megabytes }
    var hasBudget: Bool { budgetMegabytes > 0 }

    func resetToDefaults() {
        v = SettingsSnapshot()
        defaults.removeObject(forKey: Self.storageKey)
        scheduleSave()
    }

    /// Applies a value for this launch only (autotest renderer/rate/budget).
    /// The pre-override snapshot is kept so `flush()` at quit cannot smuggle an
    /// automation setting into the user's preferences.
    func setTransient(_ mutate: (inout SettingsSnapshot) -> Void) {
        if transientBaseline == nil { transientBaseline = v }
        suppressSave = true
        defer { suppressSave = false }
        var copy = v
        mutate(&copy)
        copy.clamp()
        v = copy
    }

    func set(_ mutate: (inout SettingsSnapshot) -> Void) {
        var copy = v
        mutate(&copy)
        copy.clamp()
        v = copy
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = v
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                self.defaults.set(data, forKey: Self.storageKey)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Flush synchronously (called on terminate).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        if let data = try? JSONEncoder().encode(transientBaseline ?? v) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - app paths

enum AppPaths {
    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Logs/S3DV viewer", isDirectory: true)
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("S3DV viewer", isDirectory: true)
    }
}
