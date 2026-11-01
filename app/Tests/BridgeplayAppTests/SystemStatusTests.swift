import Foundation
import Testing

@testable import BridgeplayApp

// Progress reports reach the main actor as separate tasks, so one can arrive after the run
// that issued it has finished. If it takes effect the app looks permanently busy.
@MainActor
@Suite("Run activity")
struct RunActivityTests {

    @Test("A run reports its progress")
    func reportsProgress() {
        let status = SystemStatus()
        let run = status.beginRun("cloning")

        status.report(run, "staging")

        #expect(status.activity == "staging")
        #expect(status.isBusy)
    }

    // isIdle is the single condition every button and every menu item consults, so a
    // refresh that did not count as work would let a second action start on top of it.
    @Test("Nothing may start while a refresh or a run is in flight")
    func idleCoversBothKindsOfWork() {
        let status = SystemStatus()
        #expect(status.isIdle)

        status.isRefreshing = true
        #expect(!status.isIdle)

        status.isRefreshing = false
        let run = status.beginRun("cloning")
        #expect(!status.isIdle)

        status.report(run, "staging")
        #expect(!status.isIdle)

        status.endRun()
        #expect(status.isIdle)
    }

    @Test("A finished run is not busy")
    func finishedRunIsIdle() {
        let status = SystemStatus()
        _ = status.beginRun("cloning")

        status.endRun()

        #expect(status.activity == nil)
        #expect(!status.isBusy)
    }

    // The bug this guards: a report queued before the run ended landed afterwards and set
    // activity again, leaving isBusy true with nothing running and every button disabled.
    @Test("A report that arrives after its run finished is ignored")
    func lateReportCannotResurrectActivity() {
        let status = SystemStatus()
        let run = status.beginRun("cloning")

        status.endRun()
        status.report(run, "finished")

        #expect(status.activity == nil)
        #expect(!status.isBusy)
    }

    @Test("A report from an earlier run cannot disturb the run after it")
    func staleReportDoesNotDisturbTheNextRun() {
        let status = SystemStatus()
        let first = status.beginRun("cloning")
        status.endRun()

        let second = status.beginRun("checking")
        status.report(first, "staging")

        #expect(status.activity == "checking")

        status.report(second, "downloading")
        #expect(status.activity == "downloading")
    }

    @Test("Every report of a run still counts, not just the first")
    func acceptsRepeatedReports() {
        let status = SystemStatus()
        let run = status.beginRun("cloning")

        for label in ["staging", "patching", "finished"] {
            status.report(run, label)
        }

        #expect(status.activity == "finished")
    }
}

@Suite("App version")
struct AppVersionTests {

    // Nothing sets CFBundleShortVersionString yet, so the fallback is what gets recorded as the
    // deployed version. A release shipping without the real version would go unnoticed.
    @Test("The version is never empty")
    func versionIsNeverEmpty() {
        #expect(!AppVersion.bundled.isEmpty)
        #expect(!AppVersion.fallback.isEmpty)
    }
}

// Fixture trees rather than the machine's own /Applications, so the answer does not turn
// on whether the developer happens to have the client installed.
@MainActor
@Suite("Failure remedies")
struct FailureRemedyTests {

    // No .app on it, matching the client's inner bundle, which is the case that made
    // testing the extension the wrong test.
    private func bundle(named name: String = "Inner") throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "np-remedy-\(UUID().uuidString)")
        let app = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents"), withIntermediateDirectories: true
        )
        try Data().write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    private func plainDirectory() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "np-remedy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "compatdata/1649240"), withIntermediateDirectories: true
        )
        return root.appending(path: "compatdata/1649240")
    }

    @Test("A refusal inside a bundle offers the settings pane")
    func insideABundleOffersThePane() throws {
        let target = try bundle().appending(path: "Contents/MacOS/notproton.dylib")
        let status = SystemStatus()

        status.setFailure(WriteRefused(path: target.path(percentEncoded: false)))

        #expect(status.failureRemedy == .appManagement)
        #expect(status.failure?.contains("App Management") == true)
    }

    // The bundle root itself is refused by the repair step, so the walk has to consider the
    // path it was given and not only the directories above it.
    @Test("A refusal of a bundle itself offers the settings pane")
    func theBundleItselfOffersThePane() throws {
        let status = SystemStatus()

        status.setFailure(WriteRefused(path: try bundle().path(percentEncoded: false)))

        #expect(status.failureRemedy == .appManagement)
    }

    @Test("A refusal outside a bundle asks about ownership instead")
    func outsideABundleAsksAboutOwnership() throws {
        let target = try plainDirectory()
        let status = SystemStatus()

        status.setFailure(WriteRefused(path: target.path(percentEncoded: false)))

        #expect(
            status.failureRemedy == .ownership,
            "a prefix the user owns was sent to a permission that cannot write it"
        )
        #expect(status.failureRemedy?.settingsPane == nil)
        #expect(status.failure?.contains("App Management") == false)
    }

    @Test("A plain message does not offer the settings pane")
    func plainFailureOffersNothing() throws {
        let status = SystemStatus()
        status.setFailure(WriteRefused(path: try bundle().path(percentEncoded: false)))

        status.setFailure("No supported copy of CrossOver found.")

        #expect(
            status.failureRemedy == nil,
            "the button outlived the permission failure it belonged to"
        )
    }

    @Test("Clearing a failure clears its remedy")
    func clearingDropsTheRemedy() throws {
        let status = SystemStatus()
        status.setFailure(WriteRefused(path: try bundle().path(percentEncoded: false)))

        status.clearFailure()

        #expect(status.failure == nil)
        #expect(status.failureRemedy == nil)
    }

    // A typo makes URL(string:) return nil and the button do nothing at all, which looks
    // like the app ignoring the click.
    @Test("The settings pane is a URL that names the App Management list")
    func settingsPaneParses() throws {
        let pane = try #require(Remedy.appManagement.settingsPane)

        #expect(pane.scheme == "x-apple.systempreferences")
        #expect(pane.query == "Privacy_AppBundles")
    }
}

// One row for a whole batch, so what it offers has to hold for everything in it.
@Suite("Failure reports")
struct FailureReportTests {

    private func bundlePath() throws -> String {
        let app = URL.temporaryDirectory.appending(path: "np-report-\(UUID().uuidString)/Steam.app")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents"), withIntermediateDirectories: true
        )
        try Data().write(to: app.appending(path: "Contents/Info.plist"))
        return app.path(percentEncoded: false)
    }

    @Test("Nothing refused is no report at all")
    func emptyIsNil() {
        #expect(FailureReport([]) == nil)
    }

    @Test("Refusals that agree offer the remedy they agree on")
    func agreementOffersTheRemedy() throws {
        let report = try #require(
            FailureReport([
                WriteRefused(path: try bundlePath()),
                WriteRefused(path: try bundlePath()),
            ])
        )

        #expect(report.remedy == .appManagement)
    }

    // Sending the user to App Management for a batch it fixes half of leaves the other half
    // failing with the pane already open.
    @Test("Refusals that disagree offer no remedy")
    func disagreementOffersNothing() throws {
        let report = try #require(
            FailureReport([
                WriteRefused(path: try bundlePath()),
                WriteRefused(path: "/Users/nobody/compatdata/1649240"),
            ])
        )

        #expect(report.remedy == nil)
        #expect(report.settingsPane == nil)
    }

    @Test("One failure that is not a refusal withdraws the remedy")
    func anUnrelatedFailureWithdrawsIt() throws {
        let report = try #require(
            FailureReport([
                WriteRefused(path: try bundlePath()),
                StepFailure(step: "Delete prefix", detail: "Portal is running. Quit the game first."),
            ])
        )

        #expect(report.remedy == nil)
    }

    // Every refusal says the same sentence, since none of them names its path.
    @Test("Repeated reasons are said once")
    func repeatedReasonsCollapse() throws {
        let report = try #require(
            FailureReport((1...3).map { _ in WriteRefused(path: "/Users/nobody/prefix") })
        )

        #expect(
            report.message == "Could not write files. Check permissions, make sure your user owns the folder."
        )
    }

    @Test("A path root owns is not blamed on App Management")
    func rootOwnedBeatsAppManagement() throws {
        #expect(Remedy(forPath: "/usr/bin") == .rootOwned(handOver: nil))
        #expect(Remedy(forPath: "/usr/bin").settingsPane == nil)
    }

    @Test("A bundle this account owns still asks for App Management")
    func ownedBundleAsksForAppManagement() throws {
        let root = URL.temporaryDirectory.appending(path: "np-remedy-\(UUID().uuidString)")
        let app = root.appending(path: "Steam.app")
        let inside = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: app.appending(path: "Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Remedy(forPath: inside.path(percentEncoded: false)) == .appManagement)
    }

    @Test("Distinct reasons are all kept")
    func distinctReasonsSurvive() throws {
        let report = try #require(
            FailureReport([
                StepFailure(step: "Delete prefix", detail: "Portal is running."),
                StepFailure(step: "Delete prefix", detail: "Half-Life is running."),
            ])
        )

        #expect(report.message.contains("Portal is running."))
        #expect(report.message.contains("Half-Life is running."))
    }
}

// A user who activates CrossOver after a refresh, then presses the button that was turned
// down, gets the same refusal from a verdict that is no longer true.
@MainActor
@Suite("License freshness")
struct LicenseFreshnessTests {

    private func scratch() -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "np-license-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A bundle with no tie.pub in it, which the check turns down without reading any
    // license file, so the verdict does not depend on what this machine is activated for.
    private func snapshot(
        install: CrossOverInstall?, license: CrossOverLicense.Status?, bridge: URL
    ) -> StatusSnapshot {
        StatusSnapshot(
            steam: .steamMissing,
            steamRunning: false,
            updateBlocked: false,
            crossOver: install.map { [$0] } ?? [],
            crossOverLicense: install.flatMap { i in license.map { [i.id: $0] } } ?? [:],
            runner: .none,
            payload: PayloadInspector.inspect(bridge: bridge)
        )
    }

    @Test("A stale verdict is not what the next action reads")
    func staleVerdictIsReplaced() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let install = CrossOverInstall(
            bundle: root.appending(path: "CrossOver.app"),
            releaseVersion: "20260821",
            support: .supported(SupportedRunners.all[0])
        )
        let status = SystemStatus()
        status.snapshot = snapshot(
            install: install,
            license: CrossOverLicense.Status(
                licensed: true, detail: "CrossOver is activated.",
                diagnostic: "valid license in nowhere"
            ),
            bridge: root
        )

        let fresh = try #require(await status.checkLicense())

        #expect(!fresh.licensed, "the cached verdict was handed back instead of a new one")
        #expect(
            status.snapshot?.crossOverLicense[install.id]?.licensed == false,
            "the dialog would still report the verdict the check replaced"
        )
    }

    // The gates read == false, so an install that cannot be checked at all has to stay nil
    // rather than come back as a refusal and block the button.
    @Test("No usable install leaves nothing to check")
    func nothingToCheck() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let status = SystemStatus()
        status.snapshot = snapshot(
            install: CrossOverInstall(
                bundle: root.appending(path: "CrossOver.app"),
                releaseVersion: nil,
                support: .unreadable
            ),
            license: nil,
            bridge: root
        )

        #expect(await status.checkLicense() == nil)
    }
}

// Four entry points share one answer here. The menu items used to skip it: Install dropped
// the tool without saying so, and Set Up hit the refusal inside RunnerSetup as a failed step.
@Suite("Activation questions")
struct ActivationQuestionTests {

    @Test("An install that would build a tool asks before going ahead unactivated")
    func unactivatedInstallAsks() {
        #expect(
            SystemStatus.activationQuestion(.install, licensed: false, runner: .none)
                == .installUnlicensed
        )
    }

    // The dialog warns that the tool cannot be installed. With one already set up none
    // would have been built, so the warning described something that could not happen.
    @Test("An install asks nothing when the tool it would skip is already set up")
    func installWithToolAsksNothing() {
        #expect(
            SystemStatus.activationQuestion(
                .install, licensed: false, runner: .ready(builds: ["27.0.0.40921"])
            ) == nil
        )
    }

    @Test("An activated install goes straight ahead")
    func activatedInstallProceeds() {
        #expect(SystemStatus.activationQuestion(.install, licensed: true, runner: .none) == nil)
    }

    // Unlike an install there is no reduced version to go ahead with, so this one asks
    // whatever is already set up.
    @Test("Setting up the tool asks whenever CrossOver is unactivated")
    func unactivatedToolAsks() {
        for runner in [RunnerState.none, .ready(builds: ["27.0.0.40921"])] {
            #expect(
                SystemStatus.activationQuestion(.compatibilityTool, licensed: false, runner: runner)
                    == .toolUnlicensed
            )
        }
    }

    @Test("Setting up the tool goes straight ahead when CrossOver is activated")
    func activatedToolProceeds() {
        #expect(
            SystemStatus.activationQuestion(.compatibilityTool, licensed: true, runner: .none)
                == nil
        )
    }

    // A check that could not run is not a refusal. Reading it as one would turn away every
    // user whose CrossOver the app cannot inspect.
    @Test("An install that could not be checked is not treated as a refusal")
    func uncheckedProceeds() {
        #expect(SystemStatus.activationQuestion(.install, licensed: nil, runner: .none) == nil)
        #expect(
            SystemStatus.activationQuestion(.compatibilityTool, licensed: nil, runner: .none) == nil
        )
    }
}

@MainActor
@Suite("Run bookkeeping")
struct PerformTests {

    private func quietStatus() -> SystemStatus {
        let status = SystemStatus()
        status.refreshAfterRun = { _ in }
        return status
    }

    @Test("A run ends carrying what its body said")
    func outcomeComesFromTheBody() async {
        let status = quietStatus()

        await status.perform(from: "Working") { _ in "Done." }

        #expect(status.outcome == "Done.")
        #expect(status.failure == nil)
    }

    @Test("A run with nothing to say leaves no outcome behind")
    func nothingToSayLeavesNoOutcome() async {
        let status = quietStatus()

        await status.perform(from: "Working") { _ in "Done." }
        await status.perform(from: "Working") { _ in nil }

        #expect(status.outcome == nil)
    }

    @Test("A run drops the failure the one before it left")
    func aRunClearsTheEarlierFailure() async {
        let status = quietStatus()
        status.setFailure("Old news.")

        await status.perform(from: "Working") { _ in "Done." }

        #expect(status.failure == nil)
        #expect(status.outcome == "Done.")
    }

    @Test("A body that throws ends the run as a failure and not as an outcome")
    func aThrownErrorIsRecorded() async {
        let status = quietStatus()
        // Left by an earlier run, so a failure has something to clear. Without it the
        // outcome is already nil and the run never has to drop anything.
        await status.perform(from: "Working") { _ in "Done." }

        await status.perform(from: "Working") { _ in
            throw StepFailure(step: "Staging", detail: "disk full")
        }

        #expect(status.failure?.contains("disk full") == true)
        #expect(status.outcome == nil)
    }

    @Test("The opening label is on screen before the body starts")
    func theOpeningLabelIsUpFirst() async {
        let status = quietStatus()
        var seen: String?

        await status.perform(from: "Cloning") { _ in
            seen = status.activity
            return "Done."
        }

        #expect(seen == "Cloning")
    }

    @Test("A run counts as busy until it is over")
    func busyForTheWholeRun() async {
        let status = quietStatus()
        var busyMidRun = false

        await status.perform(from: "Working") { progress in
            progress("Halfway")
            busyMidRun = status.isBusy
            return "Done."
        }

        #expect(busyMidRun)
        #expect(!status.isBusy)
    }

    @Test("A run refreshes the status before it stops counting as busy")
    func refreshesBeforeTheRunEnds() async {
        let status = SystemStatus()
        var busyDuringRefresh: Bool?
        status.refreshAfterRun = { busyDuringRefresh = $0.isBusy }

        await status.perform(from: "Working") { _ in "Done." }

        #expect(busyDuringRefresh == true)
    }
}

@MainActor
@Suite("Choosing where Steam is")
struct SteamChoiceTests {

    private func bundle(_ name: String, identifier: String, in root: URL) throws -> URL {
        let app = root.appending(path: name)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try SteamBundle.writeInfoPlist(["CFBundleIdentifier": identifier], at: app.appending(path: "Contents/Info.plist"))
        return app
    }

    @Test("Another copy of Steam is accepted while the current one is not patched")
    func acceptsSteam() throws {
        let root = try scratchDirectory("steam-choice")
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = try bundle("Steam.app", identifier: SteamRepair.valveIdentifier, in: root)

        #expect(SystemStatus.steamChoiceRefusal(picked, current: SupportPaths.Steam.defaultApp, insert: nil) == nil)
    }

    @Test("An app that is not Steam is refused")
    func refusesOtherApps() throws {
        let root = try scratchDirectory("steam-choice")
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = try bundle("CrossOver.app", identifier: "com.codeweavers.CrossOver", in: root)

        #expect(SystemStatus.steamChoiceRefusal(picked, current: SupportPaths.Steam.defaultApp, insert: nil) != nil)
    }

    @Test("A path with a colon is refused, since it would split DYLD_INSERT_LIBRARIES")
    func refusesColons() throws {
        let root = try scratchDirectory("steam-choice")
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = try bundle("a:b/Steam.app", identifier: SteamRepair.valveIdentifier, in: root)

        #expect(SystemStatus.steamChoiceRefusal(picked, current: SupportPaths.Steam.defaultApp, insert: nil) != nil)
    }

    @Test("Switching is refused while Bridgeplay is installed in the current copy")
    func refusesWhilePatched() throws {
        let root = try scratchDirectory("steam-choice")
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = try bundle("Steam.app", identifier: SteamRepair.valveIdentifier, in: root)
        let current = URL(filePath: "/Applications/Steam.app")
        let insert = "/other.dylib:" + SupportPaths.Steam.deployedDylib(inBundle: current).path(percentEncoded: false)

        #expect(SystemStatus.steamChoiceRefusal(picked, current: current, insert: insert) != nil)
        #expect(SystemStatus.steamChoiceRefusal(picked, current: current, insert: "/other.dylib") == nil)
    }
}
