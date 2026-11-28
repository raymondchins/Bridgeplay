import Foundation
import Testing

@testable import BridgeplayApp

@Suite("The panel after a launch that went wrong")
struct LaunchEndedTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ending(_ record: String, now: Date = Self.now) throws -> LaunchEnding? {
        let record = try #require(LaunchRecord.parse(record + "\nended=1800000000\n"))
        return LaunchEnding(record: record, now: now)
    }

    @Test("A crash, a quick quit or no window ever: the Status card's sentence and See Reports")
    func failures() throws {
        let crash = try #require(try ending("code=access_violation\nexit=5\nseconds=14\nstopped=game"))
        #expect(crash.verdict == .crashed)
        #expect(crash.seconds == 14)
        #expect(crash.next == .seeReports)
        #expect(crash.verdict.sentence == "Crashed.")
        #expect(crash.button == "See Reports")
        for code in ["quit_early", "illegal_instruction", "dll_not_found", "sigsegv", "sigkill", "generic_failure"] {
            #expect(try ending("code=\(code)\nexit=1\nseconds=9\nstopped=game")?.next == .seeReports, "\(code)")
        }
        let hung = try #require(try ending("code=stopped_from_steam\nexit=143\nseconds=200\nstopped=steam\nwindow="))
        #expect(hung.verdict == .neverOpenedWindow)
        #expect(hung.next == .seeReports)
    }

    @Test("A kernel anti-cheat points at the guide's other ways to play")
    func antiCheat() throws {
        let blocked = try #require(try ending("code=anticheat_driver\nexit=1\nseconds=4\nstopped=game"))
        #expect(blocked.next == .otherWaysToPlay)
        #expect(blocked.button == "Other Ways to Play")
        #expect(blocked.url(for: WinePrefix(appID: "1", name: nil, library: SteamLibrary(root: URL(filePath: "/x")), lastUsed: nil))
                == HelpLinks.antiCheatAlternatives)
    }

    @Test("A normal end, a stop after a window, a kill from outside or a stop before launch show nothing")
    func quiet() throws {
        #expect(try ending("code=ok\nexit=0\nseconds=900\nstopped=game") == nil)
        #expect(try ending("code=stopped_from_steam\nexit=143\nseconds=900\nstopped=steam\nwindow=8") == nil)
        #expect(try ending("code=stopped_from_steam\nexit=143\nseconds=900\nstopped=steam") == nil)
        #expect(try ending("code=sigterm\nexit=143\nseconds=30\nstopped=unknown") == nil)
        #expect(try ending("code=launch_services\nexit=0\nseconds=5\nstopped=unknown") == nil)
        // An exit code naming no cause, after a minute: a normal quit for some games.
        #expect(try ending("code=generic_failure\nexit=1\nseconds=2400\nstopped=game") == nil)
        #expect(try ending("code=exit_code\nexit=42\nseconds=60\nstopped=game") == nil)
        // A crash line or a Windows exception code still shows, however long it ran.
        #expect(try ending("code=crashed\nexit=1\nseconds=2400\nstopped=game")?.next == .seeReports)
        #expect(try ending("code=access_violation\nexit=5\nseconds=2400\nstopped=game")?.next == .seeReports)
        // These have their own alerts, and never ran the game.
        #expect(try ending("code=engine_missing\nexit=\nseconds=0\nstopped=unknown") == nil)
        #expect(try ending("code=anticheat_blocked\nexit=\nseconds=0\nstopped=unknown") == nil)
        #expect(try ending("code=aborted\nexit=\nseconds=0\nstopped=unknown") == nil)
    }

    @Test("A launch started before the panel came up shows nothing")
    func newerLaunch() {
        #expect(LaunchEndedCommand.shows(step: "ended"))
        for step in ["setup", "prepare", "start", "dialog"] {
            #expect(!LaunchEndedCommand.shows(step: step), "\(step)")
        }
        #expect(!LaunchEndedCommand.shows(step: nil))
    }

    @Test("Another launch's record shows nothing")
    func staleRecord() throws {
        let later = Self.now.addingTimeInterval(LaunchEndedCommand.freshness + 1)
        #expect(try ending("code=access_violation\nexit=5\nseconds=14\nstopped=game", now: later) == nil)
        let record = try #require(LaunchRecord.parse("code=access_violation\nexit=5\nseconds=14\nstopped=game\n"))
        #expect(LaunchEnding(record: record, now: Self.now) == nil)
    }

    @Test("Every verdict decides whether it shows")
    func everyVerdict() {
        let shown: [LaunchVerdict] = [.neverOpenedWindow, .quitEarly, .crashed, .illegalInstruction, .missingFile,
                                      .macKilled, .lowMemory, .unexpected, .antiCheat]
        for verdict in shown { #expect(LaunchEnding.next(for: verdict) != nil, "\(verdict)") }
        // Only failures show, so the panel never disagrees with the Status card.
        for verdict in shown { #expect(verdict.failed) }
    }

    @Test("The compatdata folder gives the game, its name and its library")
    func prefix() throws {
        let dir = try scratchDirectory("launch-ended")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)
        try FileManager.default.createDirectory(at: library.compatdata.appending(path: "1145360"), withIntermediateDirectories: true)
        try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"1145360\"\n\t\"name\"\t\t\"Hades\"\n}\n".utf8)
            .write(to: library.steamapps.appending(path: "appmanifest_1145360.acf"))
        let compatdata = library.compatdata.path(percentEncoded: false)
        let found = try #require(LaunchEndedCommand.prefix(compatdata: compatdata + "/1145360", userdata: dir))
        #expect(found.appID == "1145360")
        #expect(found.name == "Hades")
        #expect(found.library.root.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(LaunchEndedCommand.prefix(compatdata: compatdata + "/../1145360", userdata: dir) == nil)
        #expect(LaunchEndedCommand.prefix(compatdata: "/elsewhere/1145360", userdata: dir) == nil)
        #expect(LaunchEndedCommand.prefix(compatdata: "relative/steamapps/compatdata/1", userdata: dir) == nil)
        #expect(LaunchEndedCommand.prefix(compatdata: compatdata + "/12a", userdata: dir) == nil)
    }

    @Test("The duration line is the Status card's")
    func duration() {
        #expect(LastLaunch.duration(seconds: 14) == "Stopped after 14 s")
        #expect(LastLaunch.duration(seconds: 840) == "Stopped after 14 min")
        #expect(LastLaunch.duration(seconds: nil) == "Stopped")
    }
}
