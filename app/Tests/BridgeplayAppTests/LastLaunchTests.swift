import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Last launch card")
struct LastLaunchTests {

    private static let header = "=== bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===\nverb=waitforexitandrun\n"

    private static func library() throws -> SteamLibrary {
        let root = URL.temporaryDirectory.appending(path: "bp-lastlaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "steamapps/compatdata"), withIntermediateDirectories: true)
        return SteamLibrary(root: root)
    }

    private static func game(_ appID: String, in library: SteamLibrary, name: String? = nil, pfx: Bool = true) throws -> URL {
        let folder = library.compatdata.appending(path: appID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if pfx { try FileManager.default.createDirectory(at: folder.appending(path: "pfx"), withIntermediateDirectories: true) }
        if let name {
            try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"name\"\t\t\"\(name)\"\n}\n".utf8)
                .write(to: library.steamapps.appending(path: "appmanifest_\(appID).acf"))
        }
        return folder
    }

    @Test("A record is KEY=VALUE lines; unknown keys are ignored")
    func parsesRecord() throws {
        let record = try #require(LaunchRecord.parse("""
            version=1
            code=access_violation
            exit=5
            seconds=40
            stopped=game
            backend=d3dmetal
            engine=winecx-11.17
            window=12
            ended=1800000000
            future_key=whatever
            """))
        #expect(record.code == "access_violation")
        #expect(record.exit == 5)
        #expect(record.seconds == 40)
        #expect(record.stopped == .game)
        #expect(record.backend == "d3dmetal")
        #expect(record.window == .some(12))
        #expect(record.ended == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(record.verdict == .crashed)
        #expect(LaunchRecord.parse("version=1\nexit=5\n") == nil)
    }

    @Test("Codes become verdicts; an unknown code stops unexpectedly")
    func codes() {
        #expect(LaunchVerdict(code: "ok") == .ok)
        #expect(LaunchVerdict(code: "anticheat_blocked") == .antiCheat)
        #expect(LaunchVerdict(code: "aborted") == .aborted)
        #expect(LaunchVerdict(code: "rosetta_missing") == .rosettaMissing)
        #expect(LaunchVerdict(code: "engine_missing") == .engineMissing)
        #expect(LaunchVerdict(code: "illegal_instruction") == .illegalInstruction)
        #expect(LaunchVerdict(code: "dll_not_found") == .missingFile)
        #expect(LaunchVerdict(code: "sigkill") == .lowMemory)
        #expect(LaunchVerdict(code: "exit_code") == .crashed)
        #expect(LaunchVerdict(code: "anticheat_driver") == .antiCheat)
        #expect(LaunchVerdict(code: "sigterm") == .stoppedOutside)
        #expect(LaunchVerdict(code: "engine_unsupported") == .engineUnsupported)
        #expect(LaunchVerdict(code: "engine_unsupported").beforeLaunch)
        #expect(!LaunchVerdict(code: "launch_services").failed)
        #expect(LaunchVerdict(code: "something_new") == .unexpected)
        #expect(!LaunchVerdict.ok.failed)
        #expect(LaunchVerdict.unexpected.failed)
        #expect(LaunchVerdict.unexpected.sentence == "Stopped unexpectedly.")
    }

    @Test("Steam's Stop is a normal end unless the game never opened a window")
    func stoppedFromSteam() throws {
        let withWindow = try #require(LaunchRecord.parse("code=ok\nstopped=steam\nwindow=8\n"))
        #expect(withWindow.verdict == .stoppedFromSteam)
        let noWindow = try #require(LaunchRecord.parse("code=ok\nstopped=steam\nwindow=\n"))
        #expect(noWindow.verdict == .neverOpenedWindow)
        let unrecorded = try #require(LaunchRecord.parse("code=ok\nstopped=steam\n"))
        #expect(unrecorded.verdict == .stoppedFromSteam)
        // A stop before Wine started keeps its own reason
        let blocked = try #require(LaunchRecord.parse("code=anticheat_blocked\nstopped=steam\nwindow=\n"))
        #expect(blocked.verdict == .antiCheat)
        // The player's Stop before the game started is no failure
        let stopped = try #require(LaunchRecord.parse("code=aborted\nstopped=steam\n"))
        #expect(stopped.verdict == .stoppedFromSteam)
    }

    @Test("Every code the run script writes has its own verdict")
    func everyScriptCode() throws {
        let script = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "../../../dylib/feats/compat_run.sh").standardizedFileURL, encoding: .utf8)
        // exit_outcome's `echo "<code> <stopper>"` lines and the np_outcome= assignments.
        var codes = Set<String>()
        for line in script.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let match = text.firstMatch(of: /echo "([a-z_]+) (steam|game|unknown)"/) { codes.insert(String(match.1)) }
            if let match = text.firstMatch(of: /^np_outcome=([a-z_]+)$/) { codes.insert(String(match.1)) }
        }
        codes.insert("aborted")
        #expect(codes.count > 30)
        for code in codes.sorted() {
            #expect(LaunchVerdict(code: code) != .unexpected, "\(code) has no verdict")
        }
    }

    @Test("Without a record, the run log gives the verdict, including launches that never ran")
    func fromLog() {
        let now = Date()
        func verdict(_ tail: String) -> LaunchVerdict? { LastLaunch.fromLog(Self.header + tail, modified: now)?.verdict }
        #expect(verdict("=== game exited status=5, killing wine prefix ===\n=== exit cause: wine: Unhandled page fault ===\n") == .crashed)
        #expect(verdict("=== termination signal received, killing wine prefix ===\n=== game exited status=143, killing wine prefix ===\n") == .stoppedFromSteam)
        #expect(verdict("=== game exited status=137, killing wine prefix ===\n") == .lowMemory)
        #expect(verdict("=== game exited status=29, killing wine prefix ===\n") == .illegalInstruction)
        #expect(verdict("=== not launched: kernel anti-cheat, the player chose Don't Launch ===\n") == .antiCheat)
        #expect(verdict("=== Rosetta 2 is not installed, Wine cannot run: softwareupdate --install-rosetta --agree-to-license ===\n") == .rosettaMissing)
        #expect(verdict("=== runner is missing x86_64-windows/lsteamclient.dll, set up the runner in Bridgeplay ===\n") == .engineMissing)
        #expect(verdict("=== Wine through FEX did not start: it needs macOS 26.5 or later ===\n=== aborted during rosetta check (exit 1) before launch ===\n") == .engineUnsupported)
        #expect(verdict("=== game exited status=143, killing wine prefix ===\n") == .stoppedOutside)
        #expect(verdict("=== aborted during prefix lock (exit 1) before launch ===\n") == .aborted)
        // Still running: no verdict yet
        #expect(verdict("graphics: backend=d3dmetal\n") == nil)
    }

    @Test("The scan reads every compatdata folder, pfx or not, record first, under three days old")
    func scan() throws {
        let library = try Self.library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let now = Date()

        let crashed = try Self.game("1145360", in: library, name: "Hades")
        try Data("version=1\ncode=access_violation\nexit=5\nseconds=40\nstopped=game\nended=\(Int(now.timeIntervalSince1970) - 60)\n".utf8)
            .write(to: crashed.appending(path: LaunchRecord.fileName))
        // A record wins over the log beside it
        try Data((Self.header + "=== game exited status=0, killing wine prefix ===\n").utf8)
            .write(to: crashed.appending(path: "bridgeplay-run.log"))

        let blocked = try Self.game("1172470", in: library, pfx: false)
        try Data((Self.header + "=== aborted during rosetta check (exit 1) before launch ===\n").utf8)
            .write(to: blocked.appending(path: "bridgeplay-run.log"))

        let old = try Self.game("400", in: library, name: "Portal")
        try Data("code=crash\nended=\(Int(now.timeIntervalSince1970) - 4 * 86400)\n".utf8)
            .write(to: old.appending(path: LaunchRecord.fileName))

        let fine = try Self.game("620", in: library, name: "Portal 2")
        try Data("code=ok\nstopped=game\nseconds=3600\nended=\(Int(now.timeIntervalSince1970) - 30)\n".utf8)
            .write(to: fine.appending(path: LaunchRecord.fileName))

        let found = LastLaunch.scan(libraries: [library], now: now, userdata: library.root.appending(path: "none"))
        #expect(found.map(\.prefix.appID) == ["1172470", "620", "1145360"])
        let hades = try #require(found.first { $0.prefix.appID == "1145360" })
        #expect(hades.prefix.title == "Hades")
        #expect(hades.verdict == .crashed)
        #expect(hades.hasPrefix)
        #expect(hades.duration == "Stopped after 40 s")
        let unnamed = try #require(found.first { $0.prefix.appID == "1172470" })
        #expect(unnamed.verdict == .aborted)
        #expect(!unnamed.hasPrefix)

        let shown = LastLaunchDismissals.visible(found, hidden: [])
        #expect(shown.map(\.prefix.appID) == ["1172470", "1145360"])
        #expect(LastLaunchDismissals.visible(found, hidden: [hades.id]).map(\.prefix.appID) == ["1172470"])
    }

    @Test("Long sessions read in minutes")
    func duration() throws {
        let library = try Self.library()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let prefix = WinePrefix(appID: "1", name: nil, library: library, lastUsed: nil)
        #expect(LastLaunch(prefix: prefix, verdict: .crashed, seconds: 840, ended: Date(), hasPrefix: true).duration == "Stopped after 14 min")
        #expect(LastLaunch(prefix: prefix, verdict: .aborted, seconds: nil, ended: Date(), hasPrefix: false).duration == "Stopped")
    }
}
