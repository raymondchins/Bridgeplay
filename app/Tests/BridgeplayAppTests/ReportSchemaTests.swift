import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Report schema 2 carries the Steam build, engine id and the launch's outcome")
struct ReportSchemaTests {

    private let run = """
        === bridgeplay run Thu Oct 22 09:44:35 WIB 2026 ===
        runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /a
        graphics: backend=d3dmetal (auto-detected, the engine has D3DMetal)
        === bridgeplay run Thu Oct 22 09:48:47 WIB 2026 ===
        runner: build winehq-11.15 (WineHQ 11.15 - Rosetta) at /b
        === aborted during prefix build check (exit 1) before launch ===
        """

    private let machine = GameReport.Machine(chip: "Apple M5 Max", memoryBytes: 64 * 1_073_741_824,
                                             macOS: "macOS 27.0", bridgeplay: "0.7.68 (90)")

    private func record(_ text: String) -> LaunchRecord? { LaunchRecord.parse(text) }

    @Test("The engine id is the last launch's, not an aborted one's")
    func engineID() {
        #expect(GameReport.lastLaunch(in: run).id == "winecx-11.17")
        #expect(GameReport.lastLaunch(in: "runner: build winehq-11.15 (WineHQ 11.15) at /b\n").id == "winehq-11.15")
        #expect(GameReport.lastLaunch(in: "runner: build bad/id (X) at /b\n").id == nil)
    }

    @Test("The Steam build and branch are read from the launch record, odd values dropped")
    func steamFacts() {
        let facts = record("code=ok\nsteam_build=1795567705\nsteam_channel=publicbeta\n")
        #expect(facts?.steamBuild == "1795567705" && facts?.steamChannel == "publicbeta")
        let odd = record("code=ok\nsteam_build=1.0 beta\nsteam_channel=a b; rm\n")
        #expect(odd?.steamBuild == nil && odd?.steamChannel == nil)
        #expect(record("code=ok\n")?.steamBuild == nil)
        #expect(GameReport.steamBuild("1795567705") == "1795567705")
        #expect(GameReport.steamBuild("1.0 beta") == nil)
    }

    @Test("A report names the Steam its launch ran under, not the Steam at send time")
    func steamOfTheLaunch() {
        let ended = Date(timeIntervalSince1970: 1_790_000_000)
        let session = GameSession(id: "x", started: nil, ended: ended, exitStatus: 0, stoppedBySteam: false)
        func payload(_ file: String?) -> ReportPayload {
            ReportPayload.make(name: "Game", appID: "1245620", status: .gold, source: .tap, session: session,
                               log: nil, wineLog: nil, machine: machine, install: UUID().uuidString,
                               record: file.flatMap(record))
        }
        let ours = "code=ok\nsteam_build=1795500000\nsteam_channel=stable\nended=\(Int(ended.timeIntervalSince1970))\n"
        #expect(payload(ours).steamBuild == "1795500000" && payload(ours).steamChannel == "stable")
        // A later launch's record ran under another Steam: its facts are not this session's.
        let later = "code=ok\nsteam_build=1795567705\nsteam_channel=publicbeta\nended=\(Int(ended.timeIntervalSince1970) + 3600)\n"
        #expect(payload(later).steamBuild == nil && payload(later).steamChannel == nil)
        // A record from before the run script saved them, or no record: unknown, so left out.
        let older = "code=ok\nended=\(Int(ended.timeIntervalSince1970))\n"
        #expect(payload(older).steamBuild == nil && payload(older).steamChannel == nil)
        #expect(payload(nil).steamBuild == nil)
    }

    @Test("The payload is schema 2 and carries this session's outcome record")
    func payload() throws {
        let ended = Date(timeIntervalSince1970: 1_790_000_000)
        let session = GameSession(id: "x", started: ended.addingTimeInterval(-3600), ended: ended,
                                  exitStatus: 0, stoppedBySteam: false)
        let file = "version=1\ncode=ok\nexit=0\nseconds=3590\nstopped=game\nbackend=d3dmetal\nengine=winecx-11.17\n"
            + "window=14\nsteam_build=1795567705\nsteam_channel=publicbeta\nended=\(Int(ended.timeIntervalSince1970) - 20)\n"
        let payload = ReportPayload.make(name: "Elden Ring", appID: "1245620", status: .gold, source: .tap, session: session,
                                         log: run, wineLog: nil, machine: machine, install: UUID().uuidString,
                                         note: "switched to DXVK", record: record(file), consent: 2, bulk: true)
        #expect(payload.schema == 2)
        #expect(payload.consent == 2)
        #expect(payload.steamBuild == "1795567705" && payload.steamChannel == "publicbeta")
        #expect(payload.engineID == "winecx-11.17")
        #expect(payload.launch == ReportPayload.Launch(record(file), session: session))
        #expect(payload.launch?.code == "ok" && payload.launch?.seconds == 3590 && payload.launch?.window == 14)
        #expect(payload.launch?.noWindow == nil)
        #expect(payload.note == "switched to DXVK")
        let json = try #require(try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
        #expect(json["schema"] as? Int == 2)
        #expect(json["bulk"] as? Bool == true)
        #expect((json["launch"] as? [String: Any])?["code"] as? String == "ok")
    }

    @Test("A record from another launch, or one without a time, is left out")
    func otherLaunch() {
        let ended = Date(timeIntervalSince1970: 1_790_000_000)
        let session = GameSession(id: "x", started: nil, ended: ended, exitStatus: 0, stoppedBySteam: false)
        let later = "code=crashed\nseconds=4\nended=\(Int(ended.timeIntervalSince1970) + 3600)\n"
        #expect(ReportPayload.Launch(record(later), session: session) == nil)
        #expect(ReportPayload.Launch(record("code=crashed\nseconds=4\n"), session: session) == nil)
        #expect(ReportPayload.Launch(nil, session: session) == nil)
        let noWindow = ReportPayload.Launch(record("code=quit_early\nseconds=30\nwindow=\nended=\(Int(ended.timeIntervalSince1970))\n"),
                                            session: session)
        #expect(noWindow?.noWindow == true && noWindow?.window == nil)
        let unwatched = ReportPayload.Launch(record("code=ok\nseconds=30\nended=\(Int(ended.timeIntervalSince1970))\n"),
                                             session: session)
        #expect(unwatched?.noWindow == nil && unwatched?.window == nil)
        let payload = ReportPayload.make(name: "Game", appID: "1", status: .platinum, source: .auto, session: session,
                                         log: nil, wineLog: nil, machine: machine, install: UUID().uuidString)
        #expect(payload.launch == nil && payload.consent == nil && payload.bulk == nil && payload.engineID == nil)
    }

    @Test("A schema 1 body from an older app still decodes for the size check")
    func olderBody() throws {
        let body = #"{"appid":"1","status":"platinum","install":"0F8FAD5B-D9CB-469F-A165-70867728950E","source":"tap","name":"G","chip":"M1","memory":"8 GB","macos":"macOS 26.1","version":"0.7.60 (80)","session":"Session 5 min"}"#
        let decoded = try JSONDecoder().decode(ReportPayload.self, from: Data(body.utf8))
        #expect(decoded.schema == nil && decoded.launch == nil)
    }
}

@MainActor
@Suite("Consent wording is versioned")
struct ReportConsentVersionTests {

    @Test("Agreeing now records version 2; a player who agreed to the first text stays on 1")
    func versions() {
        let defaults = scratchDefaults()
        let reports = PlayReports(defaults: defaults)
        #expect(reports.agreedConsent == nil)
        reports.consent(alsoAutoShare: false)
        #expect(reports.agreedConsent == PlayReports.consentVersion)

        let older = scratchDefaults()
        older.set(true, forKey: "PlayReportsConsent")
        #expect(PlayReports(defaults: older).agreedConsent == 1)
    }
}
