import Foundation
import Testing

@testable import BridgeplayApp

@Suite("One-tap play reports")
struct PlayReportsTests {

    private static let run = """
        === bridgeplay run Tue Oct 20 21:00:00 WIB 2026 ===
        verb=waitforexitandrun
        === game exited status=0, killing wine prefix ===
        === wine prefix killed, session ending ===
        === bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===
        verb=waitforexitandrun
        runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /Users/tester/Library/Application Support/bridgeplay/runners/b
        graphics: backend=d3dmetal
        SteamUser=player_one
        """

    private static func log(_ ending: String) -> String { run + "\n" + ending + "\n" }

    private static func local(_ text: String) -> Date { GameSession.startDate(text)! }

    @Test("The last session is read from the newest run block")
    func lastSession() throws {
        let ended = Self.local("Wed Oct 21 22:05:00 2026")
        let log = Self.log("=== termination signal received, killing wine prefix ===\n=== game exited status=143, killing wine prefix ===")
        let session = try #require(GameSession.last(in: log, modified: ended))
        #expect(session.id == "=== bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===")
        #expect(session.seconds == 2 * 3600 + 5 * 60)
        #expect(session.exitStatus == 143)
        #expect(session.stoppedBySteam)
        #expect(session.inferredStatus(wineLog: nil) == .silver)
    }

    @Test("A run that hasn't finished, or never reached the game, is not a session")
    func unfinished() {
        #expect(GameSession.last(in: Self.run, modified: Date()) == nil)
        #expect(GameSession.last(in: "=== bridgeplay run x ===\n=== aborted during prefix lock (exit 1) before launch ===", modified: Date()) == nil)
        #expect(GameSession.last(in: "no header at all", modified: Date()) == nil)
    }

    @Test("Legacy notproton headers and odd dates still parse")
    func legacyHeader() throws {
        let log = "=== notproton run Fri Oct  9 10:00:00 WIB 2026 ===\n=== game exited status=0, killing wine prefix ===\n"
        let session = try #require(GameSession.last(in: log, modified: Self.local("Fri Oct 9 10:45:00 2026")))
        #expect(session.seconds == 45 * 60)
        let unknown = try #require(GameSession.last(in: "=== bridgeplay run 2026年10月9日 ===\n=== game exited status=0 ===",
                                                    modified: Date()))
        #expect(unknown.started == nil)
        #expect(unknown.inferredStatus(wineLog: nil) == nil)
    }

    @Test("Auto-share infers only clear outcomes")
    func inference() {
        func session(_ minutes: Double, status: Int, steam: Bool = false) -> GameSession {
            let end = Date()
            return GameSession(id: "x", started: end.addingTimeInterval(-minutes * 60), ended: end,
                               exitStatus: status, stoppedBySteam: steam)
        }
        #expect(session(1, status: 5).inferredStatus(wineLog: nil) == .borked)
        #expect(session(1, status: 0).inferredStatus(wineLog: "wine: Unhandled page fault on read access") == .borked)
        #expect(session(45, status: 0).inferredStatus(wineLog: nil) == .silver)
        #expect(session(45, status: 143, steam: true).inferredStatus(wineLog: nil) == .silver)
        #expect(session(45, status: 5).inferredStatus(wineLog: nil) == nil)
        #expect(session(10, status: 0).inferredStatus(wineLog: nil) == nil)
        #expect(session(0.5, status: 0).worthAsking(wineLog: nil))
        #expect(session(0.1, status: 0).inferredStatus(wineLog: nil) == nil)
        #expect(!session(0.5, status: 143, steam: true).worthAsking(wineLog: nil))
        #expect(session(0.5, status: 5).worthAsking(wineLog: nil))
        #expect(!session(60, status: 0).worthAsking(now: Date().addingTimeInterval(4 * 86400), wineLog: nil))
    }

    @Test("A Wine log with a byte that isn't UTF-8 still shows the crash")
    func wineLogWithInvalidByte() throws {
        let dir = try scratchDirectory("wine-log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "bridgeplay-wine.log")
        // A game's Shift-JIS output.
        var bytes = Data("wine: Unhandled page fault on read access\n".utf8)
        bytes.append(contentsOf: [0x83, 0x51, 0x81, 0x5B, 0x83, 0x80, 0x0A])
        try bytes.write(to: log)

        #expect(GameSession.wineCrashed(PrefixLog.text(of: log)))
        #expect(PrefixLog.text(of: dir.appending(path: "missing.log")) == nil)
    }

    @Test("The payload carries the machine, launch and redacted logs")
    func payload() throws {
        let session = GameSession(id: "x", started: Date().addingTimeInterval(-3600), ended: Date(),
                                  exitStatus: 0, stoppedBySteam: false)
        let machine = GameReport.Machine(chip: "Apple M5 Max", memoryBytes: 64 * 1_073_741_824,
                                         macOS: "macOS 27.0", bridgeplay: "3.3.1 (41)")
        let payload = ReportPayload.make(name: "Elden Ring", appID: "1245620", status: .silver, source: .auto,
                                         session: session, log: Self.run, wineLog: String(repeating: "w", count: 400_000),
                                         machine: machine, install: "0F8FAD5B-D9CB-469F-A165-70867728950E")
        #expect(payload.chip == "M5 Max")
        #expect(payload.memory == "64 GB")
        #expect(payload.engine == "WineCX 11.17 (msync, D3DMetal)")
        #expect(payload.backend == "d3dmetal")
        #expect(payload.session == "Session 60 min, exit status 0. Status inferred from the log")
        #expect(payload.log?.contains("player_one") == false)
        #expect(payload.wineLog?.count == ReportPayload.wineLogLimit)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        #expect(json?["status"] as? String == "silver")
        #expect(json?["source"] as? String == "auto")
        #expect(json?["note"] == nil && json?["setup"] == nil, "absent, not null, for older endpoints")
    }

    @Test("The payload carries the player's note and the Mac's setup")
    func payloadNoteAndSetup() {
        var machine = GameReport.Machine(chip: "Apple M4", memoryBytes: 16 * 1_073_741_824,
                                         macOS: "macOS 27.0", bridgeplay: "3.4.1 (42)")
        machine.setup = ["lowPower": "off", "displays": "1: built-in 3024x1964 120 Hz"]
        let make = { (note: String?) in
            ReportPayload.make(name: "MGSV", appID: "287700", status: .bronze, source: .tap, session: .byHand(),
                               log: nil, wineLog: nil, machine: machine, install: "0F8FAD5B-D9CB-469F-A165-70867728950E",
                               note: note)
        }
        #expect(make("  no sound in cutscenes \n").note == "no sound in cutscenes")
        #expect(make("   ").note == nil)
        #expect(make(String(repeating: "x", count: 3000)).note?.count == 1000)
        #expect(make(nil).setup?["lowPower"] == "off")
    }

    @Test("The run script's exit summary says why the game quit")
    func exitSummary() throws {
        let ended = Self.local("Wed Oct 21 20:01:15 2026")
        let quit = Self.log("""
            === game exited status=3, killing wine prefix ===
            === exit summary: exit status 3 after 75s, the game quit by itself (likely abort() in the C runtime or a breakpoint, usually after the game's own error message) ===
            === session health: healthy after 75s ===
            """)
        let session = try #require(GameSession.last(in: quit, modified: ended))
        #expect(session.summary(log: quit, wineLog: nil)
                == "Session 1 min, exit status 3 after 75s, the game quit by itself (likely abort() in the C runtime or a breakpoint, usually after the game's own error message)")

        let crashed = Self.log("""
            === game exited status=5, killing wine prefix ===
            === exit summary: exit status 5 after 12s, the game quit by itself (likely 0xc0000005, an access violation: the game crashed) ===
            === exit cause: wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger... ===
            === exit cause: Unhandled exception: page fault on read access to 0x00000000 in 64-bit code (0x0000000140001234). ===
            """)
        let crash = try #require(GameSession.last(in: crashed, modified: ended))
        #expect(crash.summary(log: crashed, wineLog: "no error lines left in this tail")
                == "Session 1 min, exit status 5 after 12s, the game quit by itself (likely 0xc0000005, an access violation: the game crashed), first Wine error: wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger...")
    }

    @Test("Without an exit summary the status stands, and Wine's first error is redacted")
    func exitWithoutSummary() throws {
        // An earlier run's summary is not this session's.
        let log = """
            === bridgeplay run Tue Oct 20 21:00:00 WIB 2026 ===
            === game exited status=0, killing wine prefix ===
            === exit summary: exit status 0 after 30 min, the game quit normally ===
            === bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===
            === game exited status=53, killing wine prefix ===

            """
        let session = try #require(GameSession.last(in: log, modified: Self.local("Wed Oct 21 20:00:10 2026")))
        #expect(session.exitAccount(in: log) == nil)
        let wineLog = "fixme:a\n0024:err:module:import_dll Library MSVCP140.dll (which is needed by L\"Z:\\\\Users\\\\someone\\\\Game.exe\") not found\n"
        #expect(session.summary(log: log, wineLog: wineLog)
                == "Session 0 min, exit status 53, first Wine error: 0024:err:module:import_dll Library MSVCP140.dll (which is needed by L\"Z:\\\\Users\\\\<user>\\\\Game.exe\") not found")
        #expect(session.summary(log: log, wineLog: "wine: Unhandled exception, no details") == "Session 0 min, exit status 53, first Wine error: wine: Unhandled exception, no details")
        #expect(session.summary(log: log, wineLog: nil) == "Session 0 min, exit status 53")
    }

    @Test("Wine's error lines are found anywhere in the log, once each")
    func wineErrorLines() {
        let log = """
            wine: configuration in L"\\\\??\\\\C:\\\\users\\\\steamuser" has been updated.
            0118:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems
            wine: Call from 00006FFFFFC3A2B8 to unimplemented function api-ms-win-core-foo.dll.Bar, aborting
            wine: Call from 00006FFFFFC3A2B8 to unimplemented function api-ms-win-core-foo.dll.Bar, aborting
            wine client error:3f4: write: Bad file descriptor
            """
        #expect(GameReport.wineErrorLines(in: log[...], limit: 5) == [
            "wine: Call from 00006FFFFFC3A2B8 to unimplemented function api-ms-win-core-foo.dll.Bar, aborting",
            "wine client error:3f4: write: Bad file descriptor",
        ])
        #expect(GameReport.wineErrorLines(in: log[...], limit: 1).count == 1)
    }

    @Test("A crash early in a long Wine log still reaches the report")
    func wineTail() {
        let early = "wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger...\n"
        let log = "fixme:a\n" + early + String(repeating: "trace line\n", count: 50_000) + "last line\n"
        let tail = GameReport.wineTail(log, limit: 1000)
        #expect(tail.count == 1000)
        #expect(tail.hasPrefix("--- Wine error lines from earlier in this log ---\n" + early + "--- end of the log ---\n"))
        #expect(tail.hasSuffix("trace line\nlast line\n"))
        #expect(GameReport.wineTail("short\n", limit: 1000) == "short\n")
        let quiet = String(repeating: "x\n", count: 1000)
        #expect(GameReport.wineTail(quiet, limit: 100) == String(quiet.suffix(100)))

        // A second error just inside the last 1000 characters gives way to the heading, so
        // it moves up into it.
        let late = "wine: could not load late.dll\n"
        let filler = String(repeating: "f", count: 1000 - late.count - 20) + "\n"
        let two = "fixme:a\n" + early + String(repeating: "trace line\n", count: 500) + late + filler
            + String(repeating: "t\n", count: 10)
        let both = GameReport.wineTail(two, limit: 1000)
        #expect(both.count <= 1000)
        #expect(both.contains("wine: could not load late.dll"))
        #expect(both.hasPrefix("--- Wine error lines from earlier in this log ---\n" + early))
        #expect(both.hasSuffix("t\nt\n"))
    }

    @Test("A report says when a newer Bridgeplay was out")
    func newerRelease() throws {
        let name = "latest-release-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LatestRelease.newer(than: "44", defaults: defaults) == nil)
        LatestRelease.record(build: "55", version: "0.7.38", defaults: defaults)
        #expect(LatestRelease.newer(than: "44", defaults: defaults) == "0.7.38 (55)")
        #expect(LatestRelease.newer(than: "55", defaults: defaults) == nil)
        #expect(LatestRelease.newer(than: "56", defaults: defaults) == nil)
        #expect(LatestRelease.newer(than: nil, defaults: defaults) == nil, "an unstamped build")

        var machine = GameReport.Machine(chip: "Apple M2", memoryBytes: 8 * 1_073_741_824,
                                         macOS: "macOS 27.0.1", bridgeplay: "0.7.0 (44)")
        machine.newerRelease = "0.7.38 (55)"
        let session = GameSession(id: "x", started: Date().addingTimeInterval(-27 * 60), ended: Date(),
                                  exitStatus: 0, stoppedBySteam: false)
        let payload = ReportPayload.make(name: "Roboquest", appID: "692890", status: .bronze, source: .tap,
                                         session: session, log: nil, wineLog: nil, machine: machine,
                                         install: "0F8FAD5B-D9CB-469F-A165-70867728950E")
        #expect(payload.session == "Session 27 min, exit status 0. A newer Bridgeplay was out: 0.7.38 (55)")
    }

    @Test("Retina mode is read from the prefix's Mac Driver key")
    func retinaFromUserReg() {
        let on = "WINE REGISTRY Version 2\r\n[Software\\\\Wine\\\\Mac Driver] 1791551861\r\n#time=1dd\r\n\"RetinaMode\"=\"y\"\r\n\r\n[Software\\\\Wine\\\\X] 1\r\n\"RetinaMode\"=\"n\"\r\n"
        #expect(GameReport.retina(on) == "on")
        #expect(GameReport.retina(on.replacingOccurrences(of: "=\"y\"", with: "=\"n\"")) == "off")
        #expect(GameReport.retina("[Software\\\\Wine\\\\X] 1\n\"RetinaMode\"=\"y\"\n") == "off", "another key's RetinaMode doesn't count")
    }

    @Test("Only a Has Issues payload carries its main problem")
    func payloadIssue() {
        let machine = GameReport.Machine(chip: "Apple M1", memoryBytes: 8 * 1_073_741_824,
                                         macOS: "macOS 27.0", bridgeplay: "0.7.39 (56)")
        let make = { (status: ReportStatus) in
            ReportPayload.make(name: "CS2", appID: "730", status: status, source: .tap, session: .byHand(),
                               log: nil, wineLog: nil, machine: machine, install: "0F8FAD5B-D9CB-469F-A165-70867728950E",
                               issue: .performance)
        }
        #expect(make(.bronze).issue == .performance)
        #expect(make(.platinum).issue == nil)
        #expect(make(.borked).issue == nil)
    }
}

// Answers https://report.invalid/<status> with that status; /offline fails like no network.
final class FakeEndpoint: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "report.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.lastPathComponent
        guard let code = Int(path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func sender(_ path: String, queue: URL) -> ReportSender {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeEndpoint.self]
        return ReportSender(endpoint: URL(string: "https://report.invalid/\(path)")!, queue: queue,
                            session: URLSession(configuration: config))
    }
}

@Suite("Play reports reach the endpoint or wait for it")
struct ReportSenderTests {

    private let payload = ReportPayload(appid: "1245620", status: .platinum, install: UUID().uuidString, source: .tap,
                                        name: "Elden Ring", chip: "M5 Max", memory: "64 GB", macos: "macOS 27.0",
                                        version: "3.3.1 (41)", engine: nil, backend: nil, session: "Session 60 min",
                                        log: "log", wineLog: nil)

    private func queued(_ queue: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    @Test("Sent and refused reports leave the queue; offline and server errors stay")
    func outcomes() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        #expect(await FakeEndpoint.sender("201", queue: queue).submit(payload) == .sent)
        #expect(await FakeEndpoint.sender("400", queue: queue).submit(payload) == .dropped)
        #expect(queued(queue).isEmpty)
        #expect(await FakeEndpoint.sender("offline", queue: queue).submit(payload) == .retryLater)
        #expect(await FakeEndpoint.sender("503", queue: queue).submit(payload) == .retryLater)
        #expect(await FakeEndpoint.sender("429", queue: queue).submit(payload) == .retryLater)
        #expect(queued(queue).count == 3)
    }

    @Test("Pending reports are retried once the wait is over")
    func retry() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        _ = await FakeEndpoint.sender("offline", queue: queue).submit(payload)
        let online = FakeEndpoint.sender("201", queue: queue)
        await online.retryPending()
        #expect(queued(queue).count == 1, "retried before the wait was over")
        await online.retryPending(now: Date().addingTimeInterval(16 * 60))
        #expect(queued(queue).isEmpty)
    }

    // Hermetic end to end with bridgeplay-web's mock server:
    //   node test/mock-server.mjs 4322 & BRIDGEPLAY_REPORT_E2E=http://127.0.0.1:4322/api/report swift test …
    @Test("End to end against the local mock endpoint",
          .enabled(if: ProcessInfo.processInfo.environment["BRIDGEPLAY_REPORT_E2E"] != nil))
    func endToEnd() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let endpoint = try #require(ProcessInfo.processInfo.environment["BRIDGEPLAY_REPORT_E2E"].flatMap(URL.init(string:)))
        let session = GameSession(id: "e2e", started: Date().addingTimeInterval(-7200), ended: Date(),
                                  exitStatus: 0, stoppedBySteam: true)
        let log = "SteamUser=player_one\nCaching Steam ID:  76561198012345678\n"
            + "runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at \(NSHomeDirectory())/x\ngraphics: backend=dxmt\n"
        let real = ReportPayload.make(name: "Elden Ring", appID: "1245620", status: .platinum, source: .tap, session: session,
                                      log: log, wineLog: "wine ok", machine: GameReport.thisMac, install: UUID().uuidString)
        let sender = ReportSender(endpoint: endpoint, queue: queue)
        #expect(await sender.submit(real) == .sent)
        #expect(queued(queue).isEmpty)
    }
}

@MainActor
@Suite("The nudge asks once per session")
struct PlayReportsFlowTests {

    private func model(_ path: String, queue: URL, version: String = "3.4.0",
                       defaults: UserDefaults? = nil) -> (PlayReports, UserDefaults) {
        let defaults = defaults ?? UserDefaults(suiteName: "play-reports-\(UUID().uuidString)")!
        return (PlayReports(defaults: defaults, version: version, sender: { FakeEndpoint.sender(path, queue: queue) }), defaults)
    }

    private func found(_ appID: String, minutes: Double, status: Int = 0, ago: Double = 0) -> PlayReports.Found {
        let end = Date().addingTimeInterval(-ago)
        let prefix = WinePrefix(appID: appID, name: "Game \(appID)", library: SteamLibrary(root: URL(filePath: "/tmp/lib")),
                                lastUsed: nil)
        let session = GameSession(id: "run \(appID) \(ago)", started: end.addingTimeInterval(-minutes * 60), ended: end,
                                  exitStatus: status, stoppedBySteam: false)
        return PlayReports.Found(prefix: prefix, session: session, log: "log", wineLog: nil)
    }

    @Test("First answer asks for consent; Not Now and answers aren't asked again")
    func consentAndDismiss() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        reports.handle([found("10", minutes: 90), found("20", minutes: 20)])
        #expect(reports.nudges.count == 2)
        reports.answer(.platinum)
        #expect(reports.consentRequest == .answer(.platinum, note: nil))
        #expect(reports.nudges.count == 2, "nothing is sent before consent")
        reports.consentRequest = nil
        reports.dismiss()
        #expect(reports.nudge?.prefix.appID == "20")
        reports.handle([found("10", minutes: 90), found("20", minutes: 20)])
        #expect(reports.nudges.count == 1, "a dismissed session came back")
    }

    @Test("With consent, one tap sends, moves on and says thanks")
    func oneTap() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        reports.handle([found("10", minutes: 90)])
        reports.answer(.bronze, note: "no sound")
        #expect(reports.consentRequest == .answer(.bronze, note: "no sound"), "the note waits for consent")
        reports.consent(alsoAutoShare: false)
        #expect(reports.nudges.isEmpty)
        #expect(reports.thanking)
        #expect(!reports.autoShare)
    }

    @Test("A game is asked about once per Bridgeplay version, answered or not")
    func oncePerVersion() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, defaults) = model("201", queue: queue)
        reports.consent(alsoAutoShare: false)
        reports.handle([found("10", minutes: 90, ago: 7200), found("20", minutes: 90, ago: 7300)])
        reports.answer(.platinum)
        reports.dismiss()
        #expect(reports.nudges.isEmpty)
        // Played both again, same version: no question.
        reports.handle([found("10", minutes: 60), found("20", minutes: 60)])
        #expect(reports.nudges.isEmpty)
        // After an update both are asked about again.
        let (updated, _) = model("201", queue: queue, version: "3.5.0", defaults: defaults)
        updated.handle([found("10", minutes: 60), found("20", minutes: 60)])
        #expect(Set(updated.nudges.map(\.prefix.appID)) == ["10", "20"])
        #expect(updated.nudge?.prefix.appID == "10", "one card at a time, newest session first")
    }

    @Test("A game that quits cleanly within seconds is asked about once per version")
    func quickCleanExit() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        let quick = found("30", minutes: 0.1, ago: 60)
        #expect(quick.session.worthAsking(wineLog: nil))
        reports.handle([quick])
        #expect(reports.nudge?.prefix.appID == "30")
        reports.dismiss()
        reports.handle([found("30", minutes: 0.1)])
        #expect(reports.nudges.isEmpty, "asked again in the same version")
    }

    @Test("A crash after a Smooth answer asks again in the same version")
    func crashAfterSmooth() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        reports.consent(alsoAutoShare: false)
        reports.handle([found("10", minutes: 90, ago: 7200), found("20", minutes: 90, ago: 7300)])
        reports.answer(.platinum)
        reports.answer(.bronze)
        #expect(reports.lastAnswer("10") == .platinum && reports.lastAnswer("20") == .bronze)
        reports.handle([found("10", minutes: 1, status: 5), found("20", minutes: 1, status: 5, ago: 10)])
        #expect(reports.nudges.map(\.prefix.appID) == ["10"], "only the game that was Smooth is asked again")
        reports.answer(.borked)
        reports.handle([found("10", minutes: 1, status: 5, ago: 20)])
        #expect(reports.nudges.isEmpty, "a second crash after answering Didn't run is not asked")
    }

    @Test("Don't Ask About This Game is permanent, but Report This Game… still asks")
    func neverAsk() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, defaults) = model("201", queue: queue)
        reports.handle([found("10", minutes: 90, ago: 100), found("10", minutes: 90, ago: 200)])
        reports.neverAsk()
        #expect(reports.nudges.isEmpty)
        let (updated, _) = model("201", queue: queue, version: "9.0.0", defaults: defaults)
        updated.handle([found("10", minutes: 90, status: 5)])
        #expect(updated.nudges.isEmpty)
        let prefix = found("10", minutes: 1).prefix
        updated.ask(about: prefix)
        for _ in 0..<50 where updated.nudges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(updated.nudge?.prefix.appID == "10")
    }

    @Test("Auto-share sends once per version, again only for a crash after Smooth")
    func autoShareOncePerVersion() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("503", queue: queue)
        reports.consent(alsoAutoShare: true)
        reports.handle([found("10", minutes: 90, ago: 7200)])
        reports.handle([found("10", minutes: 90, ago: 3600)])
        #expect(reports.nudges.isEmpty)
        #expect(reports.lastAnswer("10") == .silver)
        func queued() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []).count }
        for _ in 0..<50 where queued() < 1 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(queued() == 1, "the second session in the same version was sent too")
    }

    @Test("Verified games are neither asked about nor auto-shared; Report This Game… still asks")
    func verifiedSkipped() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("503", queue: queue)
        reports.verifiedHere = ["10"]
        reports.handle([found("10", minutes: 90), found("20", minutes: 10)])
        #expect(reports.nudges.map(\.prefix.appID) == ["20"])
        reports.consent(alsoAutoShare: true)
        reports.handle([found("10", minutes: 90, ago: 50)])
        #expect(reports.lastAnswer("10") == nil, "a verified game was auto-shared")
        reports.showBulk([found("10", minutes: 90), found("20", minutes: 10)])
        #expect(reports.bulk?.map(\.prefix.appID) == ["20"])
    }

    @Test("Report Your Games… lists every session, newest first, minus answered, Don't Ask and verified")
    func bulkList() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        reports.consent(alsoAutoShare: false)
        reports.handle([found("1", minutes: 90, ago: 10)])
        reports.answer(.platinum)                         // answered for this version
        reports.handle([found("2", minutes: 90, ago: 20)])
        reports.neverAsk()                                // Don't Ask
        reports.verifiedHere = ["3"]
        reports.showBulk([found("5", minutes: 0.2, ago: 30 * 86400), found("1", minutes: 9), found("2", minutes: 9),
                          found("3", minutes: 9), found("4", minutes: 9, ago: 86400)])
        #expect(reports.bulk?.map(\.prefix.appID) == ["4", "5"], "old and short sessions belong in the list too")
    }

    @Test("Bulk answers wait for consent, then go out one by one and count as asked")
    func bulkAnswer() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("503", queue: queue)
        let games = (1...12).map { found(String($0), minutes: 30, ago: Double($0)) }
        reports.handle([games[0]])
        reports.showBulk(games)
        reports.answerBulk(["1"], .bronze)
        #expect(reports.consentRequest == .bulk(["1"], .bronze))
        #expect(reports.bulk?.count == 12)
        reports.consent(alsoAutoShare: false)
        #expect(reports.bulk?.count == 11)
        #expect(reports.nudges.isEmpty, "the card for a game answered in the sheet stays open")
        reports.answerBulk((reports.bulk ?? []).map(\.prefix.appID), .platinum)
        #expect(reports.bulk?.isEmpty == true)
        #expect(reports.lastAnswer("1") == .bronze && reports.lastAnswer("12") == .platinum)
        func queued() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []).count }
        for _ in 0..<100 where queued() < 12 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(queued() == 12)
        reports.showBulk(games)
        #expect(reports.bulk?.isEmpty == true, "answered games came back in the same version")
    }

    @Test("A newer session of the same game replaces the older question")
    func newerSession() throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("201", queue: queue)
        reports.handle([found("10", minutes: 90, ago: 3600)])
        reports.handle([found("10", minutes: 30)])
        #expect(reports.nudges.count == 1)
        #expect(reports.nudge?.session.id == "run 10 0.0")
    }

    @Test("Report This Game… asks now, from the log's last session or by hand")
    func askByHand() async throws {
        let dir = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (reports, _) = model("201", queue: dir.appending(path: "queue"))
        let library = SteamLibrary(root: dir)
        let played = WinePrefix(appID: "10", name: "Played", library: library, lastUsed: nil)
        let never = WinePrefix(appID: "20", name: "Never", library: library, lastUsed: nil)
        try FileManager.default.createDirectory(at: played.root, withIntermediateDirectories: true)
        try "=== bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===\n=== game exited status=0, killing wine prefix ===\n"
            .write(to: PrefixLog.launch.url(for: played), atomically: true, encoding: .utf8)
        reports.ask(about: never)
        reports.ask(about: played)
        for _ in 0..<50 where reports.nudges.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let fromLog = try #require(reports.nudges.first { $0.prefix.appID == "10" })
        #expect(fromLog.session.id == "=== bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===")
        let byHand = try #require(reports.nudges.first { $0.prefix.appID == "20" })
        #expect(byHand.session.byHand)
        #expect(byHand.session.summary(wineLog: nil) == "Reported from the Prefixes page")
    }

    @Test("Auto-share needs consent, then reports clear sessions and asks about the rest")
    func autoShare() async throws {
        let queue = try scratchDirectory("reports")
        defer { try? FileManager.default.removeItem(at: queue) }
        let (reports, _) = model("503", queue: queue)
        reports.setAutoShare(true)
        #expect(reports.consentRequest == .autoShare)
        #expect(!reports.autoShare)
        reports.consent(alsoAutoShare: false)
        #expect(reports.autoShare && reports.hasConsent)

        reports.handle([found("10", minutes: 90), found("20", minutes: 10)])
        #expect(reports.nudges.map(\.prefix.appID) == ["20"], "the unclear session should still be asked about")
        // The endpoint answers 503, so the auto report waits in the queue.
        for _ in 0..<50 where (try? FileManager.default.contentsOfDirectory(atPath: queue.path))?.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(50))
        }
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        let sent = try JSONDecoder().decode(ReportPayload.self, from: Data(contentsOf: try #require(files.first)))
        #expect(sent.appid == "10" && sent.status == .silver && sent.source == .auto)
    }
}

// Answers every request with a copy of compat/games.json, or fails like no network.
final class FakeRawOK: URLProtocol, @unchecked Sendable {
    static let body = """
        [{"appid": 1245620, "status": "platinum", "tested_on": "M5 Max · macOS 27"},
         {"appid": 10, "status": "borked", "reports": [{"chip": "M2", "status": "borked"}, {"device": "M5 Max · macOS 27.0"}]},
         {"appid": 20, "status": "untested", "tested_on": "M5 Max · macOS 27"},
         {"appid": 30, "status": "gold", "tested_on": "M5 · macOS 26"}]
        """
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class FakeRawDown: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
}

@Suite("Games a maintainer verified on a Mac like this one are not asked about")
struct VerifiedGamesTests {

    private func session(_ type: URLProtocol.Type) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [type]
        return URLSession(configuration: config)
    }

    @Test("Chip families come out of free text")
    func chips() {
        #expect(VerifiedGames.chipFamilies(in: "M5 Max · macOS 27") == ["M5 Max"])
        #expect(VerifiedGames.chipFamilies(in: "M2 · 16 GB") == ["M2"])
        #expect(VerifiedGames.chipFamilies(in: "MacBook Pro M3 Ultra") == ["M3 Ultra"])
    }

    @Test("A verified status on the same chip family counts; untested and other chips don't")
    func matching() {
        let data = Data(FakeRawOK.body.utf8)
        #expect(VerifiedGames.verified(on: "M5 Max", in: data) == ["1245620", "10"])
        #expect(VerifiedGames.verified(on: "M5", in: data) == ["30"])
        #expect(VerifiedGames.verified(on: "M2", in: data) == ["10"])
        #expect(VerifiedGames.verified(on: "Other", in: data).isEmpty)
        #expect(VerifiedGames.verified(on: "M5 Max", in: Data("not json".utf8)).isEmpty)
    }

    @Test("Fetched once a day, the cache covers offline, nothing at all means ask as before")
    func cache() async throws {
        let dir = try scratchDirectory("verified")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appending(path: "compat-games.json")
        #expect(await VerifiedGames.load(chip: "M5 Max", cache: cache, session: session(FakeRawDown.self)).isEmpty)
        #expect(await VerifiedGames.load(chip: "M5 Max", cache: cache, session: session(FakeRawOK.self)) == ["1245620", "10"])
        // Fresh: not fetched again, so a dead network changes nothing.
        #expect(await VerifiedGames.load(chip: "M5 Max", cache: cache, session: session(FakeRawDown.self)) == ["1245620", "10"])
        // A day old and the fetch fails: the old copy is used and kept another day.
        let later = Date().addingTimeInterval(2 * 86400)
        #expect(await VerifiedGames.load(chip: "M5 Max", cache: cache, session: session(FakeRawDown.self), now: later) == ["1245620", "10"])
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: cache.path(percentEncoded: false))[.modificationDate] as? Date)
        #expect(abs(touched.timeIntervalSince(later)) < 2)
    }
}
