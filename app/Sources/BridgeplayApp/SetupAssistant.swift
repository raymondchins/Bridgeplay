import AppKit
import BridgeplayInstallerCore
import BridgeplayUI
import Foundation

// Drives the Setup Assistant: checks first, asks only when a check fails, and runs the
// same installs as the Status page (installIntoSteam, installWinecxEngine) in order.
@MainActor
@Observable
final class SetupAssistant {

    enum Step: Int, CaseIterable, Identifiable {
        case mac, graphics, steam, finish, done
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .mac: String(localized: "Your Mac")
            case .graphics: String(localized: "Graphics")
            case .steam: String(localized: "Steam")
            case .finish: String(localized: "Set Up")
            case .done: String(localized: "Done")
            }
        }
    }

    enum TaskState: Equatable { case waiting, running, done, failed(String) }

    struct SetupTask: Identifiable, Equatable {
        let id: String
        let title: String
        var state: TaskState = .waiting
    }

    static let finishedKey = "setupAssistantFinished"

    var step: Step = .mac
    var isWorking = false
    // "Downloading from …: 3 MB / 5 MB · 1.2 MB/s" while Steam downloads.
    var steamProgress: String?
    var message: String?

    // Mac
    var rosettaInstalled = SetupChecks.rosettaInstalled()
    // Set when the password window was closed; the Rosetta row says so in place of an error.
    var rosettaNote: String?
    let appleSilicon = SetupChecks.isAppleSilicon
    let macOSSupported = SetupChecks.macOSVersion.majorVersion >= SetupChecks.minimumMacOS
    let freeBytes = SetupChecks.freeBytes()

    // Graphics
    var gptk: WinecxD3DMetal.Payload?
    var gptkImages: [URL]
    // "Installing the Game Porting Toolkit" once the components download is done.
    var gptkProgress: String?
    @ObservationIgnored private var componentsRate = DownloadRate()

    // Steam
    var steamInstalled = SteamBundle.isPresent
    var signedIn = SetupChecks.steamSignedIn()
    @ObservationIgnored private var signInWatch: Task<Void, Never>?

    // The keychain identity that keeps Steam's controller permission across updates.
    enum TrustState: Equatable { case unknown, needed, working, done, declined(String) }
    var trust: TrustState = .unknown
    // An older install's identity in the login keychain, which macOS asks about when Steam is signed.
    var trustInLoginKeychain = false

    // Finish
    var tasks: [SetupTask] = SetupAssistant.plannedTasks
    var needsAppManagement = false
    // The tool already set up in Steam, while Setup offers Repair Steam to remove it.
    var needsSteamRepair: String?
    // A repair stopped for App Management, resumed once it's granted.
    @ObservationIgnored private(set) var repairPending = false
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    // Done: two of the settings for every game (GameDefaults); the rest are on the Game Defaults page.
    var metalHUD = GameDefaults.isOn(.metalHUD)
    var highResolution = GameDefaults.isOn(.highResolution)

    nonisolated static let defaultStep = String(localized: "Make WineCX Steam's default")

    static let plannedTasks = [
        SetupTask(id: "steam", title: String(localized: "Add Bridgeplay to Steam")),
        SetupTask(id: "engine", title: String(localized: "Set up the WineCX engine")),
        SetupTask(id: "default", title: defaultStep),
    ]

    // Set by the debug-only --setup-preview window: actions pretend instead of installing,
    // so the assistant can be clicked through on a Mac that is already set up.
    let isPreview: Bool

    init(preview: Preview? = nil, startAt start: Step = .mac) {
        isPreview = preview != nil
        let located = preview == .fresh ? nil : WinecxD3DMetal.locate()
        gptk = located
        gptkImages = preview == .fresh ? [] : GPTKImport.candidatesIfMissing(installed: located != nil)
        if preview == .fresh {
            rosettaInstalled = false
            signedIn = false
            trust = .needed
            metalHUD = false
            highResolution = false
        }
        // The preview can open on a later step; the steps before it count as passed, so a
        // fresh Mac shows step 4 as someone who pressed Trust in step 3 would see it.
        if isPreview, start != .mac {
            step = start
            if start.rawValue > Step.steam.rawValue {
                rosettaInstalled = true
                signedIn = true
                trust = .done
            }
        }
    }

    enum Preview { case thisMac, fresh }

    // The preview only flips the switch; it never writes the real default.conf.
    func setGameDefault(_ setting: GameDefaults.Setting, _ on: Bool) {
        switch setting {
        case .metalHUD: metalHUD = on
        case .highResolution: highResolution = on
        default: return
        }
        guard !isPreview else { return }
        do {
            try GameDefaults.set(setting, to: on)
        } catch {
            message = String(localized: "Bridgeplay could not save this setting. \(error.localizedDescription)")
        }
    }

    private func pretend(_ seconds: Double = 0.9) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // Preview only: runs a download's bar from empty to done in about eight seconds; Pause holds it.
    private func pretendDownload(host: String, total: Int64, _ show: (String?) -> Void) async {
        let meter = DownloadMeter.shared
        for step in 0...40 {
            while meter.paused { await pretend(0.2) }
            let received = total * Int64(step) / 40
            let speed = step > 4 ? Double(total) / 8 : nil
            show(PinnedDownload.Progress.fetching(host: host).label)
            meter.update(host: host, received: received, total: total, speed: speed,
                         remaining: speed.map { Double(total - received) / $0 })
            await pretend(0.2)
        }
        show(nil)
        meter.clear()
    }

    var macReady: Bool { appleSilicon && macOSSupported && rosettaInstalled && hasSpace }
    var hasSpace: Bool { (freeBytes ?? .max) >= SetupChecks.requiredBytes }

    static func shouldShow(_ snapshot: StatusSnapshot?, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: finishedKey), let snapshot else { return false }
        let deployed: Bool = switch snapshot.steam {
        case .installed, .outdated: true
        default: false
        }
        return !(deployed && snapshot.currentFreeEngines.contains(FreeEngineWinecx.current.build))
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        message = nil
        step = next
        if step == .steam {
            watchSignIn()
            Task { await checkTrust() }
        }
    }

    func back() {
        guard step != .finish || !isWorking, let previous = Step(rawValue: step.rawValue - 1) else { return }
        message = nil
        step = previous
    }

    // MARK: Mac

    func installRosetta() async {
        isWorking = true
        defer { isWorking = false }
        rosettaNote = nil
        message = nil
        if isPreview { await pretend(); rosettaInstalled = true; return }
        do {
            try await Task.detached(priority: .userInitiated) { try SetupChecks.installRosetta() }.value
        } catch {
            AppLog.note("setup: Rosetta install failed: \(error.localizedDescription)")
            if SetupChecks.rosettaCancelled(error) {
                rosettaNote = SetupChecks.rosettaFailure(error)
            } else {
                message = SetupChecks.rosettaFailure(error)
            }
        }
        rosettaInstalled = SetupChecks.rosettaInstalled()
    }

    // MARK: Graphics

    func importGPTK(_ image: URL) async {
        // A drop can arrive mid-import, and a second import deletes the first one's staging folder.
        guard !isWorking else { return }
        // The toolkit is copied into the support folder, which the 3.0 move has to find untouched.
        if let refusal = MigrationLaunch.shared.refusal {
            message = refusal
            return
        }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            gptk = try await Task.detached(priority: .userInitiated) { try GPTKImport.importImage(image) }.value
        } catch {
            message = error.localizedDescription
        }
    }

    // The one-click installer's components zip, so the app alone is enough: BridgeplayInstallerCore
    // checks its EdDSA signature and Apple's signature on GPTK, then copies GPTK, the DXMT and
    // DXVK archives and the configs, and installs Steam from Valve when it is missing.
    func downloadGPTK() async {
        if let refusal = MigrationLaunch.shared.refusal {
            message = refusal
            return
        }
        isWorking = true
        defer { isWorking = false; gptkProgress = nil }
        message = nil
        if isPreview {
            await pretendDownload(host: "github.com", total: 504_399_923) { gptkProgress = $0 }
            gptk = WinecxD3DMetal.Payload(libRoot: WinecxD3DMetal.userFolder, version: nil)
            steamInstalled = true
            return
        }
        let meter = DownloadMeter.shared
        let control = InstallerDownloadControl()
        let work = FileManager.default.temporaryDirectory
            .appending(path: "bridgeplay-components-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: work)
            meter.clear()
        }
        do {
            let components = try await InstallerComponents.latest()
            componentsRate = DownloadRate()
            meter.pauseControl = { $0 ? control.pause() : control.resume() }
            let archive = try await components.downloadAcrossRelease(to: work, control: control) { value in
                Task { @MainActor [weak self] in
                    // A report that lands after the download must not bring the bar back.
                    guard let self, self.isWorking, self.gptkProgress == nil else { return }
                    let total = value.total ?? components.length
                    let speed = meter.paused ? nil : self.componentsRate.add(value.received)
                    meter.update(host: components.archiveHost, received: value.received, total: total, speed: speed,
                                 remaining: speed.flatMap { $0 > 0 ? Double(total - value.received) / $0 : nil })
                }
            }
            meter.clear()
            gptkProgress = String(localized: "Installing the Game Porting Toolkit")
            try await Task.detached(priority: .userInitiated) {
                try InstallerComponents.install(archive: archive, work: work, status: { AppLog.note("setup: components: \($0)") })
            }.value
        } catch {
            AppLog.note("setup: components failed: \(error.localizedDescription)")
            // The step's own reason, without the core's generic sentence in front of it.
            let detail = if case InstallerError.componentsFailure(let reason)? = error as? InstallerError { reason }
                else { error.localizedDescription }
            message = String(localized: "The Game Porting Toolkit wasn't added. \(detail)")
        }
        gptk = WinecxD3DMetal.locate()
        steamInstalled = SteamBundle.isPresent
        if gptk != nil { gptkImages = [] }
    }

    // MARK: Steam

    func installSteam() async {
        isWorking = true
        defer { isWorking = false; steamProgress = nil }
        if isPreview {
            await pretendDownload(host: "cdn.cloudflare.steamstatic.com", total: 4_404_019) { steamProgress = $0 }
            steamInstalled = true
            return
        }
        message = nil
        do {
            try await SetupChecks.installSteam { label in Task { @MainActor in self.steamProgress = label } }
        } catch {
            message = String(localized: "Steam wasn't installed. \(error.localizedDescription)")
        }
        steamInstalled = SteamBundle.isPresent
    }

    func openSteam() {
        if isPreview { Task { await pretend(1.5); signedIn = true }; return }
        NSWorkspace.shared.open(SupportPaths.Steam.app)
        watchSignIn()
    }

    private func watchSignIn() {
        signInWatch?.cancel()
        guard !signedIn, !isPreview else { return }
        signInWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if SetupChecks.steamSignedIn() {
                    self.signedIn = true
                    return
                }
            }
        }
    }

    func checkTrust() async {
        guard trust == .unknown else { return }
        let identity = await Task.detached(priority: .utility) { LocalSigning.existing() }.value
        trustInLoginKeychain = identity != nil && identity?.keychain == nil
        if trust == .unknown { trust = identity != nil ? .done : .needed }
    }

    // One click, no password: see LocalSigning for why no prompt is needed. A failure keeps
    // ad hoc signing, which works but loses the controller permission on every update.
    func trustThisMac() async {
        guard trust != .working, trust != .done else { return }
        trust = .working
        if isPreview { await pretend(); trust = .done; return }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try LocalSigning.ensure() }.value
            trustInLoginKeychain = await Task.detached(priority: .utility) { LocalSigning.existing()?.keychain == nil }.value
            trust = .done
        } catch {
            AppLog.note("setup: signing identity not created: \(error.localizedDescription)")
            trust = .declined(Self.untrustedNote)
        }
    }

    static let untrustedNote =
        String(localized: "Not set up. Bridgeplay still works, but after each update you'll need to allow your controller again.")

    // MARK: Finish

    func finish(with status: SystemStatus) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        needsAppManagement = false
        needsSteamRepair = nil
        repairPending = false
        message = nil
        tasks = Self.plannedTasks

        if isPreview {
            for task in Self.plannedTasks {
                set(task.id, .running)
                if task.id == "engine" {
                    await pretendDownload(host: "github.com", total: 461_373_440) { status.activity = $0 }
                } else {
                    await pretend(1.2)
                }
                set(task.id, .done)
            }
            step = .done
            return
        }
        if let refusal = MigrationLaunch.shared.refusal {
            message = refusal
            return
        }

        set("steam", .running)
        await status.installIntoSteam()
        if let failure = status.failure {
            if status.failureRemedy == .appManagement {
                askForAppManagement(status)
            } else if let tool = (status.lastRunError as? SteamInstaller.ForeignInsert)?.tool {
                needsSteamRepair = tool
                set("steam", .failed(String(localized: "\(tool) is already set up in Steam.")))
            } else {
                set("steam", .failed(failure))
            }
            return
        }
        set("steam", .done)

        set("engine", .running)
        await status.installWinecxEngine()
        if let failure = status.failure {
            set("engine", .failed(failure))
            return
        }
        set("engine", .done)

        set("default", .running)
        // Quitting Steam and the config.vdf write stay off the main actor.
        do {
            if let tool = FreeEngineWinecx.current.runner.tools.first?.name {
                try await Task.detached(priority: .userInitiated) { try Self.makeDefault(tool) }.value
            }
            set("default", .done)
        } catch is SteamDefaultTool.SteamRunning {
            set("default", .failed(String(localized: "Quit Steam, then press Try Again.")))
            return
        } catch {
            set("default", .failed(error.localizedDescription))
            return
        }

        UserDefaults.standard.set(true, forKey: Self.finishedKey)
        step = .done
    }

    // Steam rewrites config.vdf when it quits, so this account's Steam is quit first, and
    // only when the default changes. The "steam" task only quits it when it has files to
    // replace. A Steam open in another account does not write this account's config.vdf.
    nonisolated static func makeDefault(
        _ tool: String,
        needsChange: (String) throws -> Bool = { try SteamDefaultTool.needsChange(to: $0) },
        steamOpen: () -> Bool = { SteamBundle.isRunningForThisUser },
        runningBuild: () -> String? = { RunnerInstaller.runningBuild() },
        stop: () throws -> Bool = { try SteamBundle.stopClient(step: defaultStep) },
        write: (String) throws -> Void = { try SteamDefaultTool.set($0) }
    ) throws {
        guard try needsChange(tool) else { return }
        // Quitting Steam can take a running game with it.
        if steamOpen(), let build = runningBuild() {
            throw StepFailure(step: defaultStep,
                              detail: String(localized: "A game or Wine tool is still running on build \(build). Quit it first."))
        }
        do {
            if try stop() { AppLog.note("setup: quit Steam to set its default compatibility tool") }
        } catch is SteamBundle.OpenInAnotherAccount {}
        try write(tool)
    }

    var notStarted: Bool { tasks.allSatisfy { $0.state == .waiting } }
    var failed: Bool { tasks.contains { if case .failed = $0.state { true } else { false } } }

    private func set(_ id: String, _ state: TaskState) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
    }

    // Repair Steam swaps in Valve's bundle, which also needs App Management.
    func repairSteamAndRetry(with status: SystemStatus,
                             repair: @MainActor (SystemStatus) async -> Void = { await $0.repairSteam() }) async {
        guard !isWorking else { return }
        // perform() drops a run that overlaps another without a failure, which would read as success.
        guard !status.isBusy else {
            set("steam", .failed(String(localized: "Bridgeplay is still busy with another task. Try again when it finishes.")))
            return
        }
        isWorking = true
        // A card left from an earlier attempt would hide this attempt's error and its Report button.
        permissionWatch?.cancel()
        permissionWatch = nil
        needsAppManagement = false
        needsSteamRepair = nil
        repairPending = false
        set("steam", .running)
        await repair(status)
        isWorking = false
        if let failure = status.failure {
            if repairFailed(failure, remedy: status.failureRemedy) {
                openAppManagement()
                watchPermission(status)
            }
            return
        }
        await finish(with: status)
    }

    // Shows why a repair failed; true when it waits for App Management and resumes after.
    func repairFailed(_ failure: String, remedy: Remedy?) -> Bool {
        guard remedy == .appManagement else {
            set("steam", .failed(failure))
            return false
        }
        needsAppManagement = true
        repairPending = true
        set("steam", .failed(String(localized: "macOS needs your permission first.")))
        return true
    }

    private func askForAppManagement(_ status: SystemStatus) {
        needsAppManagement = true
        set("steam", .failed(String(localized: "macOS needs your permission first.")))
        openAppManagement()
        watchPermission(status)
    }

    func openAppManagement() {
        if let pane = Remedy.appManagement.settingsPane { Remedy.openSettings(pane) }
    }

    // Retries on its own as soon as macOS lets this app write into Steam.app.
    private func watchPermission(_ status: SystemStatus) {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.needsAppManagement else { return }
                if await self.resumeAfterPermission(status, canWrite: Self.canWriteSteam()) { return }
            }
        }
    }

    // One poll of the watch; false keeps it polling. A pending repair also waits while another
    // run is in flight, since the repair would refuse it and nothing would retry.
    func resumeAfterPermission(_ status: SystemStatus, canWrite: Bool,
                               repair: @MainActor (SystemStatus) async -> Void = { await $0.repairSteam() }) async -> Bool {
        guard canWrite, !(repairPending && status.isBusy) else { return false }
        // Detached first, so the retry's own cancel doesn't stop this task mid-run.
        permissionWatch = nil
        if repairPending {
            await repairSteamAndRetry(with: status, repair: repair)
        } else {
            await finish(with: status)
        }
        return true
    }

    nonisolated static func canWriteSteam(app: URL = SupportPaths.Steam.app) -> Bool {
        let probe = app.appending(path: "Contents/.bridgeplay-write-probe")
        guard FileManager.default.createFile(atPath: probe.path(percentEncoded: false), contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    func openSteamAndClose() {
        guard !isPreview else { return }
        NSWorkspace.shared.open(SupportPaths.Steam.app)
    }

    func dismiss() {
        signInWatch?.cancel()
        permissionWatch?.cancel()
        guard !isPreview else { return }
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
    }
}
