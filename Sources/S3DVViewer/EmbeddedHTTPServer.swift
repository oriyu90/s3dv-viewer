// Minimal loopback static server used as the embedded preview's web host.
// Uses Network.framework; accepts plain HTTP/1.1 GET/HEAD requests from the
// embedded WKWebView, drains declared Content-Length bodies, and serves files
// directly from the app bundle's resource directory.
// The listener is pinned to 127.0.0.1 (requiredLocalEndpoint) so the app never
// exposes anything beyond the loopback interface, and loopback HTTP is
// ATS-exempt, so no Info.plist exceptions are needed.
import Foundation
import Network
import S3DVCore

/// Shared embedded-server configuration and helpers.
enum EmbeddedServerConfig {
    /// TCP parameters pinned to 127.0.0.1 with a system-assigned ephemeral port.
    /// `port` 0 asks for an ephemeral port; a fixed port lets a user bookmark the
    /// loopback viewer URL or point an external browser at the same stream.
    static func loopbackTCPParams(port: UInt16 = 0,
                                  _ configure: (NWParameters) -> Void = { _ in }) -> NWParameters {
        let params = NWParameters.tcp
        configure(params)
        if let loopback = IPv4Address("127.0.0.1") {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(loopback), port: NWEndpoint.Port(rawValue: port) ?? 0)
        }
        return params
    }
}

/// Resumes a checked continuation at most once; the listener state handlers can
/// fire `.ready`/`.failed`/`.cancelled` in overlapping orders on the queue.
final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; body() }
    }
}

final class EmbeddedHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "s3dv.embedded.http")
    private(set) var port: UInt16 = 0
    var documentRoot: URL?

    private func dbg(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[http] \(message)\n".utf8))
        #endif
    }

    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "icns": return "image/x-icns"
        default: return "application/octet-stream"
        }
    }

    /// JSON served at /metadata so the page can enable its seek timeline.
    var metadataProvider: (() -> Data)?

    /// Binds 127.0.0.1; `port` 0 = ephemeral. Resolves once `ready`.
    func start(documentRoot: URL, port: UInt16 = 0) async throws -> UInt16 {
        self.documentRoot = documentRoot
        let listener = try NWListener(using: EmbeddedServerConfig.loopbackTCPParams(port: port))
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = ContinuationOnce()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    let assigned = listener?.port?.rawValue ?? 0
                    self.port = assigned
                    once.run { continuation.resume(returning: assigned) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: S3DVError.invalid("HTTP server cancelled while starting")) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard self != nil, listener != nil else { return }
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if error != nil { connection.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            guard let headerRange = buf.range(of: Data("\r\n\r\n".utf8)) else {
                // Bounded header accumulation: a request line/header block that
                // never terminates is a protocol error, not something to buffer.
                if buf.count > 64 * 1024 {
                    self?.sendSimple(connection, status: 431, text: "Request Header Fields Too Large")
                    return
                }
                if isComplete { connection.cancel() } else { self?.readRequest(connection, buffer: buf) }
                return
            }
            let headerBlob = String(decoding: buf[..<headerRange.lowerBound], as: UTF8.self)
            let headerLines = headerBlob.components(separatedBy: "\r\n")
            let requestLine = headerLines.first ?? ""
            let parts = requestLine.components(separatedBy: " ")
            let method = parts.first ?? "GET"
            let rawTarget = parts.count > 1 ? parts[1] : "/"

            var contentLength = 0
            for line in headerLines.dropFirst() {
                let pieces = line.components(separatedBy: ":")
                if pieces.count == 2,
                   pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
                   let n = Int(pieces[1].trimmingCharacters(in: .whitespaces)) {
                    contentLength = min(max(n, 0), 64 * 1024 * 1024)
                }
            }
            let bodyEnd = headerRange.upperBound + contentLength
            guard buf.count >= bodyEnd else {
                if isComplete { connection.cancel(); return }
                self?.readRequest(connection, buffer: buf)
                return
            }
            // Carry any pipelined bytes past this request into the next iteration
            // instead of dropping them (which would stall the connection).
            let leftover = buf.count > bodyEnd ? buf.subdata(in: bodyEnd..<buf.count) : Data()
            self?.respond(connection, method: method, rawTarget: rawTarget, leftover: leftover)
        }
    }

    private func sendSimple(_ connection: NWConnection, status: Int, text: String) {
        let payload = Data("\(text)\n".utf8)
        var head = "HTTP/1.1 \(status) \(text)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, method: String, rawTarget: String, leftover: Data) {
        var path = rawTarget
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path == "/" { path = "/index.html" }
        while path.hasPrefix("//") { path.removeFirst() }
        dbg("REQ \(rawTarget)")

        var status = 200
        var payload = Data()
        var mime = "application/octet-stream"
        let verb = method.uppercased()

        if verb != "GET" && verb != "HEAD" {
            status = 405
            mime = "text/plain; charset=utf-8"
            payload = Data("Method not allowed\n".utf8)
        } else if path.split(separator: "/").contains("..") || path.contains("\0") {
            status = 403
            mime = "text/plain; charset=utf-8"
            payload = Data("Forbidden\n".utf8)
        } else if path == "/metadata" {
            mime = "application/json; charset=utf-8"
            payload = metadataProvider?() ?? Data("{}".utf8)
        } else if path == "/favicon.ico" {
            status = 204
            payload = Data()
        } else if let root = documentRoot {
            let fileURL = root.appendingPathComponent(String(path.dropFirst()))
            if let data = try? Data(contentsOf: fileURL) {
                mime = Self.mimeType(forPath: path)
                payload = data
            } else {
                status = 404
                mime = "text/plain; charset=utf-8"
                payload = Data("Not found\n".utf8)
            }
        } else {
            status = 404
            mime = "text/plain; charset=utf-8"
            payload = Data("No document root\n".utf8)
        }

        var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        if status != 204 {
            // RFC 7230: a 204 response must not carry Content-Length or a body.
            head += "Content-Type: \(mime)\r\n"
            head += "Content-Length: \(payload.count)\r\n"
        }
        head += "Connection: keep-alive\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        var out = Data(head.utf8)
        if verb != "HEAD" && status != 204 { out.append(payload) }

        connection.send(content: out, completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            // Keep-alive: accept the next request on the same connection,
            // resuming from any bytes that were already pipelined.
            self?.readRequest(connection, buffer: leftover)
        })
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }
}
