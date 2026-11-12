// Loopback WebSocket server hosting the .s3dv packet stream.
// Mirrors src/s3dv/server.py: each accepted connection replays the recording
// from its first packet; pacing delay = min(cap, (ts-prev)/1e9/rate).
// WebKit's window.WebSocket connects as an ordinary RFC 6455 client.
// Pinned to 127.0.0.1 like the HTTP server — never bound beyond loopback.
//
// Inbound text frames carry the JSON control channel (pause/resume/step/seek/
// speed). Binary client frames are ignored silently, exactly like server.py.
import Foundation
import Network
import S3DVCore

final class EmbeddedWSServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "s3dv.embedded.ws")
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var accepted = 0
    private(set) var maxClients = 1

    /// Called for every accepted + ready WebSocket connection.
    var onConnection: ((NWConnection) -> Void)?

    /// Binds 127.0.0.1; `port` 0 asks the system for an ephemeral port.
    /// Resolves on `.ready` and throws on `.failed`/`.cancelled` so a
    /// half-started server can never stall `open()`.
    func start(port requested: UInt16 = 0, maxClients: Int = 1) async throws -> UInt16 {
        self.maxClients = max(1, maxClients)
        let params = EmbeddedServerConfig.loopbackTCPParams(port: requested) { p in
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            p.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        }
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = ContinuationOnce()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    let assigned = listener?.port?.rawValue ?? 0
                    self.port = assigned
                    #if DEBUG
                    FileHandle.standardError.write(Data("[ws] ready port=\(assigned)\n".utf8))
                    #endif
                    once.run { continuation.resume(returning: assigned) }
                case .failed(let error):
                    NSLog("S3DV WS server failed: %@", String(describing: error))
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: S3DVError.invalid("WS server cancelled while starting")) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, listener != nil else { return }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let self else { return }
                        // Last client wins: a page reload replaces the view. Refusing
                        // the new connection instead left the viewer with a dead
                        // socket whenever a previous connection closed abnormally.
                        self.lock.lock()
                        self.accepted += 1
                        let over = self.accepted > self.maxClients
                        self.lock.unlock()
                        if over { NSLog("S3DV WS: more than %d clients connected", self.maxClients) }
                        self.onConnection?(connection)
                    case .failed, .cancelled:
                        self?.lock.lock()
                        self?.accepted = max(0, (self?.accepted ?? 1) - 1)
                        self?.lock.unlock()
                        connection.cancel()
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        lock.lock(); accepted = 0; lock.unlock()
    }
}

/// One live replay connection over WebSocket binary frames.
enum ReplayError: LocalizedError {
    case clientStalled(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .clientStalled(let seconds):
            return "viewer stopped reading for \(Int(seconds)) s (page frozen or suspended)"
        }
    }
}

/// Runs a block at most once across threads (send completion vs timeout).
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}

final class ReplayConnection: @unchecked Sendable {
    let connection: NWConnection
    /// Set by the engine; invoked when the remote side goes away mid-replay.
    var onRemoteClosed: (() -> Void)?
    /// Answers one inbound JSON text frame (returns the ack/error JSON to send).
    var onText: ((String) -> String?)?

    private let lock = NSLock()
    private var remoteClosed = false
    private var receiving = false

    init(connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.lock.lock()
                self.remoteClosed = true
                self.lock.unlock()
                self.onRemoteClosed?()
            default: break
            }
        }
    }

    var isClosedByPeer: Bool {
        lock.lock(); defer { lock.unlock() }
        return remoteClosed
    }

    // MARK: send

    /// Send one packet as its own binary WebSocket frame.
    ///
    /// `timeout` matters: if the WebContent process stops reading (a frozen or
    /// suspended page), the socket buffer fills and the send never completes,
    /// which used to wedge the whole replay with no error and no UI feedback.
    /// The race is resolved exactly once, so a late completion cannot double-resume.
    func sendBinary(_ wire: Data, timeout: TimeInterval = 20) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "packet", metadata: [metadata])
        let once = OnceBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: wire,
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { error in
                                once.run {
                                    if let error { cont.resume(throwing: error) }
                                    else { cont.resume() }
                                }
                            })
            if timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    once.run { cont.resume(throwing: ReplayError.clientStalled(timeout)) }
                }
            }
        }
    }

    private func sendText(_ text: String) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8),
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { error in
                                if let error { cont.resume(throwing: error) }
                                else { cont.resume() }
                            })
        }
    }

    // MARK: receive (control channel)

    /// Starts the inbound frame loop. Text frames are handed to `onText`; binary
    /// frames are drained and ignored (server.py parity).
    func startReceiving() {
        lock.lock()
        guard !receiving else { lock.unlock(); return }
        receiving = true
        lock.unlock()
        pump()
    }

    private func pump() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }
            if error != nil { return }
            guard let content, !content.isEmpty else {
                // End of stream: re-arming receive on a finished connection spun
                // the socket queue at 100 % CPU.
                if isComplete || error != nil { return }
                self.pump()
                return
            }
            // Only text frames carry the control channel; the client never sends
            // binary. Sniffing the payload keeps this off the protocol-metadata
            // API, whose definition type differs across SDK builds.
            let text = String(decoding: content, as: UTF8.self)
            if text.hasPrefix("{"), text.hasSuffix("}"), text.contains("cmd") {
                if let reply = self.onText?(text) {
                    Task { try? await self.sendText(reply) }
                }
            }
            self.pump()
        }
    }

    // MARK: close

    private func sendCloseFrame(code: UInt16, reason: String = "") async {
        var payload = Data()
        payload.append(UInt8(truncatingIfNeeded: code >> 8))
        payload.append(UInt8(truncatingIfNeeded: code))
        if !reason.isEmpty { payload.append(Data(reason.utf8).prefix(120)) }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: payload,
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { _ in cont.resume() })
        }
    }

    /// Clean end of stream: 1000 close frame, then wait for the peer to hang up
    /// (bounded) before tearing the socket down. Cancelling immediately after the
    /// close frame used to truncate large replays — the 1.27 GB stream lost ~28 %
    /// of its packets that way.
    func closeAfterDrain(timeout: TimeInterval = 2.0) async {
        await sendCloseFrame(code: 1000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !isClosedByPeer {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        onRemoteClosed = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Abnormal end: 1011 close frame, then drop.
    func closeWithError(code: UInt16, reason: String) async {
        await sendCloseFrame(code: code, reason: reason)
        onRemoteClosed = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func cancel() {
        onRemoteClosed = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
