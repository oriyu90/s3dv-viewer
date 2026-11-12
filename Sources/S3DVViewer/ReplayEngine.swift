// Native replay engine: turns a lazily-mapped .s3dv recording into the S3DP
// binary stream the embedded viewer consumes over loopback WebSocket.
//
// Responsibilities
//  * pacing  — mirrors src/s3dv/server.py: delay = min(cap, (ts-prev)/1e9/rate)
//  * control — pause / resume / step / seek / speed from JSON text frames
//  * budget  — bounds the viewer's resident geometry so a 1.27 GB / 21 M-triangle
//              city stream cannot exhaust the WebContent process. When the budget
//              forces an eviction or a skip it switches the session to
//              sequence-normalised mode (continuously increasing sequence
//              numbers) because the protocol requires contiguity.
//  * teardown — cancels cleanly, never leaves a send in flight, and drains the
//              socket before the close frame so the peer receives every packet.
import Foundation
import Network
import S3DVCore

// MARK: - public types

enum ReplayPhase: String, Sendable {
    case idle, playing, paused, seeking, finished, failed, stopped
}

struct ReplayStats: Sendable, Equatable {
    var phase: ReplayPhase = .idle
    var packetIndex = 0
    var packetCount = 0
    var packetsSent = 0
    /// Frames actually put on the wire, including synthesised CHUNK_REMOVE
    /// evictions — the number the viewer's own counter must match.
    var framesSent = 0
    var bytesSent = 0
    var residentChunks = 0
    var residentTriangles = 0
    var residentBytes = 0
    var evictions = 0
    /// Evictions across the whole session (governor.evictions resets per snapshot).
    var evictionsTotal = 0
    var deferred = 0
    var renumbered = false
    var currentTime: Double = 0
    var duration: Double = 0
    var packetsPerSecond: Double = 0
    var megabytesPerSecond: Double = 0
    var errorText: String = ""
    /// Control frames accepted from the page (pause/resume/step/seek/speed).
    var controlCommands = 0
    var seeks = 0

    static let zero = ReplayStats()
}

struct ReplayOptions: Sendable {
    var rate: Double = 1
    var pacingCap: Double = 2
    var loop = false
    var loopGap: Double = 0.75
    var startPaused = false
    var allowControl = true
    /// 0 disables the budget (unbounded residency).
    var budgetBytes: Int = 0
    var evictionPolicy: EvictionPolicy = .spatial
    var arenaVertices: Int = 4_000_000
}

enum ReplayCommand: Sendable {
    case pause, resume, step
    case seek(Double)
    case speed(Double)
}

// MARK: - budget governor

/// Tracks what the viewer currently holds and decides what to evict.
/// Costs come from the mesh payload header only — no geometry is decoded.
private struct BudgetGovernor {
    struct Entry {
        var revision: UInt32
        var bytes: Int
        var triangles: Int
        var lastUsed: UInt64
    }

    private(set) var limit: Int
    private(set) var policy: EvictionPolicy
    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var residentBytes = 0
    private(set) var residentTriangles = 0
    private(set) var evictions = 0
    private var clock: UInt64 = 0

    var active: Bool { limit > 0 }
    var chunks: Int { entries.count }

    init(limit: Int, policy: EvictionPolicy) {
        self.limit = limit
        self.policy = policy
        entries.reserveCapacity(limit > 0 ? min(12_000, max(256, limit / 96_000)) : 512)
    }

    /// Live budget change (settings window / memory pressure). Existing entries
    /// stay until the next admission trims them, so playback never stalls.
    mutating func setLimit(_ newLimit: Int) {
        if newLimit != limit { limit = newLimit }
    }

    mutating func setPolicy(_ newPolicy: EvictionPolicy) {
        if newPolicy != policy { policy = newPolicy }
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        residentBytes = 0
        residentTriangles = 0
        evictions = 0
        clock = 0
    }

    /// Registers (or replaces) a chunk. Returns the ids to remove before the new
    /// chunk may be sent, plus whether the new chunk itself should be dropped.
    mutating func admit(chunk: UInt64, revision: UInt32, bytes: Int, triangles: Int)
        -> (evict: [(id: UInt64, revision: UInt32)], skip: Bool) {
        clock &+= 1
        guard active else {
            entries[chunk] = Entry(revision: revision, bytes: bytes,
                                   triangles: triangles, lastUsed: clock)
            residentBytes += bytes
            residentTriangles += triangles
            return ([], false)
        }
        if let old = entries[chunk] {
            residentBytes -= old.bytes
            residentTriangles -= old.triangles
            entries[chunk] = nil
        }
        // A single chunk larger than the whole budget can never fit: skip it.
        if bytes > limit {
            return ([], true)
        }
        // Evict only under real pressure. Admission must never drop chunks while
        // the budget has room — an earlier revision also rejected "farther than
        // everything resident" chunks unconditionally, which silently discarded
        // the outer shell of a 244 MB stream that used 12 % of its budget.
        // The victim's revision must be captured while the entry still exists:
        // reading it after removal produced revision 1, which the viewer rejects
        // as stale, so evictions silently did nothing.
        var victims: [(id: UInt64, revision: UInt32)] = []
        while residentBytes + bytes > limit, let victim = pickVictim() {
            if let victimEntry = entries.removeValue(forKey: victim) {
                residentBytes -= victimEntry.bytes
                residentTriangles -= victimEntry.triangles
                victims.append((victim, victimEntry.revision))
            } else {
                break
            }
        }
        if residentBytes + bytes > limit {
            return (victims, true)
        }
        entries[chunk] = Entry(revision: revision, bytes: bytes,
                               triangles: triangles, lastUsed: clock)
        residentBytes += bytes
        residentTriangles += triangles
        evictions += victims.count
        return (victims, false)
    }

    mutating func remove(chunk: UInt64) {
        if let e = entries.removeValue(forKey: chunk) {
            residentBytes -= e.bytes
            residentTriangles -= e.triangles
        }
    }

    private func pickVictim() -> UInt64? {
        switch policy {
        case .lru:
            return entries.min { $0.value.lastUsed < $1.value.lastUsed }?.key
        case .spatial:
            return entries.max {
                (ChunkGrid.shellDistance(of: $0.key) ?? Int.max)
                    < (ChunkGrid.shellDistance(of: $1.key) ?? Int.max)
            }?.key
        }
    }
}

// MARK: - session

/// One live replay over one WebSocket connection. Main-actor isolated: every
/// mutation happens on the main thread, and the pacing sleeps yield so the UI
/// stays responsive. A 1.27 GB recording costs a few hundred kilobytes of
/// resident memory here (the recording itself stays mapped on disk).
@MainActor
final class ReplaySession {
    private let recording: S3DVRecording
    private let connection: ReplayConnection
    private let options: ReplayOptions

    private(set) var stats = ReplayStats.zero
    var onStats: ((ReplayStats) -> Void)?

    private var paused = false
    private var stepQueued = false
    private var seekQueue: [Double] = []
    private var rate: Double
    private var stopRequested = false
    private var loopRequested: Bool
    private var task: Task<Void, Never>?
    /// The in-flight pacing sleep, cancelled when a control command arrives so
    /// pause/seek react immediately instead of after the current delay.
    private var pacingTask: Task<Void, Never>?
    private var governor: BudgetGovernor

    private var lastRateSample = DispatchTime.now()
    private var rateSamplePackets = 0
    private var rateSampleBytes = 0

    /// Drives both the pacing wait and the pause wait; 20 ms keeps seek latency
    /// imperceptible without a continuation/lock dance.
    private static let tick: UInt64 = 20_000_000

    init(recording: S3DVRecording, connection: ReplayConnection, options: ReplayOptions) {
        self.recording = recording
        self.connection = connection
        self.options = options
        self.rate = options.rate
        self.paused = options.startPaused
        self.loopRequested = options.loop
        self.governor = BudgetGovernor(limit: options.budgetBytes, policy: options.evictionPolicy)
        stats.packetCount = recording.packetCount
        stats.duration = recording.durationNS > 0 ? Double(recording.durationNS) / 1e9 : 0
        stats.phase = options.startPaused ? .paused : .playing
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        stopRequested = true
        task?.cancel()
        connection.cancel()
    }

    /// Live reconfiguration from the Settings window / memory-pressure handler.
    /// The rate, loop flag, budget and eviction policy are picked up by the
    /// running loop; the size of an already-admitted chunk set is not re-planned
    /// until the next admission, so this never stalls playback.
    func updateOptions(rate newRate: Double, loop: Bool, budget: Int, policy: EvictionPolicy) {
        rate = min(max(newRate.isFinite ? newRate : rate, 0.05), 64)
        governor.setLimit(budget)
        governor.setPolicy(policy)
        loopRequested = loop
        publish()
    }

    // MARK: control surface (also fed by JSON text frames from the page)

    func handle(_ command: ReplayCommand) {
        guard options.allowControl else { return }
        defer { pacingTask?.cancel() }
        switch command {
        case .pause:
            if !paused {
                paused = true
                stats.phase = .paused
                publish()
            }
        case .resume:
            if paused {
                paused = false
                stats.phase = .playing
                publish()
            }
        case .step:
            if !paused {
                paused = true
                stats.phase = .paused
            }
            stepQueued = true
            publish()
        case .seek(let t):
            // A finished replay has no socket: enqueueing here used to leave the
            // phase stuck at "seeking" forever. The caller restarts instead.
            guard task != nil else {
                stats.errorText = "replay finished — restart before seeking"
                publish()
                return
            }
            seekQueue.append(t)
            stats.phase = .seeking
            publish()
        case .speed(let r):
            guard r.isFinite, r > 0 else { return }
            rate = min(max(r, 0.05), 64)
            publish()
        }
    }

    /// Parses one JSON text frame. Mirrors server.classifies(): invalid input is
    /// rejected without touching the stream.
    @discardableResult
    func handle(text: String) -> String? {
        guard options.allowControl else {
            return #"{"type":"error","message":"control channel disabled by the viewer"}"#
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String else {
            return #"{"type":"error","message":"control message must be a JSON object with a cmd"}"#
        }
        stats.controlCommands += 1
        if cmd == "seek" { stats.seeks += 1 }
        switch cmd {
        case "pause": handle(.pause); return #"{"type":"ok","cmd":"pause"}"#
        case "resume": handle(.resume); return #"{"type":"ok","cmd":"resume"}"#
        case "step": handle(.step); return #"{"type":"ok","cmd":"step"}"#
        case "seek":
            guard let raw = object["t"], !(raw is Bool),
                  let t = (raw as? NSNumber)?.doubleValue, t.isFinite else {
                return #"{"type":"error","message":"seek requires numeric \"t\""}"#
            }
            handle(.seek(t))
            return #"{"type":"ok","cmd":"seek"}"#
        case "speed":
            guard let raw = object["rate"], !(raw is Bool),
                  let r = (raw as? NSNumber)?.doubleValue, r.isFinite, r > 0 else {
                return #"{"type":"error","message":"speed requires a positive numeric \"rate\""}"#
            }
            handle(.speed(r))
            return #"{"type":"ok","cmd":"speed"}"#
        default:
            return #"{"type":"error","message":"unknown command"}"#
        }
    }

    // MARK: main loop

    private func run() async {
        var index = 0
        var previousTimestamp: UInt64?
        var session: UInt64 = 1
        var nextSequence: UInt64 = 0
        var renumbering = false
        var lastSentSequence: UInt64 = 0
        var lastTime: Double = 0

        stats.phase = paused ? .paused : .playing
        publish()

        while !stopRequested {
            // 1. control: seek wins, then step, then pause
            if let target = seekQueue.first {
                seekQueue.removeFirst()
                index = packetNumber(for: target)
                previousTimestamp = nil
                governor.reset()
                renumbering = false
                stats.evictions = 0
                stats.residentChunks = 0
                stats.residentBytes = 0
                stats.residentTriangles = 0
                paused = false
                stats.phase = .playing
                publish()
                continue
            }

            if paused && !stepQueued {
                await sleep(Self.tick)
                continue
            }

            // 2. end of stream
            if index >= recording.packetCount {
                if loopRequested {
                    index = 0
                    previousTimestamp = nil
                    governor.reset()
                    renumbering = false
                    stats.evictions = 0
                    lastSentSequence = 0
                    stats.phase = .playing
                    publish()
                    if options.loopGap > 0 {
                        await sleep(UInt64(options.loopGap * 1e9))
                    }
                    continue
                }
                break
            }

            // 3. read + decode one record (payload is copied transiently)
            let wire: Data
            let packet: S3DPPacket
            do {
                wire = try recording.wire(at: index)
                packet = try S3DPPacket.decode(wire)
            } catch {
                stats.phase = .failed
                publish()
                await fail("decode error at packet \(index): \(error.localizedDescription)")
                return
            }
            session = packet.session

            // 4. budget: admit / evict / skip
            var outgoing: [Data] = []
            var skipThis = false
            switch packet.opcode {
            case .chunkRemove:
                governor.remove(chunk: packet.chunk)
            case .chunkAdd, .chunkReplace:
                let header = S3DVMeshHeader.parse(packet.payload)
                let bytes = header?.residentBytes ?? packet.payload.count
                let triangles = (header?.indexCount ?? 0) / 3
                var decision = governor.admit(chunk: packet.chunk, revision: packet.revision,
                                             bytes: bytes, triangles: triangles)
                if !decision.evict.isEmpty || decision.skip {
                    // Sequence numbers must stay contiguous once we inject or drop
                    // packets, so the session switches to normalised numbering.
                    if !renumbering {
                        renumbering = true
                        nextSequence = lastSentSequence &+ 1
                    }
                    // CHUNK_REMOVE must carry a revision strictly greater than the
                    // resident one, otherwise the viewer ignores it. The next real
                    // event for that chunk (rev+1) is therefore dropped once; the
                    // chunk is meant to be gone, so that is the desired outcome.
                    for victim in decision.evict {
                        let remove = S3DPPacket.make(opcode: .chunkRemove, session: session,
                                                    sequence: nextSequence, chunk: victim.id,
                                                    revision: victim.revision &+ 1,
                                                    timestampNS: packet.timestampNS)
                        nextSequence &+= 1
                        outgoing.append(remove.encode())
                        stats.evictionsTotal += 1
                    }
                    skipThis = decision.skip
                    decision.evict = []
                }
            case .snapshotBegin:
                governor.reset()
                stats.evictions = 0
                renumbering = false
            default:
                break
            }

            if skipThis {
                stats.deferred += 1
                index += 1
                continue
            }

            // 5. emit (with the normalized sequence header when active)
            if renumbering {
                let rewired = packet.renumbered(sequence: nextSequence)
                nextSequence &+= 1
                lastSentSequence = rewired.sequence
                outgoing.append(rewired.encode())
            } else {
                lastSentSequence = packet.sequence
                outgoing.append(wire)
            }
            for frame in outgoing {
                do {
                    try await connection.sendBinary(frame, timeout: 20)
                } catch {
                    if Task.isCancelled {
                        stats.phase = .stopped
                        task = nil
                    } else {
                        stats.phase = .failed
                        stats.errorText = error.localizedDescription
                        CrashGuard.shared.log("replay stalled: \(error.localizedDescription) "
                            + "at packet \(index)/\(recording.packetCount)")
                    }
                    publish()
                    if stats.phase == .failed {
                        await connection.closeWithError(code: 1011, reason: stats.errorText)
                    }
                    return
                }
                stats.bytesSent += frame.count
                stats.framesSent += 1
            }
            stats.packetsSent += 1
            stats.packetIndex = index
            lastTime = Double(packet.timestampNS) / 1e9
            stats.currentTime = lastTime
            index += 1

            if stepQueued {
                stepQueued = false
                paused = true
                stats.phase = .paused
            }

            // 6. pacing (skipped for a step, which must be immediate)
            if !paused, let previous = previousTimestamp {
                let delay = ReplayClock.pacingDelay(prevTS: previous, ts: packet.timestampNS,
                                                    rate: rate, cap: options.pacingCap)
                if delay > 0 { await interruptibleSleep(delay) }
            }
            previousTimestamp = packet.timestampNS

            stats.residentChunks = governor.chunks
            stats.residentBytes = governor.residentBytes
            stats.residentTriangles = governor.residentTriangles
            stats.evictions = governor.evictions
            stats.renumbered = renumbering
            sampleRates()
            publish()
        }

        if stopRequested || Task.isCancelled {
            stats.phase = .stopped
            publish()
            return
        }
        stats.phase = .finished
        task = nil
        publish()
        await connection.closeAfterDrain()
    }

    // MARK: helpers

    private func packetNumber(for seconds: Double) -> Int {
        guard recording.packetCount > 0 else { return 0 }
        let clamped = max(0, min(seconds, max(0, stats.duration)))
        let offset = recording.checkpointOffset(atNS: UInt64(clamped * 1e9))
        return recording.packetNumber(atOffset: offset)
    }

    private func sleep(_ nanos: UInt64) async {
        try? await Task.sleep(nanoseconds: nanos)
    }

    /// Sleeps for `seconds`, waking immediately when a control command arrives.
    /// A sliced polling loop looked equivalent but each 20 ms slice is subject to
    /// timer coalescing in a background app: a 0.4 s pacing delay degraded to
    /// ~10 s per packet when the window was not frontmost.
    private func interruptibleSleep(_ seconds: Double) async {
        guard seconds > 0, !paused, !stepQueued, seekQueue.isEmpty else { return }
        let task = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        pacingTask = task
        await task.value
        pacingTask = nil
    }

    private func sampleRates() {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastRateSample.uptimeNanoseconds) / 1e9
        guard elapsed >= 0.5 else { return }
        let packets = stats.packetsSent - rateSamplePackets
        let bytes = stats.bytesSent - rateSampleBytes
        stats.packetsPerSecond = Double(packets) / elapsed
        stats.megabytesPerSecond = Double(bytes) / elapsed / 1_048_576
        rateSamplePackets = stats.packetsSent
        rateSampleBytes = stats.bytesSent
        lastRateSample = now
    }

    private var lastPublish = Date.distantPast

    private func publish() {
        // The loop calls this for every packet; SwiftUI only needs ~10 Hz.
        let now = Date()
        let throttle = stats.phase == .playing ? 0.1 : 0.0
        guard throttle == 0 || now.timeIntervalSince(lastPublish) >= throttle else { return }
        lastPublish = now
        onStats?(stats)
    }

    private func fail(_ message: String) async {
        onStats?(stats)
        await connection.closeWithError(code: 1011, reason: message)
    }
}

private extension ReplayClock {
    /// Pacing with a configurable cap (the kit hard-codes 2 s; the viewer lets
    /// the user raise it for slowed-down captures).
    static func pacingDelay(prevTS: UInt64, ts: UInt64, rate: Double, cap: Double) -> Double {
        guard rate > 0 else { return 0 }
        let gap = ts >= prevTS ? Double(ts - prevTS) / 1e9 : -1
        return min(max(cap, 0), max(0, gap / rate))
    }
}
