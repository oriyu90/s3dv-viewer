// One control request, parsed from a single line of text.
//
// Two shapes are accepted so that both the CLI and a human with `nc -U` can talk
// to the app:
//
//   {"cmd":"seek","t":"3.5"}          JSON (what s3dvctl sends)
//   seek t=3.5                        whitespace + key=value
//   seek 3.5                          bare tokens become arg0, arg1, …
import Foundation

public struct ControlRequest: Equatable, Sendable {
    public let cmd: String
    public let args: [String: String]
    public let raw: String

    public init(cmd: String, args: [String: String] = [:], raw: String = "") {
        self.cmd = cmd.lowercased()
        self.args = args
        self.raw = raw
    }

    public func string(_ key: String) -> String? {
        args[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    public func double(_ key: String) -> Double? {
        guard let raw = string(key) else { return nil }
        return Double(raw)
    }

    public func int(_ key: String) -> Int? {
        guard let raw = string(key) else { return nil }
        return Int(raw)
    }

    /// Accepts "on/off/true/false/yes/no/1/0" for switches.
    public func flag(_ key: String, default fallback: Bool? = nil) -> Bool? {
        guard let raw = string(key)?.lowercased() else { return fallback }
        switch raw {
        case "1", "on", "true", "yes", "y": return true
        case "0", "off", "false", "no", "n": return false
        default: return fallback
        }
    }

    public static func parse(_ line: String) -> ControlRequest? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = object["cmd"] as? String, !cmd.isEmpty else { return nil }
            var args: [String: String] = [:]
            for (key, value) in object where key != "cmd" {
                if let s = value as? String { args[key] = s }
                else if let n = value as? NSNumber { args[key] = n.stringValue }
                else if let b = value as? Bool { args[key] = b ? "true" : "false" }
            }
            return ControlRequest(cmd: cmd, args: args, raw: trimmed)
        }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let cmd = parts.first else { return nil }
        var args: [String: String] = [:]
        var positional = 0
        for token in parts.dropFirst() {
            if let eq = token.firstIndex(of: "="), eq != token.startIndex {
                args[String(token[..<eq])] = String(token[token.index(after: eq)...])
            } else {
                args["arg\(positional)"] = token
                positional += 1
            }
        }
        return ControlRequest(cmd: cmd, args: args, raw: trimmed)
    }
}

public enum ControlJSON {
    /// Compact, stable key order for the reply (pretty-printed when asked).
    public static func encode(_ object: [String: Any], pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"failed to encode reply"}"#
        }
        return text
    }

    public static func error(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }
}
