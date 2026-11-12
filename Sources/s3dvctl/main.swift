// s3dvctl — drives a running S3DV viewer over its UNIX control socket.
//
//   s3dvctl status
//   s3dvctl open path=~/runs/tdt_fuse/prod_gt.s3dv
//   s3dvctl pause
//   s3dvctl seek t=12.5
//   s3dvctl set rate 0.5
//   s3dvctl bench 20 --json
//   s3dvctl wait timeout=600
//
// Every command the GUI exposes is available; `s3dvctl help` lists them.
import Foundation
import Darwin
import S3DVControl

// MARK: - usage

let usage = """
s3dvctl — S3DV viewer をコマンドラインから操作する

使い方:
  s3dvctl <command> [key=value ...] [--json] [--socket PATH]

例:
  s3dvctl status
  s3dvctl open path=~/runs/tdt_fuse/prod_gt.s3dv
  s3dvctl pause; s3dvctl step; s3dvctl seek t=12.5; s3dvctl play
  s3dvctl set rate 0.5
  s3dvctl set budget 384
  s3dvctl bench 20 --json
  s3dvctl screenshot path=/tmp/city.png
  s3dvctl wait timeout=600
  s3dvctl quit

終了コード: 0 成功 / 1 サーバーがエラーを返した / 2 使い方の誤り / 3 接続できない / 4 wait がタイムアウト
"""

// MARK: - argument parsing

struct Options {
    var command = ""
    var pairs: [String: String] = [:]
    var positional: [String] = []
    var json = false
    var socket = ControlPath.socketURL().path
}

func parseArguments(_ argv: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < argv.count {
        let token = argv[index]
        switch token {
        case "--json":
            options.json = true
        case "--socket":
            guard index + 1 < argv.count else { return nil }
            options.socket = argv[index + 1]
            index += 1
        case "-h", "--help":
            options.command = "help"
        default:
            if options.command.isEmpty {
                options.command = token.lowercased()
            } else if let equals = token.firstIndex(of: "=") {
                options.pairs[String(token[..<equals])] = String(token[token.index(after: equals)...])
            } else {
                options.positional.append(token)
            }
        }
        index += 1
    }
    // Bare tokens become arg0, arg1, … so `rate 0.5` and `seek 12` both work.
    for (offset, value) in options.positional.enumerated() {
        options.pairs["arg\(offset)"] = value
    }
    return options.command.isEmpty ? nil : options
}

// MARK: - socket client

func connect(to path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count <= ControlPath.maxPathBytes else { close(fd); return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            for (i, byte) in bytes.enumerated() { destination[i] = CChar(bitPattern: byte) }
            destination[bytes.count] = 0
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { close(fd); return nil }
    // `wait` may legitimately hold the connection for a long time.
    var timeout = timeval(tv_sec: 3_700, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

func roundTrip(path: String, line: String) -> String? {
    guard let fd = connect(to: path) else { return nil }
    defer { close(fd) }
    var payload = Array((line + "\n").utf8)
    var sent = 0
    while sent < payload.count {
        let n = payload[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return nil }
        sent += n
    }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { return nil }
        if n == 0 { break }
        data.append(contentsOf: chunk[0..<n])
        if chunk[0..<n].contains(0x0A) { break }
    }
    guard !data.isEmpty else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - output

func render(_ value: Any, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent)
    switch value {
    case let dictionary as [String: Any]:
        return dictionary.keys.sorted().map { key in
            let rendered = render(dictionary[key]!, indent: indent + 2)
            if rendered.hasPrefix("\n") || rendered.contains("\n") && !rendered.hasPrefix("[") {
                return "\(pad)\(key):\n\(rendered)"
            }
            return "\(pad)\(key): \(rendered)"
        }.joined(separator: "\n")
    case let array as [Any]:
        if array.isEmpty { return "[]" }
        return "\n" + array.map { pad + "  - " + render($0, indent: indent + 4) }.joined(separator: "\n")
    case is NSNull:
        return "—"
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        let double = number.doubleValue
        return double == double.rounded() && abs(double) < 1e15
            ? String(format: "%.0f", double) : String(format: "%.3f", double)
    default:
        return "\(value)"
    }
}

func renderCommands(_ list: [[String: Any]]) -> String {
    let rows = list.compactMap { item -> (String, String, String)? in
        guard let cmd = item["cmd"] as? String,
              let usage = item["usage"] as? String,
              let desc = item["desc"] as? String else { return nil }
        return (cmd, usage, desc)
    }
    let width = rows.map { $0.1.count }.max() ?? 0
    return rows.map { cmd, usage, desc in
        "  " + usage.padding(toLength: max(width, usage.count), withPad: " ", startingAt: 0) + "  " + desc
    }.joined(separator: "\n")
}

// MARK: - main

guard let options = parseArguments(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

if options.command == "help" && options.pairs.isEmpty {
    // Ask the server for the authoritative list; fall back to local usage.
    if let reply = roundTrip(path: options.socket, line: #"{"cmd":"help"}"#),
       let data = reply.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let commands = object["commands"] as? [[String: Any]] {
        print("S3DV viewer control — commands\n")
        print(renderCommands(commands))
        print("\n詳細は apps/s3dv-viewer/README.md の「CLI」節。")
        exit(0)
    }
    print(usage)
    exit(0)
}

var request: [String: Any] = ["cmd": options.command]
for (key, value) in options.pairs { request[key] = value }
guard let requestData = try? JSONSerialization.data(withJSONObject: request),
      let requestLine = String(data: requestData, encoding: .utf8) else {
    FileHandle.standardError.write(Data("failed to encode request\n".utf8))
    exit(2)
}

guard let reply = roundTrip(path: options.socket, line: requestLine) else {
    FileHandle.standardError.write(Data("""
    S3DV viewer に接続できません（\(options.socket)）。
    - アプリが起動しているか確認してください
    - 別のソケットを使う場合は --socket PATH か S3DV_CONTROL_SOCKET を指定してください

    """.utf8))
    exit(3)
}

guard let data = reply.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    FileHandle.standardError.write(Data("unexpected reply: \(reply)\n".utf8))
    exit(1)
}

if options.json {
    print(reply)
} else if let commands = object["commands"] as? [[String: Any]] {
    print(renderCommands(commands))
} else if object["ok"] as? Bool == true {
    var printable = object
    printable.removeValue(forKey: "ok")
    print(printable.isEmpty ? "ok" : render(printable))
} else {
    FileHandle.standardError.write(Data("error: \(object["error"] as? String ?? "unknown")\n".utf8))
    exit(1)
}

if options.command == "wait", (object["timedOut"] as? Bool) == true { exit(4) }
if object["ok"] as? Bool == false { exit(1) }
exit(0)
