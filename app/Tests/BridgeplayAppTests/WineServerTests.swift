import Foundation
import Testing

@testable import BridgeplayApp

// Serialized: each case looks for children of this process, so cases must not overlap.
@Suite("WineServer", .serialized)
struct WineServerTests {

    // Runs a copy of sleep under `name` as a child of this process, so a real game's server on
    // the Mac cannot change the answer. Returns whether WineServer sees it.
    private func sees(serverNamed name: String) throws -> Bool {
        let dir = URL.temporaryDirectory.appending(path: "np-wineserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only this process's children, whatever else the Mac runs.
        let pgrep = dir.appending(path: "pgrep")
        try Data("#!/bin/sh\nexec /usr/bin/pgrep -P \(getpid()) \"$@\"\n".utf8).write(to: pgrep)
        let server = dir.appending(path: name)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: server.path(percentEncoded: false))
        for url in [pgrep, server] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }
        // A copied system binary only runs with a signature of its own.
        let sign = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", server.path(percentEncoded: false)])
        try #require(sign.succeeded)

        let process = Process()
        process.executableURL = server
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }

        return WineServer.isRunning(pgrep: pgrep.path(percentEncoded: false))
    }

    @Test("Every engine's server name counts as a running game",
          arguments: ["wineserver-arm64", "wineserver-x86", "wineserver"])
    func everyServerNameCounts(name: String) throws {
        #expect(try sees(serverNamed: name))
    }

    @Test("A process that only starts with wineserver does not count",
          arguments: ["wineserver-arm64x", "wineserver-foo", "xwineserver"])
    func lookAlikesDoNotCount(name: String) throws {
        let seen = try sees(serverNamed: name)
        #expect(seen == false)
    }

    // The names come from PrefixTools.layout (and compat_run.sh). A server it can pick that the
    // pattern misses would put the bug back, so every layout's server has to match.
    @Test("Every server PrefixTools can pick matches the pattern",
          arguments: [
            (["lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine", "bin/wineserver-arm64"], CompatTool.Flavor.fex),
            (["lib/wine/x86_64-unix/wine", "bin/wineserver"], .rosetta),
            (["lib/wine/x86_64-unix/wine", "bin/wineserver-x86"], .rosetta),
          ])
    func everyLayoutServerMatches(files: [String], flavor: CompatTool.Flavor) throws {
        let fm = FileManager.default
        let runner = fm.temporaryDirectory.appending(path: "np-server-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: runner) }
        for path in files {
            let file = runner.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }

        let name = PrefixTools.layout(runner: runner, flavor: flavor).server.lastPathComponent
        let regex = try NSRegularExpression(pattern: "^(\(WineServer.processPattern))$")
        #expect(regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil, "\(name)")
    }
}
