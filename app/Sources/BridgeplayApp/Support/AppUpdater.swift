import AppKit
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {

    // One updater for the app: the menu and the Status page's Refresh share it.
    static let shared = AppUpdater()

    private(set) var flow = UpdateFlow()
    // What the running build brought, until it is dismissed.
    private(set) var whatsNew: WhatsNew?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    // Sparkle holds its delegates weakly.
    @ObservationIgnored private let finder: ReleaseFinder
    @ObservationIgnored private var sessionObservation: NSKeyValueObservation?
    // Sparkle's own install-and-relaunch for an update waiting for quit.
    @ObservationIgnored private var installNow: (() -> Void)?

    init() {
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = true
        #endif
        finder = ReleaseFinder()
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: finder,
            userDriverDelegate: finder
        )
        finder.report = { [weak self] in self?.flow.apply($0) }
        finder.installerReady = { [weak self] in self?.installNow = $0 }
        whatsNew = LatestRelease.takeWhatsNew(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        // Async because Sparkle changes this mid-way through closing a session.
        sessionObservation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.runQueuedCheck() }
            }
        }
    }

    // Sparkle ignores checkForUpdates during a session, and a download started in the
    // background is one, so a click here has to be answered or kept for later.
    func check() {
        #if !DEBUG
        let updater = controller.updater
        switch flow.click(busy: updater.sessionInProgress && !updater.canCheckForUpdates) {
        case .run: controller.checkForUpdates(nil)
        case .focus: controller.userDriver.showUpdateInFocus()
        case .wait: showMainWindow()
        }
        #endif
    }

    // One click, no window. A running game is left alone: the update waits for quit instead.
    func restartToUpdate(busy: Bool) async {
        await refreshRestartBlock()
        switch flow.restart(busy: busy, canInstallNow: installNow != nil) {
        case .install: installNow?()
        case .offer: check()
        case .blocked: break
        }
    }

    func refreshRestartBlock() async {
        flow.apply(.gameRunning(await RestartGuard.gameRunning()))
    }

    func dismissWhatsNew() {
        whatsNew = nil
    }

    private func runQueuedCheck() {
        guard controller.updater.canCheckForUpdates, flow.takeQueuedCheck() else { return }
        controller.checkForUpdates(nil)
    }

    // The banner lives in the main window, which may be minimized when the menu is used.
    private func showMainWindow() {
        NSApp.activate()
        let window = NSApp.windows.first {
            !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.sheetParent == nil
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

}

@MainActor
private final class ReleaseFinder: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    var report: ((UpdateEvent) -> Void)?
    var installerReady: ((@escaping () -> Void) -> Void)?

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        report?(.cycleStarted(byUser: updateCheck == .updates))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        LatestRelease.record(build: item.versionString, version: item.displayVersionString, notes: item.itemDescription)
        report?(.found(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        report?(.downloading(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        report?(.preparing(version: item.displayVersionString))
    }

    // True keeps the install block for Restart to Update. It also holds this session open
    // until quit, so no more checks run; Sparkle still installs on quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installerReady?(immediateInstallHandler)
        report?(.ready(version: item.displayVersionString))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        report?(.cycleFinished)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // A background update never opens a window; the banner is the reminder.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        report?(.reminder(version: update.displayVersionString, downloaded: state.stage != .notDownloaded))
    }

    func standardUserDriverWillFinishUpdateSession() {
        report?(.updateClosed)
    }
}

// Where an update has got to.
enum UpdateStage: Equatable, Sendable {
    case idle
    case checking
    case available(version: String)
    case downloading(version: String)
    case preparing(version: String)
    case ready(version: String)
}

enum UpdateEvent: Equatable, Sendable {
    case cycleStarted(byUser: Bool)
    case found(version: String)
    case downloading(version: String)
    case preparing(version: String)
    case ready(version: String)
    case reminder(version: String, downloaded: Bool)
    case updateClosed
    case cycleFinished
    case gameRunning(Bool)
}

// Background sessions have no window of their own, so this is what the banner shows and
// what decides where a click on Check for Updates goes.
struct UpdateFlow: Equatable, Sendable {
    enum Click: Equatable, Sendable {
        case run
        // Sparkle's own window is up; bring it forward.
        case focus
        // A background session is running, and the banner shows how far it has got.
        case wait
    }

    enum Restart: Equatable, Sendable {
        case install
        // No installer to call, so Sparkle's window offers the install.
        case offer
        case blocked
    }

    private(set) var stage = UpdateStage.idle
    private(set) var checkQueued = false
    private(set) var gameRunning = false
    private var userSession = false

    private var isReady: Bool {
        if case .ready = stage { true } else { false }
    }

    // What the banner shows. A background check that finds nothing stays out of sight unless
    // someone is waiting for it.
    var notice: UpdateStage? {
        switch stage {
        case .idle, .checking: checkQueued ? .checking : nil
        default: stage
        }
    }

    mutating func apply(_ event: UpdateEvent) {
        switch event {
        case .cycleStarted(let byUser):
            userSession = byUser
            if !byUser, !isReady { stage = .checking }
        case .found(let version):
            if !userSession, !isReady { stage = .available(version: version) }
        case .downloading(let version):
            if !userSession, !isReady { stage = .downloading(version: version) }
        case .preparing(let version):
            if !userSession, !isReady { stage = .preparing(version: version) }
        case .ready(let version):
            stage = .ready(version: version)
            // This session now lasts until quit, and the banner is the answer to the click.
            checkQueued = false
        case .reminder(let version, let downloaded):
            stage = downloaded ? .ready(version: version) : .available(version: version)
        case .updateClosed:
            if case .available = stage { stage = .idle }
        case .cycleFinished:
            userSession = false
            if !isReady { stage = .idle }
        case .gameRunning(let running):
            gameRunning = running
        }
    }

    func restart(busy: Bool, canInstallNow: Bool) -> Restart {
        if busy || gameRunning { return .blocked }
        return canInstallNow ? .install : .offer
    }

    mutating func click(busy: Bool) -> Click {
        guard busy else {
            userSession = true
            return .run
        }
        if isReady { return .wait }
        if userSession { return .focus }
        checkQueued = true
        return .wait
    }

    mutating func takeQueuedCheck() -> Bool {
        guard checkQueued else { return false }
        checkQueued = false
        userSession = true
        return true
    }
}

// The newest release Sparkle has found, so a play report can say the player was behind.
enum LatestRelease {
    static let buildKey = "LatestReleaseBuild"
    static let versionKey = "LatestReleaseVersion"
    static let notesKey = "LatestReleaseNotes"
    static let whatsNewShownKey = "WhatsNewShownBuild"

    static func record(build: String, version: String, notes: String? = nil, defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: buildKey)
        defaults.set(version, forKey: versionKey)
        defaults.set(notes, forKey: notesKey)
    }

    // The build before this one recorded the notes when it found the update, so a first
    // install or a build that never saw its own release shows nothing. Asks once per build.
    static func takeWhatsNew(build: String?, defaults: UserDefaults = .standard) -> WhatsNew? {
        guard let build, defaults.string(forKey: buildKey) == build,
              defaults.string(forKey: whatsNewShownKey) != build,
              let version = defaults.string(forKey: versionKey) else { return nil }
        defaults.set(build, forKey: whatsNewShownKey)
        return WhatsNew(version: version, changes: changes(in: defaults.string(forKey: notesKey) ?? ""))
    }

    // Release notes are the release's commit subjects. Keeps what a player would notice.
    static func changes(in notes: String) -> [String] {
        let subject = /^(?<type>[a-z]+)(\([^)]*\))?!?:\s*(?<text>.+)$/
        let hidden: Set<Substring> = ["build", "chore", "ci", "docs", "refactor", "style", "test"]
        return notes.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- ") else { return nil }
            text.removeFirst(2)
            if let match = text.wholeMatch(of: subject) {
                if hidden.contains(match.output.type) { return nil }
                text = String(match.output.text)
            }
            text = text.replacing(/\s*\(#\d+\)$/, with: "")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    // "0.7.38 (55)" when the release found is newer than `build`; releases are ordered by
    // build, never by the version label.
    static func newer(than build: String?, defaults: UserDefaults = .standard) -> String? {
        guard let found = defaults.string(forKey: buildKey), let foundBuild = Int(found),
              let build = build.flatMap({ Int($0) }), foundBuild > build else { return nil }
        let version = defaults.string(forKey: versionKey) ?? ""
        return version.isEmpty ? "build \(found)" : "\(version) (\(found))"
    }
}

struct WhatsNew: Equatable, Sendable {
    let version: String
    let changes: [String]
}
