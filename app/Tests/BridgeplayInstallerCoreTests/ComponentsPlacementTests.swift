import CryptoKit
import Foundation
import Testing
@testable import BridgeplayInstallerCore

@Suite("Placing the installer components")
struct ComponentsPlacementTests {
    private final class Calls: @unchecked Sendable {
        var steam: [URL] = []
        var resets = 0
        var statuses: [String] = []
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private struct Fixture {
        let root: URL, source: URL, home: URL, applications: URL
        var support: URL { home.appending(path: "Library/Application Support/bridgeplay") }
        var caches: URL { home.appending(path: "Library/Caches/bridgeplay") }
    }

    private func fixture(steam: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "placement-\(UUID().uuidString)")
        let source = root.appending(path: "Bridgeplay")
        let files = [
            "gptk/external/libd3dshared.dylib": "new gptk",
            "cache/engines/dxmt.tar.gz": "dxmt",
            "config/gamefixes-default/default.conf": "SHIPPED=1\n",
            "config/gamefixes-default/448510.conf": "BACKEND=dxmt\n",
            "config/gamefixes-default/notes.txt": "not a conf",
            "config/gamecontrollerdb.txt": "shipped mappings",
        ]
        for (path, text) in files {
            let url = source.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let applications = root.appending(path: "Applications")
        try fm.createDirectory(at: applications.appending(path: steam ? "Steam.app" : "Other.app"), withIntermediateDirectories: true)
        let home = root.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return Fixture(root: root, source: source, home: home, applications: applications)
    }

    private func placement(_ f: Fixture, _ calls: Calls) -> ComponentsPlacement {
        var placement = ComponentsPlacement(source: f.source)
        placement.home = f.home
        placement.applications = f.applications
        placement.installSteam = { applications, _ in calls.steam.append(applications) }
        placement.resetSetupAssistant = { calls.resets += 1 }
        return placement
    }

    private func text(_ url: URL) -> String? {
        FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("A fresh Mac gets GPTK, the engine archives, the shipped confs and the mappings")
    func freshMac() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let calls = Calls()
        try placement(f, calls).place(status: { calls.statuses.append($0) })

        #expect(text(f.support.appending(path: "gptk/external/libd3dshared.dylib")) == "new gptk")
        #expect(text(f.caches.appending(path: "engines/dxmt.tar.gz")) == "dxmt")
        #expect(text(f.support.appending(path: "gamefixes-default/448510.conf")) == "BACKEND=dxmt\n")
        #expect(!FileManager.default.fileExists(atPath: f.support.appending(path: "gamefixes-default/notes.txt").path))
        // The user's own default.conf is never written.
        #expect(!FileManager.default.fileExists(atPath: f.support.appending(path: "gamefixes/default.conf").path))
        #expect(FileManager.default.fileExists(atPath: f.support.appending(path: ".installer").path))
        #expect(text(f.support.appending(path: "gamecontrollerdb.txt")) == "shipped mappings")
        #expect(calls.steam.isEmpty)
        #expect(calls.resets == 1)
        #expect(calls.statuses == [ComponentsPlacement.copyStatus])
    }

    @Test("Steam is installed first only when Applications has none")
    func steamWhenMissing() throws {
        let f = try fixture(steam: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let calls = Calls()
        try placement(f, calls).place(status: { calls.statuses.append($0) })
        #expect(calls.steam == [f.applications])
        #expect(calls.statuses == [ComponentsPlacement.steamStatus, ComponentsPlacement.copyStatus])
    }

    @Test("A failed Steam install stops before anything is copied")
    func steamFailure() throws {
        let f = try fixture(steam: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var placement = placement(f, Calls())
        placement.installSteam = { _, _ in throw InstallerError.componentsFailure("no Steam") }
        #expect(throws: InstallerError.self) { try placement.place() }
        #expect(!FileManager.default.fileExists(atPath: f.support.appending(path: "gptk").path))
    }

    @Test("A failed copy logs the tool's reason and shows the plain message")
    func failureReasonIsLogged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.source.appending(path: "gptk"))
        let lines = Lines()
        var placement = placement(f, Calls())
        placement.log = { lines.add($0) }

        let failure = try #require(throws: InstallerError.self) { try placement.place() }

        guard case .componentsFailure(let message) = failure else {
            Issue.record("Unexpected error: \(failure)")
            return
        }
        #expect(message == "The Game Porting Toolkit could not be copied.")
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.hasPrefix(message) == true)
        #expect(lines.all.first?.contains("ditto") == true)
    }

    @Test("An older GPTK is replaced whole, and the user's mappings and edited confs stay")
    func update() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fm = FileManager.default
        for (path, text) in ["gptk/stale.dylib": "old", "gamecontrollerdb.txt": "my mappings",
                             "gamefixes/111.conf": "untouched copy", "gamefixes/222.conf": "edited copy",
                             "gamefixes-default/448510.conf": "BACKEND=d3dmetal\n"] {
            let url = f.support.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        var placement = placement(f, Calls())
        placement.oldConfs = ["111": ComponentsPlacement.hex(SHA256.hash(data: Data("untouched copy".utf8))),
                              "222": ComponentsPlacement.hex(SHA256.hash(data: Data("original copy".utf8)))]
        try placement.place()

        #expect(!fm.fileExists(atPath: f.support.appending(path: "gptk/stale.dylib").path))
        #expect(try fm.contentsOfDirectory(atPath: f.support.path).filter { $0.hasPrefix(".gptk-") }.isEmpty)
        #expect(text(f.support.appending(path: "gamecontrollerdb.txt")) == "my mappings")
        #expect(!fm.fileExists(atPath: f.support.appending(path: "gamefixes/111.conf").path))
        #expect(text(f.support.appending(path: "gamefixes/222.conf")) == "edited copy")
        #expect(text(f.support.appending(path: "gamefixes-default/448510.conf")) == "BACKEND=dxmt\n")
    }

    @Test("Two placements at once both succeed and leave one whole toolkit")
    func concurrentPlacements() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var placement = placement(f, Calls())
        // Shared by the workers below, so it must not touch the unlocked call counters.
        placement.resetSetupAssistant = {}
        try placement.place()
        nonisolated(unsafe) let shared = placement
        nonisolated(unsafe) var failures: [Error] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do { try shared.place() } catch { lock.withLock { failures.append(error) } }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(text(f.support.appending(path: "gptk/external/libd3dshared.dylib")) == "new gptk")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.support.path).filter { $0.hasPrefix(".gptk-") }.isEmpty)
    }

    @Test("While only the notproton folders exist, the files go there for the app's own move")
    func legacyFolders() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let library = f.home.appending(path: "Library")
        for legacy in ["Application Support/notproton", "Caches/notproton"] {
            try FileManager.default.createDirectory(at: library.appending(path: legacy), withIntermediateDirectories: true)
        }
        try placement(f, Calls()).place()
        #expect(text(library.appending(path: "Application Support/notproton/gptk/external/libd3dshared.dylib")) == "new gptk")
        #expect(text(library.appending(path: "Caches/notproton/engines/dxmt.tar.gz")) == "dxmt")
        #expect(!FileManager.default.fileExists(atPath: f.support.path))
    }

    @Test("Only a file ending in a UDIF trailer passes as Valve's disk image")
    func diskImage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "koly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "good.dmg"), bad = dir.appending(path: "bad.dmg"), short = dir.appending(path: "short.dmg")
        try (Data(repeating: 0, count: 1000) + Data("koly".utf8) + Data(repeating: 0, count: 508)).write(to: good)
        try Data(repeating: 0, count: 2000).write(to: bad)
        try Data("koly".utf8).write(to: short)
        #expect(ValveSteam.isDiskImage(good))
        #expect(!ValveSteam.isDiskImage(bad))
        #expect(!ValveSteam.isDiskImage(short))
    }
}
