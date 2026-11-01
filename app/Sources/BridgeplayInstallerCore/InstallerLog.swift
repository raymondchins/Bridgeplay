import Darwin
import Foundation

/// What the installer did, for bug reports. Home paths are written as `~`.
public enum InstallerLog {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Bridgeplay/installer.log")
    private static let lock = NSLock()
    private static let limit = 512 * 1024

    public static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
            let previous = url.appendingPathExtension("1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(redact(message))\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The last lines, capped so they fit in a GitHub issue link.
    public static func tail(lines count: Int = 40, maxCharacters: Int = 4000) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
        return tail.count > maxCharacters ? String(tail.suffix(maxCharacters)) : tail
    }

    public static var system: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"), version].compactMap { $0 }.joined(separator: ", ")
    }

    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
