// Logic behind Status view

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum AppVersion {
    static let fallback = "0.1.0-dev"

    // The label people see: X.Y.Z, or X.Y.Z-beta.N in a beta build. It went from 3.5.0 back to 0.7.0,
    // so it never orders installs.
    static var display: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }

    // What Steam's install records carry and compare (dylib.version, the build record).
    static var bundled: String { deployKey(build: ProductVersion.build, display: display) }

    // "4.0.<build>": the build counter only goes up, and 4 sorts past every 3.x record, so an
    // older app another macOS user still runs sees a newer install and leaves it alone.
    static func deployKey(build: String?, display: String) -> String {
        build.map { "4.0.\($0)" } ?? display
    }

    // A deploy key as people read it: "4.0.44" is "build 44"; older records are versions.
    static func label(deployed: String) -> String {
        guard deployed.hasPrefix("4.0."), let build = Int(deployed.dropFirst(4)) else { return deployed }
        return String(localized: "build \(build)")
    }
}

struct StatusSnapshot: Sendable {
    var steam: SteamDeployment
    var steamRunning: Bool
    var updateBlocked: Bool
    var crossOver: [CrossOverInstall]
    var crossOverLicense: [String: CrossOverLicense.Status] = [:]
    var runner: RunnerState
    var payload: PayloadState
    var installedRunners: [RunnerBuild] = []
    var orphanedRunners: [String] = []
    var damagedRunners: [String] = []
    var installContent: DeploymentContent.Status = .unchecked
    // Free engine builds whose engine tree matches every pin, checked per engine.
    var currentFreeEngines: Set<String> = []
    // The Game Porting Toolkit folder linked into the WineCX engine, when one is.
    var gptkSource: String?

    static func capture(bundledVersion: String) -> StatusSnapshot {
        let installs = CrossOverSource.discover()
        var licenses: [String: CrossOverLicense.Status] = [:]
        for install in installs where install.isUsable {
            licenses[install.id] = CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }

        let runner = RunnerStore.state()
        let installed = RunnerStore.installedBuilds()
        let engines = FreeEngineStatus.capture(installs)

        return StatusSnapshot(
            steam: SteamBundle.deployment(bundledVersion: bundledVersion),
            steamRunning: SteamBundle.isRunning,
            updateBlocked: UpdateBlock.isPresent(),
            crossOver: installs,
            crossOverLicense: licenses,
            runner: runner,
            payload: PayloadInspector.inspect(builds: installed),
            installedRunners: installed,
            orphanedRunners: RunnerStore.orphanedClones(),
            damagedRunners: RunnerStore.damagedClones(),
            installContent: DeploymentContent.current(version: bundledVersion),
            currentFreeEngines: engines.current,
            gptkSource: engines.gptkSource
        )
    }
}

enum FreeEngineState: Sendable, Equatable {
    case missing
    // Unpacked, but not matching every pin of this Bridgeplay: "Update & Set Up".
    case outdated
    case current
}

enum FreeEngineStatus {

    static func buildID(of install: CrossOverInstall) -> String? {
        if case .supported(let build) = install.support { return build.id }
        return nil
    }

    // Each free engine is judged against its own pins.
    static func isCurrent(_ install: CrossOverInstall) -> Bool {
        guard let id = buildID(of: install) else { return false }
        if id == FreeEngine.current.build { return FreeEngine.hasRenderer(root: install.crossOverRoot) }
        if let release = FreeEngineWinecx.release(build: id) {
            return FreeEngineWinecx.hasBackends(root: install.crossOverRoot, release: release)
        }
        return false
    }

    static func capture(_ installs: [CrossOverInstall]) -> (current: Set<String>, gptkSource: String?) {
        var current: Set<String> = []
        var gptk: String?
        for install in installs where install.isFree {
            guard let id = buildID(of: install) else { continue }
            if isCurrent(install) { current.insert(id) }
            if FreeEngineWinecx.release(build: id) != nil, gptk == nil {
                gptk = WinecxD3DMetal.linkedSource(root: install.crossOverRoot)
            }
        }
        return (current, gptk)
    }

    static func state(build: String, installs: [CrossOverInstall], current: Set<String>) -> FreeEngineState {
        if current.contains(build) { return .current }
        return installs.contains { $0.isFree && buildID(of: $0) == build } ? .outdated : .missing
    }
}

@MainActor
@Observable
final class SystemStatus {

    var snapshot: StatusSnapshot?
    var isRefreshing = false
    var activity: String?
    var outcome: String?
    private(set) var highlightedRow: String?
    @ObservationIgnored private var highlightReset: Task<Void, Never>?
    private(set) var failure: String?
    private(set) var failureRemedy: Remedy?

    private var runInFlight = false
    // Tests replace the refresh so a run does not modify the real Steam/support folders
    // if run on an actual user's machine.
    @ObservationIgnored var refreshAfterRun: @MainActor (SystemStatus) async -> Void = { await $0.refresh() }
    private var checkingLicense = false

    var isBusy: Bool { activity != nil || runInFlight || checkingLicense }
    var isIdle: Bool { !isBusy && !isRefreshing }
    // A pending 3.0 folder move blocks every install: anything written now would land in
    // the new folders before the old ones are moved in.
    var canInstall: Bool {
        isIdle && snapshot?.installContent.blocksInstallation != true && !MigrationLaunch.shared.pending
    }

    enum Confirmation: Identifiable, Hashable {
        case replaceSteam
        case blockUpdates
        case installUnlicensed
        case toolUnlicensed
        case removeBuild
        case removeEverything

        var id: Self { self }
    }

    // A second ask replaces the first rather than queueing behind it, so the dialog on screen
    // is always the one that will run if it is confirmed.
    var pendingConfirmation: Confirmation?
    var generation = 0

    func beginRun(_ label: String) -> Int {
        activity = label
        AppLog.note("run begin: \(label)")
        return generation
    }

    func report(_ run: Int, _ label: String) {
        guard run == generation else { return }
        activity = label
        AppLog.note("run step: \(label)")
    }

    func endRun() {
        generation += 1
        activity = nil
        DownloadMeter.shared.clear()
        AppLog.note("run end\(failure == nil ? "" : " (failed)")")
    }

    // What the last run threw, for callers that treat some failures as something else.
    @ObservationIgnored private(set) var lastRunError: Error?

    private func record(_ error: Error) {
        lastRunError = error
        setFailure(error)
        if let refusal = error as? WriteRefused {
            AppLog.note("run failed: cannot write \(refusal.path)")
        } else {
            AppLog.note("run failed: \(error.localizedDescription)")
        }
    }

    func setFailure(_ message: String) {
        failure = message
        failureRemedy = nil
    }

    func setFailure(_ error: Error) {
        let report = FailureReport([error])
        failure = report?.message
        failureRemedy = report?.remedy
    }

    func clearFailure() {
        failure = nil
        failureRemedy = nil
    }

    var usableCrossOver: CrossOverInstall? {
        snapshot?.crossOver.first(where: \.isUsable)
    }

    var usableCrossOvers: [CrossOverInstall] {
        snapshot?.crossOver.filter(\.isUsable) ?? []
    }

    var crossOverRows: [CrossOverRow] {
        guard let snapshot else { return [] }
        var unpatched: [String] = []
        if case .unpatched(let builds, _) = snapshot.runner { unpatched = builds }
        return CrossOverRow.rows(
            installs: snapshot.crossOver,
            licenses: snapshot.crossOverLicense,
            installed: snapshot.installedRunners,
            damaged: snapshot.damagedRunners,
            orphaned: snapshot.orphanedRunners,
            unpatched: unpatched
        )
    }

    var repairSource: CrossOverInstall? {
        let builds = snapshot?.runner.builds ?? []
        for wanted in builds {
            let found = usableCrossOvers.first { install in
                if case .supported(let build) = install.support { return build.id == wanted }
                return false
            }
            if let found { return found }
        }
        return nil
    }

    var setupSource: CrossOverInstall? { repairSource ?? usableCrossOver }

    func checkLicense(for chosen: CrossOverInstall? = nil) async -> CrossOverLicense.Status? {
        guard let install = chosen ?? usableCrossOver else { return nil }
        let status = await Task.detached(priority: .userInitiated) {
            CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }.value
        snapshot?.crossOverLicense[install.id] = status
        return status
    }

    enum Request {
        case install
        case compatibilityTool
    }

    nonisolated static func activationQuestion(
        _ request: Request, licensed: Bool?, runner: RunnerState
    ) -> Confirmation? {
        guard licensed == false else { return nil }
        switch request {
        case .install: return runner == RunnerState.none ? .installUnlicensed : nil
        case .compatibilityTool: return .toolUnlicensed
        }
    }

    func requestInstall(unattended: Bool = false) async {
        guard canInstall else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        if let question = Self.activationQuestion(
            .install,
            licensed: await checkLicense()?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingConfirmation = question
        } else {
            await installIntoSteam(unattended: unattended)
        }
    }

    func requestCompatibilityTool(
        from chosen: CrossOverInstall? = nil, replacingExisting: Bool = false
    ) async {
        guard canInstall else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        let install = chosen ?? setupSource
        if let question = Self.activationQuestion(
            .compatibilityTool,
            licensed: await checkLicense(for: install)?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingConfirmation = question
        } else {
            await setUpRunner(from: install, replacingExisting: replacingExisting)
        }
    }

    private(set) var pendingRemoval: String?

    func requestBuildRemoval(_ build: String) {
        guard canInstall else { return }
        pendingRemoval = build
        pendingConfirmation = .removeBuild
    }

    func cancelBuildRemoval() {
        pendingRemoval = nil
    }

    func removePendingBuild() async {
        guard let build = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(from: RunnerInstaller.removeStep) { _ in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireUnblockedContent()
            let changed = try await Task.detached(priority: .userInitiated) {
                try RunnerInstaller.removeClone(forBuild: build)
            }.value
            let removed = String(localized: "Removed build \(SupportedRunners.displayVersion(forID: build)).")
            return changed && SteamBundle.isRunning ? "\(removed) \(Self.toolsRestartHint)" : removed
        }
    }

    func addCrossOver() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Select a copy of CrossOver.")
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)

        guard panel.runModal() == .OK, let picked = panel.url else { return }

        clearFailure()
        outcome = nil

        guard CrossOverSource.looksLikeCrossOver(picked) else {
            setFailure(String(localized: "\(picked.lastPathComponent) is not a valid copy of CrossOver."))
            AppLog.note("crossOver choice refused: \(picked.path(percentEncoded: false))")
            return
        }

        await refresh()
        if let row = CrossOverRow.listing(CrossOverSource.inspect(bundle: picked), in: crossOverRows) {
            AppLog.note("crossOver already listed: \(picked.path(percentEncoded: false))")
            highlight(row)
            return
        }
        CrossOverSource.addManualBundle(picked)
        AppLog.note("crossOver added: \(picked.path(percentEncoded: false))")
        await refresh()
    }

    func chooseSteam() async {
        let current = SupportPaths.Steam.app
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Select your copy of Steam.")
        panel.directoryURL = current.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = URL(filePath: url.path)

        clearFailure()
        outcome = nil

        guard !CrossOverSource.same(picked, current) else { return }
        if SupportPaths.Steam.isUnreachable(current) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Steam at \(current.path(percentEncoded: false)) isn't connected.")
            alert.informativeText = String(localized: "If Bridgeplay is installed there, it will stay installed. Continue anyway?")
            alert.addButton(withTitle: String(localized: "Continue Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            if let refusal = Self.steamChoiceRefusal(picked, current: current) {
                setFailure(refusal)
                AppLog.note("steam choice refused: \(picked.path(percentEncoded: false))")
                return
            }

            if CrossOverSource.same(picked, SupportPaths.Steam.defaultApp) {
                UserDefaults.standard.removeObject(forKey: SupportPaths.Steam.appPathKey)
            } else {
                UserDefaults.standard.set(picked.path(percentEncoded: false), forKey: SupportPaths.Steam.appPathKey)
            }
        } catch {
            setFailure(error)
            return
        }
        AppLog.note("steam chosen: \(picked.path(percentEncoded: false))")
        await refresh()
    }

    static func steamChoiceRefusal(
        _ picked: URL, current: URL, insert: String? = SteamBundle.currentInsert()
    ) -> String? {
        guard Bundle(url: picked)?.bundleIdentifier == SteamRepair.valveIdentifier else {
            return String(localized: "\(picked.lastPathComponent) is not Steam.")
        }
        guard !picked.path(percentEncoded: false).contains(":") else {
            return String(localized: "Bridgeplay cannot use Steam from a folder with a colon in its name.")
        }
        let deployed = SupportPaths.Steam.deployedDylib(inBundle: current).path(percentEncoded: false)
        if let insert, insert.split(separator: ":").contains(Substring(deployed)) {
            return String(localized: "Bridgeplay is installed in \(current.path(percentEncoded: false)). Use Repair Steam to remove it before choosing another copy of Steam.")
        }
        return nil
    }

    private func highlight(_ row: CrossOverRow) {
        AccessibilityNotification.Announcement(String(localized: "\(row.title) is already listed.")).post()
        highlightReset?.cancel()
        highlightedRow = row.id
        highlightReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.highlightedRow = nil
        }
    }

    func removeFromList(_ install: CrossOverInstall) async {
        guard isIdle else { return }
        clearFailure()
        outcome = nil
        CrossOverSource.removeManualBundle(install.bundle)
        AppLog.note("crossOver removed from list: \(install.id)")
        await refresh()
    }

    private static let toolsRestartHint = String(localized: "Restart Steam to update its list of compatibility tools.")

    private func runnerOutcome(_ result: RunnerSetup.Outcome) -> String {
        if result.stagedNothing { return String(localized: "Compatibility tool is already set up.") }
        guard result.toolsChanged, SteamBundle.isRunning else { return String(localized: "Compatibility tool ready.") }
        return String(localized: "Compatibility tool ready. \(Self.toolsRestartHint)")
    }

    func perform(
        from first: String,
        _ body: (_ progress: @escaping @Sendable (String) -> Void) async throws -> String?
    ) async {
        guard !runInFlight else {
            AppLog.note("run refused: '\(first)' overlaps a run already in flight")
            return
        }
        runInFlight = true
        defer { runInFlight = false }

        clearFailure()
        outcome = nil
        lastRunError = nil
        let run = beginRun(first)
        defer { endRun() }

        do {
            outcome = try await body { label in
                Task { @MainActor in self.report(run, label) }
            }
        } catch {
            record(error)
        }

        await refreshAfterRun(self)
    }

    private func setUpRunner(from install: CrossOverInstall?, replacingExisting: Bool = false) async {
        if let refusal = MigrationLaunch.shared.refusal {
            setFailure(refusal)
            return
        }
        guard let install else {
            setFailure(String(localized: "No supported Wine engine found. Download the free WineHQ or WineCX engine first."))
            AppLog.note("run refused: no supported CrossOver")
            outcome = nil
            return
        }

        await perform(from: RunnerSetup.Phase.cloning.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: replacingExisting) {
                    progress($0.label)
                }
            }.value

            return runnerOutcome(result)
        }
    }

    func freeEngineState(_ build: String) -> FreeEngineState {
        guard let snapshot else { return .missing }
        return FreeEngineStatus.state(
            build: build, installs: snapshot.crossOver, current: snapshot.currentFreeEngines)
    }

    // Downloads the free WineHQ engine and sets the compatibility tool up from it,
    // so no CrossOver install or license is needed.
    func installFreeEngine() async {
        guard canInstall else { return }
        await perform(from: FreeEngine.step) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let install = try await FreeEngine.install { progress($0.label) }
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: true) { progress($0.label) }
            }.value
            return runnerOutcome(result)
        }
    }

    // The same for WineCX. The engine links a Game Porting Toolkit while it is unpacked,
    // and the runner is cloned from it afterwards, so the copy carries the same links.
    func installWinecxEngine() async {
        guard canInstall else { return }
        await perform(from: FreeEngineWinecx.step) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let install = try await FreeEngineWinecx.install { progress($0.label) }
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: true) { progress($0.label) }
            }.value
            return runnerOutcome(result)
        }
    }

    static let rescanStep = "Look for the Game Porting Toolkit"

    // Looks for a Game Porting Toolkit again and links or unlinks it in the WineCX engine
    // and in the runner copied from it, so both always carry the same Direct3D.
    func rescanGameportingToolkit() async {
        guard canInstall else { return }
        await perform(from: Self.rescanStep) { _ in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let found = await Task.detached(priority: .userInitiated) {
                Self.relinkGameportingToolkit()
            }.value
            return found.map { "Game Porting Toolkit linked from \($0)." }
                ?? "Game Porting Toolkit not found."
        }
    }

    nonisolated static func relinkGameportingToolkit(
        engines: URL = SupportPaths.engines,
        runners: URL = SupportPaths.runners,
        roots: [URL] = WinecxD3DMetal.searchRoots()
    ) -> String? {
        // Every WineCX release on disk, engine and runner, so each carries the same Direct3D.
        let trees = FreeEngineWinecx.releases.flatMap { release in
            [SupportPaths.crossOverRoot(inBundle: FreeEngineWinecx.bundle(for: release, engines: engines)),
             SupportPaths.clonedRoot(forBuild: release.build, runners: runners)]
        }
        var linked: String?
        for root in trees {
            if let payload = WinecxD3DMetal.refresh(root: root, roots: roots) {
                linked = linked ?? payload.libRoot.standardizedFileURL.path(percentEncoded: false)
            }
        }
        return linked
    }

    func fetchValveBinaries() async {
        guard canInstall else { return }
        await perform(from: ValveFetcher.Phase.verifying.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await ValveFetcher.run { progress($0.label) }
            return result.wroteNothing ? nil : String(localized: "Downloaded missing components.")
        }
    }

    private static let restartHint = String(localized: "Steam was stopped, so start it again.")

    private static let toolNotActivated =
        String(localized: "The compatibility tool was not set up because CrossOver is not activated.")

    private func requireInstallableContent() async throws {
        try await requireUnblockedContent()
        let running = await Task.detached(priority: .utility) {
            RunnerInstaller.runningBuild() != nil
        }.value
        guard !running else {
            throw StepFailure(step: SteamInstaller.step, detail: String(localized: "A game or Wine tool is running. Quit it before updating Bridgeplay."))
        }
    }

    private func requireUnblockedContent() async throws {
        let version = AppVersion.bundled
        let content = await Task.detached(priority: .utility) {
            DeploymentContent.current(version: version)
        }.value
        snapshot?.installContent = content
        guard !content.blocksInstallation else {
            throw StepFailure(step: SteamInstaller.step,
                              detail: String(localized: "Installation is blocked. Refresh Status and use the Bridgeplay app that installed this build."))
        }
    }

    // unattended: nobody pressed anything, so a Steam that opened since the decision to
    // install is left running and the install stops instead.
    func installIntoSteam(unattended: Bool = false) async {
        if let refusal = MigrationLaunch.shared.refusal {
            setFailure(refusal)
            AppLog.note("run refused: install waits for the 3.0 folder move")
            return
        }
        await perform(from: InstallPhase.checkingPayload.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let stopClient = unattended ? SteamInstaller.leaveTheClient : SteamInstaller.stopTheClient
            let result = try await Task.detached(priority: .userInitiated) {
                // Only an install that changed Steam's signature tried a reset, so only it decides.
                try SteamInstaller.run(holdingInstallationLock: true, stopClient: stopClient,
                                       onInputReset: { failed in
                                           Task { @MainActor in self.controllerResetFailures = failed }
                                       },
                                       report: { progress($0.label) })
            }.value

            var parts = [String(localized: "Bridgeplay successfully installed.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            let install = usableCrossOver
            let state = await Task.detached(priority: .userInitiated) {
                (runner: RunnerStore.state(),
                 payload: PayloadInspector.inspect(),
                 license: install.map { CrossOverLicense.check(crossOverRoot: $0.crossOverRoot) })
            }.value

            if let install, state.license?.licensed == true, state.runner == .none {
                progress(String(localized: "Setting up compatibility tool"))
                // A tool that came up is the expected case and goes unsaid. Failure
                // throws, and an unactivated CrossOver is reported below.
                _ = try await Task.detached(priority: .userInitiated) {
                    try RunnerSetup.run(from: install) { progress($0.label) }
                }.value
            } else if install != nil, state.license?.licensed == false, state.runner == .none {
                // Not a failure, Bridgeplay was installed but without a compatibility tool
                parts.append(Self.toolNotActivated)
            }

            // Fetch binaries from Valve
            let valve = try ValvePackageManifest.bundled()
            let needsValve = await Task.detached(priority: .utility) {
                valve.files.contains { Digest.sha256IfPresent(SupportPaths.bridge.appending(path: $0.bridgePath)) != $0.sha256 }
            }.value
            if needsValve {
                progress(String(localized: "Downloading missing components"))
                _ = try await ValveFetcher.run { progress($0.label) }
            }

            try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.finish(result)
            }.value

            return parts.joined(separator: " ")
        }
        if failure == nil {
            UserDefaults.standard.removeObject(forKey: SteamPatchKeeper.pausedKey)
        }
    }

    // MARK: Controller permission

    static let inputMonitoringPane =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    static func openInputMonitoring() {
        AppLog.note("opening Input Monitoring settings")
        NSWorkspace.shared.open(inputMonitoringPane)
    }

    private static let controllerResetFailuresKey = "steamInputResetFailures"

    // What macOS refused to reset after the last install changed Steam's signature. Kept
    // across launches: until it is fixed, controllers stay silently blocked.
    var controllerResetFailures: [String] = UserDefaults.standard.stringArray(forKey: SystemStatus.controllerResetFailuresKey) ?? [] {
        didSet {
            if controllerResetFailures.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.controllerResetFailuresKey)
            } else {
                UserDefaults.standard.set(controllerResetFailures, forKey: Self.controllerResetFailuresKey)
                AppLog.note("controller permission: macOS kept \(controllerResetFailures.joined(separator: ", ")) for Steam")
            }
        }
    }

    // MARK: Signing identity

    // nil until checked.
    private(set) var signingIdentityReady: Bool?

    func refreshSigningIdentity() async {
        signingIdentityReady = await Task.detached(priority: .utility) { LocalSigning.existing() != nil }.value
    }

    func trustThisMac() async {
        guard isIdle else { return }
        await perform(from: LocalSigning.step) { _ in
            _ = try await Task.detached(priority: .userInitiated) { try LocalSigning.ensure() }.value
            return String(localized: "Bridgeplay is trusted on this Mac. Controllers keep their permission after the next update.")
        }
        await refreshSigningIdentity()
    }

    // MARK: Keeping Bridgeplay in Steam

    var patchBanner: SteamPatchKeeper.Banner?
    @ObservationIgnored private var lastPatchCheck: Date?
    @ObservationIgnored private var lastAutoReapply: Date?
    @ObservationIgnored private var autoReapplyFailed = false

    // Called at launch, when the app comes to the front and every few minutes. Re-applies
    // Bridgeplay on its own only while Steam and every game are closed; otherwise it shows
    // a banner with one button.
    func checkSteamPatch(trigger: String, setupShowing: Bool = false, now: Date = Date()) async {
        if let last = lastPatchCheck, now.timeIntervalSince(last) < SteamPatchKeeper.checkInterval { return }
        guard isIdle, !setupShowing else { return }
        lastPatchCheck = now
        let version = AppVersion.bundled
        let seen = await Task.detached(priority: .utility) { SteamPatchKeeper.capture(bundledVersion: version) }.value
        let decision = SteamPatchKeeper.decide(SteamPatchKeeper.Inputs(
            deployment: seen.deployment,
            previouslyDeployed: seen.previouslyDeployed,
            steamRunning: seen.steamRunning,
            gameRunning: seen.gameRunning,
            paused: UserDefaults.standard.bool(forKey: SteamPatchKeeper.pausedKey),
            installBlocked: snapshot?.installContent.blocksInstallation == true,
            lastAttempt: lastAutoReapply,
            lastAttemptFailed: autoReapplyFailed,
            now: now))

        switch decision {
        case .nothing:
            if patchBanner != nil { AppLog.note("patch keeper (\(trigger)): Steam carries Bridgeplay again") }
            patchBanner = nil
            autoReapplyFailed = false
        case .ask(let kind, let blocker):
            let banner = SteamPatchKeeper.Banner(kind: kind, blocker: blocker)
            if banner != patchBanner { AppLog.note("patch keeper (\(trigger)): \(kind) waits, \(blocker)") }
            patchBanner = banner
        case .reapply(let kind):
            guard isIdle else { return }
            AppLog.note("patch keeper (\(trigger)): re-applying on its own, \(kind)")
            lastAutoReapply = now
            await installIntoSteam(unattended: true)
            if lastRunError is SteamInstaller.ClientStarted {
                // Not a failure: Steam opened in the meantime, so ask as if it had been open.
                AppLog.note("patch keeper (\(trigger)): Steam opened before re-applying, asking instead")
                clearFailure()
                patchBanner = SteamPatchKeeper.Banner(kind: kind, blocker: .steamRunning)
                return
            }
            settleReapply(kind)
        }
    }

    func reapplyFromBanner() async {
        guard isIdle, let banner = patchBanner, banner.canApply else { return }
        AppLog.note("patch keeper: re-applying on request, \(banner.kind)")
        let wasRunning = await Task.detached(priority: .userInitiated) { SteamBundle.isRunning }.value
        await installIntoSteam()
        settleReapply(banner.kind)
        if failure == nil, wasRunning {
            let stillRunning = await Task.detached(priority: .userInitiated) { SteamBundle.isRunning }.value
            if !stillRunning { NSWorkspace.shared.open(SupportPaths.Steam.app) }
        }
    }

    private func settleReapply(_ kind: SteamPatchKeeper.Kind) {
        autoReapplyFailed = failure != nil
        if autoReapplyFailed {
            AppLog.note("patch keeper: re-apply failed")
            patchBanner = SteamPatchKeeper.Banner(kind: kind, blocker: .lastTryFailed)
        } else {
            patchBanner = nil
            outcome = kind == .removedBySteam
                ? String(localized: "Steam updated, so Bridgeplay put itself back into Steam.")
                : String(localized: "Bridgeplay updated its files in Steam.")
        }
    }

    func setUpdateBlock(_ blocked: Bool) async {
        await perform(from: blocked ? String(localized: "Blocking Steam client updates")
                                    : String(localized: "Allowing Steam client updates")) { _ in
            if blocked {
                try UpdateBlock.write()
                return String(localized: "Steam client updates are blocked.")
            }

            try UpdateBlock.remove()
            return String(localized: "Steam client updates are allowed.")
        }
    }

    func repairSteam() async {
        await perform(from: RepairPhase.checking.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try await SteamRepair.run(report: { progress($0.label) })
            UserDefaults.standard.set(true, forKey: SteamPatchKeeper.pausedKey)
            AppLog.note("patch keeper: paused until Bridgeplay is installed again")

            var parts = [String(localized: "Steam restored to its original state.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            return parts.joined(separator: " ")
        }
    }

    func resetControllerPermission() async {
        await perform(from: String(localized: "Resetting Steam's controller permission")) { _ in
            let failed = SteamInstaller.failedInputAccessResets()
            controllerResetFailures = failed
            guard failed.isEmpty else {
                throw StepFailure(
                    step: String(localized: "Reset controller permission"),
                    detail: String(localized: "macOS did not reset \(failed.joined(separator: ", ")) for Steam.")
                )
            }
            return SteamBundle.isRunning
                ? String(localized: "Controller permission reset. Restart Steam so macOS asks again.")
                : String(localized: "Controller permission reset. macOS asks again when Steam starts.")
        }
    }

    func removeEverything() async {
        await perform(from: UninstallPhase.stoppingClient.label) { progress in
            let result = try await Uninstall.run(leftovers: .live) { progress($0.label) }

            let summary = result.partialRemoval ?? (result.steamNeedsRedownload
                ? String(localized: "Bridgeplay has been removed. Steam could not be restored. Reinstall Steam from steampowered.com before using it again.")
                : String(localized: "Bridgeplay has been removed."))
            return [summary, result.keptGamefixesNote].compactMap { $0 }.joined(separator: " ")
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let version = AppVersion.bundled
        let captured = await Task.detached(priority: .userInitiated) {
            StatusSnapshot.capture(bundledVersion: version)
        }.value
        snapshot = captured
        AppLog.note(captured)
        if !captured.installContent.blocksInstallation { CJKFonts.fetchIfNeeded() }
        await refreshSigningIdentity()
        await refreshRunnerStorage(cleanTemplates: !captured.installContent.blocksInstallation)
    }

    private(set) var runnerSizes: [String: Int64] = [:]
    private(set) var templateSizes: [String: [CompatTool.Flavor: Int64]] = [:]
    private(set) var templateCleanupFailure: String?
    private(set) var bridgeCopyBytes: Int64 = 0

    func refreshRunnerStorage(
        runners: URL = SupportPaths.runners, libraries: [SteamLibrary] = PrefixStore.libraries(),
        cleanTemplates: Bool = true,
        acquireInstallationLock: @escaping @Sendable () throws -> DeploymentContent.InstallationLock = {
            try DeploymentContent.acquireInstallationLock()
        }
    ) async {
        let known = runnerSizes
        let measured = await Task.detached(priority: .utility) {
            let failures: [StepFailure]
            if cleanTemplates, let lock = try? acquireInstallationLock() {
                defer { lock.release() }
                RunnerInstaller.removeLeftoverRemovals(runners: runners)
                failures = RunnerInstaller.removeStalePrefixTemplates(
                    runners: runners, libraries: libraries, reportBusy: false)
            } else {
                failures = []
            }
            var sizes: [String: Int64] = [:]
            var templates: [String: [CompatTool.Flavor: Int64]] = [:]
            let bridgeCopies = libraries.reduce(Int64(0)) { total, library in
                let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                var info = stat()
                guard lstat(folder.path(percentEncoded: false), &info) == 0,
                    info.st_mode & S_IFMT == S_IFDIR else { return total }
                return total + PrefixStore.directoryBytes(
                    folder.appending(path: SupportPaths.bridgeCacheFolder), metric: .allocated)
            }
            for build in RunnerStore.clonedBuilds(in: runners) {
                sizes[build] = known[build] ?? RunnerStore.cloneSize(forBuild: build, runners: runners)
                templates[build] = libraries.reduce(into: [:]) { totals, library in
                    let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    var info = stat()
                    guard lstat(folder.path(percentEncoded: false), &info) == 0,
                        info.st_mode & S_IFMT == S_IFDIR else { return }
                    for flavor in CompatTool.Flavor.allCases {
                        let template = SupportPaths.prefixTemplate(forBuild: build, flavor: flavor, in: library)
                        totals[flavor, default: 0] += PrefixStore.directoryBytes(template, metric: .allocated)
                    }
                }
            }
            return (sizes, templates, failures, bridgeCopies)
        }.value
        runnerSizes = measured.0
        templateSizes = measured.1
        templateCleanupFailure = measured.2.isEmpty ? nil : measured.2.map(\.detail).joined(separator: "\n")
        bridgeCopyBytes = measured.3
    }
}
