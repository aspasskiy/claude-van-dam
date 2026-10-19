import CryptoKit
import Foundation

public struct SwapError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

enum JSONFiles {
    /// Parses a JSON object, preserving every key (never round-trip these files
    /// through Codable: unknown keys like `projects` or `mcpServers` would be lost).
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func serialize(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Temp file in the same directory, chmod 0600, then rename over the target.
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw SwapError("Couldn't write \(tmp.path)")
        }
        chmod(tmp.path, mode)
        if rename(tmp.path, url.path) != 0 {
            let err = String(cString: strerror(errno))
            unlink(tmp.path)
            throw SwapError("Couldn't replace \(url.path): \(err)")
        }
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// ISO dates as stored: "2026-10-16T09:29:59.711151+00:00" or "…Z".
enum ISODate {
    nonisolated(unsafe) private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fraction = try! NSRegularExpression(pattern: #"\.\d+"#)

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let trimmed = fraction.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        return parser.date(from: trimmed)
    }

    /// "%Y-%m-%dT%H:%M:%SZ".
    static func nowUTC() -> String { parser.string(from: Date()) }
}
