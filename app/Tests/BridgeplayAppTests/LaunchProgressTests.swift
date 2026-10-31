import CoreGraphics
import Foundation
import Testing

@testable import BridgeplayApp

@Suite("The panel between Play and the game's first window")
struct LaunchProgressTests {

    private let first = LaunchProgress(firstLaunch: true)
    private let later = LaunchProgress(firstLaunch: false)

    @Test("A first launch shows almost at once, a later one shortly after")
    func delays() {
        #expect(first.action(step: .setup, elapsed: 0.5, launchEnded: false, gameWindow: false) == .hidden)
        #expect(first.action(step: .setup, elapsed: 1, launchEnded: false, gameWindow: false) == .shown(.setup))
        // Hell Maiden's relaunch opened its window 12s in; most relaunches land around there, so
        // the delay must be well under that to actually show for them.
        #expect(later.action(step: .start, elapsed: 2, launchEnded: false, gameWindow: false) == .hidden)
        #expect(later.action(step: .start, elapsed: 3, launchEnded: false, gameWindow: false) == .shown(.start))
    }

    @Test("The game's window, the end of the launch or its end take the panel away")
    func quits() {
        #expect(first.action(step: .start, elapsed: 30, launchEnded: false, gameWindow: true) == .quit)
        #expect(first.action(step: .setup, elapsed: 30, launchEnded: true, gameWindow: false) == .quit)
        #expect(first.action(step: .ended, elapsed: 30, launchEnded: false, gameWindow: false) == .quit)
        // Before its delay too, so a fast launch never shows it.
        #expect(later.action(step: .start, elapsed: 2, launchEnded: false, gameWindow: true) == .quit)
        #expect(later.action(step: .start, elapsed: LaunchProgress.limit, launchEnded: false, gameWindow: false) == .quit)
    }

    @Test("A Bridgeplay alert hides it until the next step")
    func dialogs() {
        #expect(first.action(step: .dialog, elapsed: 30, launchEnded: false, gameWindow: false) == .hidden)
        #expect(first.action(step: .prepare, elapsed: 31, launchEnded: false, gameWindow: false) == .shown(.prepare))
    }

    @Test("An unknown step says only that the game is still starting")
    func unknownStep() {
        #expect(first.action(step: nil, elapsed: 5, launchEnded: false, gameWindow: false) == .shown(nil))
        #expect(LaunchProgress.phase(nil) == "Still starting…")
        #expect(LaunchProgress.phase(.setup) == "Setting up Windows for this game…")
        #expect(LaunchProgress.message(game: "Hell Maiden") == "Bridgeplay is starting Hell Maiden.")
        #expect(LaunchProgress.message(game: nil) == "Bridgeplay is starting this game.")
        #expect(first.note != nil)
        #expect(later.note == nil)
    }

    @Test("The steps are the words compat_run.sh writes")
    func stepsMatchTheRunScript() throws {
        let script = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../../../dylib/feats/compat_run.sh").standardizedFileURL, encoding: .utf8)
        #expect(script.contains("/\(LaunchProgressCommand.stepName)\""))
        #expect(script.contains(LaunchProgressCommand.flag))
        for step in ["setup", "prepare", "start", "dialog", "ended"] {
            #expect(LaunchStep(rawValue: step) != nil)
            #expect(script.contains("launch_progress \(step)") || script.contains("launch_step \(step)"))
        }
    }

    @Test("The game's processes are told by the launcher log they keep as stderr")
    func findsTheLauncherLog() throws {
        let dir = try scratchDirectory("launch-log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "bridgeplay-wine.log")
        let other = dir.appending(path: "other.log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: other.path(percentEncoded: false), contents: nil)
        var file = stat()
        #expect(stat(log.path(percentEncoded: false), &file) == 0)

        func sleeper(writingTo url: URL) throws -> Process {
            let child = Process()
            child.executableURL = URL(filePath: "/bin/sleep")
            child.arguments = ["5"]
            child.standardError = try FileHandle(forWritingTo: url)
            try child.run()
            return child
        }
        let game = try sleeper(writingTo: log)
        defer { game.terminate() }
        let stranger = try sleeper(writingTo: other)
        defer { stranger.terminate() }
        #expect(LaunchProgressWatcher.holdsOpen(device: file.st_dev, inode: file.st_ino, pid: game.processIdentifier))
        #expect(!LaunchProgressWatcher.holdsOpen(device: file.st_dev, inode: file.st_ino, pid: stranger.processIdentifier))
        #expect(!LaunchProgressWatcher.holdsOpen(device: file.st_dev, inode: file.st_ino, pid: -1))
    }

    @Test("A process is known by its start time, so a reused pid is looked at again")
    func startTimes() throws {
        let own = LaunchProgressWatcher.startTime(of: getpid())
        #expect(own != nil)
        #expect(LaunchProgressWatcher.startTime(of: getpid()) == own)
        #expect(LaunchProgressWatcher.startTime(of: -1) == nil)
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        #expect(LaunchProgressWatcher.startTime(of: child.processIdentifier) != own)
    }

    // The run script checks the app binary for the flag before passing it.
    @Test("The flag is long enough to sit in the binary's strings")
    func flagIsFindable() {
        #expect(LaunchProgressCommand.flag.utf8.count > 15)
    }

    @Test("The game is named from its library's appmanifest")
    func namesTheGame() throws {
        let dir = try scratchDirectory("launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)
        try FileManager.default.createDirectory(at: library.steamapps, withIntermediateDirectories: true)
        try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"3372060\"\n\t\"name\"\t\t\"Hell Maiden\"\n}\n".utf8)
            .write(to: library.steamapps.appending(path: "appmanifest_3372060.acf"))
        let compatdata = library.compatdata.path(percentEncoded: false)
        #expect(LaunchProgressWatcher.gameName(compatdata: compatdata + "/3372060") == "Hell Maiden")
        #expect(LaunchProgressWatcher.gameName(compatdata: compatdata + "/1") == nil)
        #expect(LaunchProgressWatcher.gameName(compatdata: "/elsewhere/3372060") == nil)
    }

    @Test("A full-screen game's window counts, a sliver of one does not")
    func windowOwnerTakesFullScreenLayers() {
        func window(layer: Int, width: Double = 1512) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: Int32(42),
             kCGWindowBounds as String: ["Width": width, "Height": 982.0]]
        }
        #expect(LaunchProgressWatcher.windowOwner(window(layer: 0)) == 42)
        #expect(LaunchProgressWatcher.windowOwner(window(layer: 26)) == 42)
        #expect(LaunchProgressWatcher.windowOwner(window(layer: 26, width: 10)) == nil)
        #expect(LaunchProgressWatcher.windowOwner(window(layer: -1)) == nil)
    }

}
