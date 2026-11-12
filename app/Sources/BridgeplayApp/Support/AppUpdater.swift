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
    // An update downloaded and waiting for quit, or kept to resume, and the beta preference.
    private(set) var pending: PendingUpdate?
    private(set) var betaEnrolled = BetaUpdates.enrolled(.standard)
    // The hidden switch, the one-time "back on stable" notice, and a Check for Updates that
    // found no stable release for a build leaving the beta.
    private(set) var betaUIShown = BetaUpdatesUI.shown(.standard)
    private(set) var backOnStable = BetaCatchUp.notice(running: .current, defaults: .standard)
    private(set) var leavingNothingFound = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    // Sparkle holds its delegates weakly.
    @ObservationIgnored private let finder: ReleaseFinder
    @ObservationIgnored private var sessionObservation: NSKeyValueObservation?
    // Sparkle's own install-and-relaunch for an update waiting for quit.
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var preferenceWatch: DefaultsWatch?
    @ObservationIgnored private var uiWatch: DefaultsWatch?

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
        finder.pendingChanged = { [weak self] in self?.pending = $0 }
        finder.checked = { [weak self] found, byUser, unsupported, state in
            guard let self else { return }
            leavingNothingFound = BetaUpdatesUI.leavingNothingFound(found: found, byUser: byUser, unsupported: unsupported,
                                                                    state: state, before: leavingNothingFound)
        }
        whatsNew = LatestRelease.takeWhatsNew(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        // Async because Sparkle changes this mid-way through closing a session.
        sessionObservation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.runQueuedCheck()
                    self?.restartIfQueued()
                }
            }
        }
        preferenceWatch = DefaultsWatch(key: BetaUpdates.enrolledKey) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.betaPreferenceChanged() }
            }
        }
        uiWatch = DefaultsWatch(key: BetaUpdatesUI.shownKey) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.betaUIShown = BetaUpdatesUI.shown(.standard) }
            }
        }
    }

    var running: RunningBuild { finder.routing.running }
    var state: UpdaterState { .of(enrolled: betaEnrolled, running: running.channel) }

    func dismissBackOnStable() {
        BetaCatchUp.acknowledge(.standard)
        backOnStable = nil
    }

    // After quit or relaunch: the pending update if there is one (it installs whatever the
    // preference says), else the running build, and the state that build will be in.
    var prediction: UpdatePrediction {
        .make(running: finder.routing.running, enrolled: betaEnrolled, pending: pending)
    }

    // Always allowed, and takes effect at once; a pending update still installs.
    func setBetaUpdates(_ enrolled: Bool) {
        BetaUpdates.set(enrolled: enrolled)
        betaPreferenceChanged()
    }

    private func betaPreferenceChanged() {
        let enrolled = BetaUpdates.enrolled(.standard)
        guard enrolled != betaEnrolled else { return }
        betaEnrolled = enrolled
        leavingNothingFound = false
        AppLog.note("update: beta updates \(enrolled ? "on" : "off")")
        let action = finder.routing.preferenceChanged(enrolled: enrolled,
                                                      sessionInProgress: controller.updater.sessionInProgress)
        apply(action)
    }

    private func restartIfQueued() {
        guard !controller.updater.sessionInProgress else { return }
        apply(finder.routing.sessionEnded())
    }

    private func apply(_ action: UpdateRouting.PreferenceAction) {
        #if !DEBUG
        let updater = controller.updater
        for call in action.calls {
            switch call {
            case .resetUpdateCycle: updater.resetUpdateCycle()
            case .checkInBackground: updater.checkForUpdatesInBackground()
            }
        }
        #endif
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
    var pendingChanged: ((PendingUpdate?) -> Void)?
    // Found or not, whether the user asked, whether the newest item needs another macOS or Mac,
    // and the state the check ran in.
    var checked: ((Bool, Bool, Bool, UpdaterState) -> Void)?
    private var userCheck = false
    var routing = UpdateRouting(running: .current, settings: .read(.standard))

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        routing.startCheck(settings: .read(.standard))
        userCheck = updateCheck == .updates
        report?(.cycleStarted(byUser: updateCheck == .updates))
    }

    // nil keeps SUFeedURL, so the stable state requests the feed exactly as before.
    func feedURLString(for updater: SPUUpdater) -> String? {
        routing.route.feedURL
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        routing.route.allowedChannels
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        routing.feedDidLoad()
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let items = appcast.items
        guard let choice = routing.choose(items.map(FeedItem.init)) else { return nil }
        return choice.map { items[$0] } ?? SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        LatestRelease.record(build: item.versionString, version: item.displayVersionString, notes: item.itemDescription,
                             state: routing.state)
        UpdateLog.note(routing.found(FeedItem(item), feedURL: updater.feedURL?.absoluteString))
        pendingChanged?(routing.pending)
        checked?(true, userCheck, false, routing.state)
        report?(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        UpdateLog.note(routing.notFound(reason: Self.describe(reason), feedURL: updater.feedURL?.absoluteString))
        pendingChanged?(routing.pending)
        let unsupported = [.systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64].contains(reason)
        checked?(false, userCheck, unsupported, routing.state)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        routing.downloading(FeedItem(item))
        pendingChanged?(routing.pending)
        report?(.downloading(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        report?(.preparing(version: item.displayVersionString))
    }

    // True keeps the install block for Restart to Update. It also holds this session open
    // until quit, so no more checks run; Sparkle still installs on quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        routing.waitingForQuit(FeedItem(item))
        pendingChanged?(routing.pending)
        installerReady?(immediateInstallHandler)
        report?(.ready(version: item.displayVersionString))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let error = error as NSError?
        let feedError = error.map { $0.domain == SUSparkleErrorDomain && Self.feedErrors.contains(Int($0.code)) } ?? false
        UpdateLog.note(routing.finished(error: error.map { "\($0.domain) \($0.code)" }, feedFailed: feedError,
                                        feedURL: updater.feedURL?.absoluteString))
        pendingChanged?(routing.pending)
        report?(.cycleFinished)
    }

    // The feed could not be fetched or read.
    private static let feedErrors: Set<Int> = [Int(SUError.appcastParseError.rawValue), Int(SUError.appcastError.rawValue),
                                               Int(SUError.downloadError.rawValue)]

    private static func describe(_ reason: SPUNoUpdateFoundReason?) -> String {
        switch reason {
        case .onLatestVersion: "up to date"
        case .onNewerThanLatestVersion: "newer than the feed"
        case .systemIsTooOld: "macOS too old for the newest item"
        case .systemIsTooNew: "macOS too new for the newest item"
        case .hardwareDoesNotSupportARM64: "hardware unsupported"
        default: "no update"
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // A background update never opens a window; the banner is the reminder.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if state.stage != .notDownloaded {
            UpdateLog.note(routing.resuming(FeedItem(update)))
            pendingChanged?(routing.pending)
        }
        guard !state.userInitiated else { return }
        report?(.reminder(version: update.displayVersionString, downloaded: state.stage != .notDownloaded))
    }

    func standardUserDriverWillFinishUpdateSession() {
        report?(.updateClosed)
    }
}

extension FeedItem {
    init(_ item: SUAppcastItem) {
        self.init(label: item.displayVersionString, build: item.versionString, channel: item.channel,
                  containsBetas: item.propertiesDictionary[BetaUpdates.containsBetasElement] as? String)
    }
}

// F0.9 lines go to bridgeplay.log, beside the dylib's own lines, and to the app's log.
enum UpdateLog {
    static var file: URL { SupportPaths.support.appending(path: "bridgeplay.log") }

    private static let queue = DispatchQueue(label: "bridgeplay.updatelog")

    static func note(_ line: String?) {
        guard let line else { return }
        AppLog.note(line)
        let text = "\(Date().ISO8601Format()) [app] \(line)\n"
        queue.async { append(text, to: file) }
    }

    // O_APPEND, so lines from Steam's dylib and from here never overwrite each other. The folder
    // is never created here: the dylib picks the legacy folder only while this one is missing.
    static func append(_ text: String, to file: URL) {
        let fd = open(file.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

// Calls back when one key of the standard defaults changes, in this process or another.
private final class DefaultsWatch: NSObject, @unchecked Sendable {
    private let key: String
    private let changed: @Sendable () -> Void

    init(key: String, changed: @escaping @Sendable () -> Void) {
        self.key = key
        self.changed = changed
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changed()
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
    // The updater state that found it; absent means stable, so the stable state writes nothing new.
    static let stateKey = "LatestReleaseState"

    static func record(build: String, version: String, notes: String? = nil, state: UpdaterState = .stable,
                       defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: buildKey)
        defaults.set(version, forKey: versionKey)
        defaults.set(notes, forKey: notesKey)
        if state != .stable {
            defaults.set(state.rawValue, forKey: stateKey)
        } else if defaults.object(forKey: stateKey) != nil {
            defaults.removeObject(forKey: stateKey)
        }
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
    // build, never by the version label. Only a release found in `state` counts, so a beta the
    // beta feed offered doesn't make a stable player behind.
    static func newer(than build: String?, state: UpdaterState = .stable, defaults: UserDefaults = .standard) -> String? {
        guard (defaults.string(forKey: stateKey) ?? UpdaterState.stable.rawValue) == state.rawValue,
              let found = defaults.string(forKey: buildKey), let foundBuild = Int(found),
              let build = build.flatMap({ Int($0) }), foundBuild > build else { return nil }
        let version = defaults.string(forKey: versionKey) ?? ""
        return version.isEmpty ? "build \(found)" : "\(version) (\(found))"
    }
}

struct WhatsNew: Equatable, Sendable {
    let version: String
    let changes: [String]
}
