import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Checking Steam in the background")
struct BackgroundCheckTests {

    private static let version = "4.0.90"
    private static let steamBuild = "1795567705"
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        _ mode: BackgroundCheck.Mode = .notify,
        deployment: SteamDeployment = .notInstalled,
        previouslyDeployed: Bool = true,
        steamRunning: Bool = false,
        gameRunning: Bool = false,
        appOpen: Bool = false,
        keeperPaused: Bool = false,
        installBlocked: Bool = false,
        health: HealthReading = .none,
        told: String? = nil,
        lastTry: Date? = nil,
        lastTryFailed: Bool = false
    ) -> BackgroundCheck.Inputs {
        BackgroundCheck.Inputs(
            mode: mode, deployment: deployment, previouslyDeployed: previouslyDeployed,
            steamRunning: steamRunning, gameRunning: gameRunning, appOpen: appOpen,
            keeperPaused: keeperPaused, installBlocked: installBlocked, health: health,
            steamBuild: Self.steamBuild, bundledVersion: Self.version, told: told,
            lastTry: lastTry, lastTryFailed: lastTryFailed, now: Self.now)
    }

    private var removedKey: String {
        BackgroundCheck.noticeKey(.removedBySteam, steamBuild: Self.steamBuild, bundledVersion: Self.version)
    }

    // A support folder fixture the way the dylib leaves it; nothing outside the temp folder.
    private func reading(health mode: String? = nil, paused: Bool = false, steam: String = BackgroundCheckTests.steamBuild) throws -> HealthReading {
        let work = try scratchDirectory("background-check")
        defer { try? FileManager.default.removeItem(at: work) }
        if let mode {
            let json = """
            {"written": 1800000000, "pid": 4242, "patch_build": "90", "steam_build": "\(steam)",
             "mode": "\(mode)", "strikes": 2}
            """
            try Data(json.utf8).write(to: work.appending(path: SteamHealthStore.healthFile))
            try Data(#"{"strikes": 2}"#.utf8).write(to: work.appending(path: SteamHealthStore.bootFile))
        }
        if paused { try SteamHealthStore.setPaused(true, folder: work) }
        return SteamHealthStore.read(folder: work, installedPatch: "90", installedSteam: Self.steamBuild,
                                     isThisUsersSteam: { _ in false })
    }

    @Test("Off, or with the app open, it does nothing and leaves the app's keeper to it")
    func offAndAppOpen() {
        #expect(BackgroundCheck.decide(inputs(.off)) == .skip(.off))
        let open = inputs(.reapply, appOpen: true)
        #expect(BackgroundCheck.decide(open) == .skip(.appOpen))
        #expect(BackgroundCheck.waitsForQuit(.skip(.appOpen), inputs: open))
    }

    @Test("By default a Steam update that removed Bridgeplay is told once, never re-applied")
    func notifiesOnce() {
        let notice = BackgroundCheck.Notice(kind: .removedBySteam, blocker: nil, key: removedKey)
        #expect(BackgroundCheck.decide(inputs()) == .notify(notice))
        #expect(BackgroundCheck.decide(inputs(steamRunning: true)) == .notify(notice))
        #expect(BackgroundCheck.decide(inputs(told: removedKey)) == .skip(.alreadyTold))
        #expect(!BackgroundCheck.waitsForQuit(.notify(notice), inputs: inputs(steamRunning: true)))
        #expect(notice.body.contains("Open Bridgeplay"))
    }

    @Test("A newer Steam or Bridgeplay build is a new notice")
    func newBuildIsNews() {
        let other = BackgroundCheck.noticeKey(.removedBySteam, steamBuild: "1795999999", bundledVersion: Self.version)
        #expect(BackgroundCheck.decide(inputs(told: other)) != .skip(.alreadyTold))
        let older = BackgroundCheck.noticeKey(.removedBySteam, steamBuild: Self.steamBuild, bundledVersion: "4.0.89")
        #expect(BackgroundCheck.decide(inputs(told: older)) != .skip(.alreadyTold))
    }

    @Test("Re-apply mode puts it back only with Steam and every game closed")
    func reappliesWhenClosed() {
        #expect(BackgroundCheck.decide(inputs(.reapply)) == .reapply(.removedBySteam))
        #expect(BackgroundCheck.decide(inputs(.reapply, deployment: .outdated(deployed: "4.0.89", bundled: Self.version)))
                == .reapply(.outdated))

        let steamOpen = inputs(.reapply, steamRunning: true)
        let waiting = BackgroundCheck.decide(steamOpen)
        #expect(waiting == .notify(.init(kind: .removedBySteam, blocker: .steamRunning, key: removedKey)))
        #expect(BackgroundCheck.waitsForQuit(waiting, inputs: steamOpen))
        // Told once, but it keeps waiting for the quit.
        let toldWaiting = inputs(.reapply, steamRunning: true, told: removedKey)
        #expect(BackgroundCheck.decide(toldWaiting) == .skip(.alreadyTold))
        #expect(BackgroundCheck.waitsForQuit(.skip(.alreadyTold), inputs: toldWaiting))

        let game = BackgroundCheck.decide(inputs(.reapply, gameRunning: true))
        #expect(game == .notify(.init(kind: .removedBySteam, blocker: .gameRunning, key: removedKey)))
    }

    @Test("A failed or recent try is not repeated; the failure is told once")
    func failedTry() {
        let failed = BackgroundCheck.decide(inputs(.reapply, told: removedKey, lastTryFailed: true))
        let failedKey = removedKey + "|failed"
        #expect(failed == .notify(.init(kind: .removedBySteam, blocker: .lastTryFailed, key: failedKey)))
        #expect(BackgroundCheck.decide(inputs(.reapply, told: failedKey, lastTryFailed: true)) == .skip(.alreadyTold))
        let recent = BackgroundCheck.decide(inputs(.reapply, lastTry: Self.now.addingTimeInterval(-60)))
        #expect(recent == .notify(.init(kind: .removedBySteam, blocker: .lastTryFailed, key: failedKey)))
        #expect(BackgroundCheck.decide(inputs(.reapply, lastTry: Self.now.addingTimeInterval(-3600))) == .reapply(.removedBySteam))
    }

    @Test("Pause, Repair Steam and a blocked install all win over a Steam update")
    func respectsPause() throws {
        let paused = try reading(paused: true)
        #expect(paused.paused)
        for mode in [BackgroundCheck.Mode.notify, .reapply] {
            #expect(BackgroundCheck.decide(inputs(mode, health: paused)) == .skip(.paused))
            #expect(BackgroundCheck.decide(inputs(mode, keeperPaused: true)) == .skip(.paused))
            #expect(BackgroundCheck.decide(inputs(mode, installBlocked: true)) == .skip(.installBlocked))
        }
    }

    @Test("A tripped breaker for this Steam build stops it; one for an older build does not")
    func respectsBreaker() throws {
        let tripped = try reading(health: "passive")
        #expect(tripped.freshness == .lastStart)
        #expect(BackgroundCheck.decide(inputs(.reapply, health: tripped)) == .skip(.breakerTripped))
        #expect(BackgroundCheck.decide(inputs(.notify, health: tripped)) == .skip(.breakerTripped))

        // Steam updated since: the breaker lets go, so does this check.
        let stale = try reading(health: "passive", steam: "1790000000")
        #expect(stale.freshness == .stale)
        #expect(BackgroundCheck.decide(inputs(.reapply, health: stale)) == .reapply(.removedBySteam))

        let healthy = try reading(health: "active")
        #expect(BackgroundCheck.decide(inputs(.reapply, health: healthy)) == .reapply(.removedBySteam))
    }

    @Test("Steam that carries Bridgeplay, never had it, is foreign or missing is left alone")
    func nothingToDo() {
        for mode in [BackgroundCheck.Mode.notify, .reapply] {
            #expect(BackgroundCheck.decide(inputs(mode, deployment: .installed(version: Self.version))) == .skip(.nothingToDo))
            #expect(BackgroundCheck.decide(inputs(mode, previouslyDeployed: false)) == .skip(.nothingToDo))
            #expect(BackgroundCheck.decide(inputs(mode, deployment: .foreign(insert: "/other.dylib"))) == .skip(.nothingToDo))
            #expect(BackgroundCheck.decide(inputs(mode, deployment: .steamMissing)) == .skip(.nothingToDo))
        }
    }

    @Test("A try that Steam interrupted is not a failure")
    func interruptedTry() {
        #expect(!BackgroundCheck.tryFailed(exitStatus: 0, steamRunningAfter: false))
        #expect(!BackgroundCheck.tryFailed(exitStatus: 1, steamRunningAfter: true))
        #expect(BackgroundCheck.tryFailed(exitStatus: 1, steamRunningAfter: false))
    }

    @Test("The mode is read back, and anything unknown is off")
    func modeDefaults() {
        let defaults = scratchDefaults()
        #expect(BackgroundCheck.mode(defaults) == .off)
        defaults.set("reapply", forKey: BackgroundCheck.modeKey)
        #expect(BackgroundCheck.mode(defaults) == .reapply)
        defaults.set("always", forKey: BackgroundCheck.modeKey)
        #expect(BackgroundCheck.mode(defaults) == .off)
    }
}

@MainActor
@Suite("The background check's login item")
struct BackgroundItemTests {

    private final class FakeService: BackgroundItemService {
        var state: BackgroundItem.State = .off
        var refuses = false
        var registered = 0
        var unregistered = 0

        func register() throws {
            if refuses { throw CocoaError(.featureUnsupported) }
            registered += 1
            state = .on
        }

        func unregister() throws {
            unregistered += 1
            state = .off
        }
    }

    @Test("On registers and records the mode; off records first and unregisters")
    func turnsOnAndOff() throws {
        let defaults = scratchDefaults()
        let service = FakeService()
        defaults.set("old", forKey: BackgroundCheck.toldKey)
        #expect(try BackgroundItem.set(.notify, service: service, defaults: defaults) == .on)
        #expect(BackgroundCheck.mode(defaults) == .notify)
        #expect(defaults.string(forKey: BackgroundCheck.toldKey) == nil)

        // Switching modes does not register twice.
        #expect(try BackgroundItem.set(.reapply, service: service, defaults: defaults) == .on)
        #expect(service.registered == 1)
        #expect(BackgroundItem.current(service: service, defaults: defaults) == .on)

        #expect(try BackgroundItem.set(.off, service: service, defaults: defaults) == .off)
        #expect(BackgroundCheck.mode(defaults) == .off)
        #expect(service.unregistered == 1)
    }

    @Test("A refused registration leaves it off")
    func refusalStaysOff() {
        let defaults = scratchDefaults()
        let service = FakeService()
        service.refuses = true
        #expect(throws: (any Error).self) { try BackgroundItem.set(.notify, service: service, defaults: defaults) }
        #expect(BackgroundCheck.mode(defaults) == .off)
        #expect(BackgroundItem.current(service: service, defaults: defaults) == .off)
    }

    @Test("Waiting for approval in System Settings shows as such; a mode alone is not on")
    func approval() {
        let defaults = scratchDefaults()
        let service = FakeService()
        service.state = .needsApproval
        defaults.set("notify", forKey: BackgroundCheck.modeKey)
        #expect(BackgroundItem.current(service: service, defaults: defaults) == .needsApproval)
        service.state = .off
        #expect(BackgroundItem.current(service: service, defaults: defaults) == .off)
        service.state = .unavailable
        defaults.set("off", forKey: BackgroundCheck.modeKey)
        #expect(BackgroundItem.current(service: service, defaults: defaults) == .unavailable)
    }
}
