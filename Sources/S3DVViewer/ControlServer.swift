// UNIX domain socket that exposes the running app to the command line.
//
// Why a socket and not AppleScript/URL schemes: the viewer has to be scriptable
// for long running checks (open → seek → bench → close) without stealing focus,
// and a UNIX socket gives us that with no extra entitlements and no TCC prompts.
//
// Security: the socket lives in the user's Application Support directory (0700),
// the socket file itself is 0600, and every accepted connection is checked against
// the current uid with LOCAL_PEERCRED. Nothing is reachable from another user and
// nothing listens on a network interface.
import Foundation
import Darwin
import S3DVCore
import S3DVControl

final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "s3dv.control.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var socketPath: String = ""
    private let lock = NSLock()

    /// Handles one raw request line and returns the reply line (no newline).
    var onRequest: (@Sendable (String) async -> String)?

    private(set) var isRunning = false

    // Darwin: SOL_LOCAL == 0, LOCAL_PEERCRED == 0x0001 (sys/un.h).
    private static let solLocal: Int32 = 0
    private static let localPeerCred: Int32 = 0x0001

    // MARK: - lifecycle

    func start(path: String) throws {
        stop()
        guard path.utf8.count <= ControlPath.maxPathBytes else {
            throw S3DVError.invalid("control socket path is too long (\(path.utf8.count) bytes)")
        }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw S3DVError.invalid("socket() failed: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw S3DVError.invalid("bind(\(path)) failed: \(code)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw S3DVError.invalid("listen() failed: \(code)")
        }

        // Non-blocking accept: the read source fires when a client is pending, and
        // a blocking accept() at the end of the drain loop parked the whole queue
        // (the first client then never got served).
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        listenFD = fd
        socketPath = path
        isRunning = true
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        CrashGuard.shared.log("control socket listening at \(path)")
    }

    func stop() {
        lock.lock()
        let running = isRunning
        isRunning = false
        lock.unlock()
        guard running else { return }
        source?.cancel()
        source = nil
        listenFD = -1
        if !socketPath.isEmpty { unlink(socketPath) }
        socketPath = ""
    }

    // MARK: - accept + serve

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN: no more pending clients
            }
            // Accepted sockets inherit the listener's O_NONBLOCK flag on Darwin,
            // so a read could return EAGAIN before the client's bytes arrived and
            // the reply was silently dropped. Clear it for the connection.
            let flags = fcntl(client, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }
            // Serve on a concurrent queue: a `wait` request holds its connection
            // for minutes and must not stop other clients from being accepted.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard peerIsCurrentUser(fd) else {
            // Never vanish silently: a client that gets no bytes cannot tell a
            // permission problem from a crashed app.
            writeAll(fd, ControlJSON.error("control socket accepts only the current user") + "\n")
            return
        }
        guard let line = readLine(fd) else {
            writeAll(fd, ControlJSON.error("empty request") + "\n")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task {
            if let handler = self.onRequest {
                box.text = await handler(line)
            } else {
                box.text = ControlJSON.error("no handler installed")
            }
            semaphore.signal()
        }
        // Bounded wait: a wedged handler must not pin this connection forever.
        if semaphore.wait(timeout: .now() + 1_000) == .timedOut {
            box.text = ControlJSON.error("request timed out")
        }
        writeAll(fd, box.text + "\n")
    }

    private func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let rc = getsockopt(fd, Self.solLocal, Self.localPeerCred, &cred, &length)
        guard rc == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    private func readLine(_ fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 65_536 {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                return String(decoding: line, as: UTF8.self)
            }
        }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }

    private func writeAll(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                if errno == EINTR || errno == EAGAIN { usleep(500); continue }
                return
            }
            offset += n
        }
    }
}

/// Mutable reply slot shared between the socket thread and the handler task.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
