// Which feed, channels and item an update check uses, worked out from the beta preference and
// the running build. Sparkle-free so it can be tested; AppUpdater feeds it Sparkle's events.

import Foundation

enum UpdaterState: String, Equatable, Sendable {
    case stable, beta, leaving

    static var current: UpdaterState {
        .of(enrolled: BetaUpdates.enrolled(.standard), running: ProductVersion.channel)
    }

    // A missing or unreadable preference is off.
    static func of(enrolled: Bool, running: ProductVersion.Channel) -> UpdaterState {
        if enrolled { return .beta }
        return running == .beta ? .leaving : .stable
    }

    // Sparkle's default channel (no-channel items) is always allowed on top of these.
    var allowedChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: [BetaUpdates.betaChannel, BetaUpdates.criticalChannel]
        case .leaving: [BetaUpdates.criticalChannel]
        }
    }
}

// The per-account defaults in com.bridgeplay.Bridgeplay. Nothing here writes them except
// set(enrolled:), which only a user action calls.
enum BetaUpdates {
    static let enrolledKey = "BetaUpdates"
    static let betaFeedOverrideKey = "BetaFeedURLOverride"
    static let stableFeedOverrideKey = "StableFeedURLOverride"
    static let betaFeedURL = "https://github.com/raymondchins/Bridgeplay/releases/download/beta-feed/appcast.xml"
    static let betaChannel = "beta"
    static let criticalChannel = "beta-critical"
    // The stable item's list of the betas it contains. Sparkle keys custom elements by their
    // qualified name, so the feed must use this prefix.
    static let containsBetasElement = "bridgeplay:containsBetas"

    // Only a real boolean counts: a string, a number or garbage is off.
    static func enrolled(_ defaults: UserDefaults) -> Bool {
        flag(defaults, key: enrolledKey)
    }

    static func flag(_ defaults: UserDefaults, key: String) -> Bool {
        guard let value = defaults.object(forKey: key) as AnyObject?,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return (value as? Bool) ?? false
    }

    static func set(enrolled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enrolled, forKey: enrolledKey)
    }
}

// What a check reads from defaults, once per check.
struct UpdateSettings: Equatable, Sendable {
    var enrolled = false
    var betaFeedOverride: String?
    var stableFeedOverride: String?

    static func read(_ defaults: UserDefaults) -> UpdateSettings {
        UpdateSettings(enrolled: BetaUpdates.enrolled(defaults),
                       betaFeedOverride: defaults.object(forKey: BetaUpdates.betaFeedOverrideKey) as? String,
                       stableFeedOverride: defaults.object(forKey: BetaUpdates.stableFeedOverrideKey) as? String)
    }

    // A testing override has to be an absolute http, https or file URL to be used.
    static func usable(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        return text
    }
}

struct RunningBuild: Equatable, Sendable {
    var label: String
    var build: String?
    var channel: ProductVersion.Channel

    static var current: RunningBuild {
        RunningBuild(label: ProductVersion.short, build: ProductVersion.build, channel: ProductVersion.channel)
    }

    var number: Int? { build.flatMap { Int($0) } }
}

// The feed, channels and item rule for one check.
struct UpdateRoute: Equatable, Sendable {
    enum Feed: Equatable, Sendable { case stable, beta }

    var state: UpdaterState
    var feed: Feed
    // What feedURLStringForUpdater returns; nil leaves Sparkle on SUFeedURL, as today.
    var feedURL: String?
    var fallback = false
    // Notes the check's log line carries: overrides used or ignored, the fallback.
    var notes: [String] = []

    var allowedChannels: Set<String> { state.allowedChannels }
    // In the stable state Sparkle's own choice is untouched.
    var choosesItems: Bool { state != .stable }

    static func make(state: UpdaterState, settings: UpdateSettings, betaFeedFailed: Bool) -> UpdateRoute {
        var notes: [String] = []
        func overridden(_ text: String?, key: String) -> String? {
            guard let text else { return nil }
            guard let usable = UpdateSettings.usable(text) else {
                notes.append("\(key) ignored (not a URL)")
                return nil
            }
            notes.append("\(key) used")
            return usable
        }
        let feed: Feed = state == .stable || betaFeedFailed ? .stable : .beta
        let url = switch feed {
        case .stable: overridden(settings.stableFeedOverride, key: BetaUpdates.stableFeedOverrideKey)
        case .beta: overridden(settings.betaFeedOverride, key: BetaUpdates.betaFeedOverrideKey) ?? BetaUpdates.betaFeedURL
        }
        let fallback = state != .stable && betaFeedFailed
        if fallback { notes.append("stable feed after a failed beta-feed check") }
        return UpdateRoute(state: state, feed: feed, feedURL: url, fallback: fallback, notes: notes)
    }
}

// F0.7: ascending beta builds and inclusive ranges, "81-85,87". Missing or empty is none.
enum CatchUpList: Equatable, Sendable {
    case missing
    case list([ClosedRange<Int>])
    case malformed

    init(_ text: String?) {
        guard let text else { self = .missing; return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { self = .list([]); return }
        var ranges: [ClosedRange<Int>] = []
        for token in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = token.trimmingCharacters(in: .whitespaces)
                .split(separator: "-", omittingEmptySubsequences: false)
            let numbers = parts.map { part in part.allSatisfy(\.isASCIIDigit) ? Int(part) : nil }
            guard (1...2).contains(numbers.count), let low = numbers.first ?? nil, let high = numbers.last ?? nil,
                  low <= high, ranges.last.map({ $0.upperBound < low }) ?? true else {
                self = .malformed
                return
            }
            ranges.append(low...high)
        }
        self = .list(ranges)
    }

    func contains(_ build: Int) -> Bool {
        if case .list(let ranges) = self { return ranges.contains { $0.contains(build) } }
        return false
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// One appcast item as the rules see it.
struct FeedItem: Equatable, Sendable {
    var label: String
    var build: String
    var channel: String?
    var containsBetas: String?

    var number: Int? { Int(build) }
    var isStable: Bool { channel == nil }
    // The channel of the build this item installs.
    var buildChannel: ProductVersion.Channel { isStable ? .stable : .beta }
    var described: String { "\(build) (\(channel ?? "stable"))" }
}

struct ItemChoice: Equatable, Sendable {
    var index: Int?
    var reason: String?
    var notes: [String] = []

    // The item rule for the beta and leaving states: of the allowed items, the highest build above
    // the running one. A stable item from a beta build needs that build in its catch-up list.
    static func choose(_ items: [FeedItem], running: RunningBuild, allowed: Set<String>) -> ItemChoice {
        guard let current = running.number else { return ItemChoice(reason: "running build unknown") }
        var best: (index: Int, build: Int)?
        var notes: [String] = []
        for (index, item) in items.enumerated() {
            guard let build = item.number, build > current else { continue }
            if let channel = item.channel {
                guard allowed.contains(channel) else { continue }
            } else if running.channel == .beta {
                let list = CatchUpList(item.containsBetas)
                if list == .malformed { notes.append("malformed containsBetas on \(item.build), treated as none") }
                guard list.contains(current) else {
                    notes.append("stable \(item.build) does not contain \(current)")
                    continue
                }
            }
            if best.map({ build > $0.build }) ?? true { best = (index, build) }
        }
        guard let best else {
            return ItemChoice(reason: "no allowed item above \(current)", notes: notes)
        }
        return ItemChoice(index: best.index, notes: notes)
    }
}

// An update Sparkle has downloaded: waiting for quit, or kept to resume.
// What a check ended with. Unsupported: the newest item needs another macOS or Mac.
enum CheckResult: Equatable, Sendable { case found, nothing, unsupported }

struct PendingUpdate: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable { case downloading, waitingForQuit = "waiting for quit", resumable }

    var item: FeedItem
    var stage: Stage
}

// "After quit/relaunch you will be on X (build n), state Y."
struct UpdatePrediction: Equatable, Sendable {
    var label: String
    var build: String?
    var channel: ProductVersion.Channel
    var state: UpdaterState
    // A pending update installs whatever the preference now says; Sparkle can't cancel it.
    var installsPending: Bool
    // That pending update is on a channel the current state no longer allows.
    var pendingOutsideState: Bool

    static func make(running: RunningBuild, enrolled: Bool, pending: PendingUpdate?) -> UpdatePrediction {
        guard let pending else {
            return UpdatePrediction(label: running.label, build: running.build, channel: running.channel,
                                    state: .of(enrolled: enrolled, running: running.channel),
                                    installsPending: false, pendingOutsideState: false)
        }
        let now = UpdaterState.of(enrolled: enrolled, running: running.channel)
        let outside = pending.item.channel.map { !now.allowedChannels.contains($0) } ?? false
        let channel = pending.item.buildChannel
        return UpdatePrediction(label: pending.item.label, build: pending.item.build, channel: channel,
                                state: .of(enrolled: enrolled, running: channel),
                                installsPending: true, pendingOutsideState: outside)
    }
}

// One app run's routing: the route of the check in progress, whether the last beta-feed check
// failed, the pending update and the F0.9 log line. Nothing here is stored on disk.
struct UpdateRouting: Equatable, Sendable {
    enum PreferenceAction: Equatable, Sendable {
        case none
        case restartCycle
        // Opting in also checks in the background.
        case restartCycleAndCheck

        // The SPUUpdater calls, in order. resetUpdateCycle holds a session while it works out the
        // next check, so a check made after it is refused; a background check reschedules the
        // cycle itself when it ends.
        var calls: [UpdaterCall] {
            switch self {
            case .none: []
            case .restartCycle: [.resetUpdateCycle]
            case .restartCycleAndCheck: [.checkInBackground]
            }
        }
    }

    enum UpdaterCall: Equatable, Sendable { case resetUpdateCycle, checkInBackground }

    let running: RunningBuild
    private(set) var settings: UpdateSettings
    private(set) var route: UpdateRoute
    private(set) var pending: PendingUpdate?
    private(set) var betaFeedFailed = false
    // Waiting for the session in progress to end before the cycle restarts.
    private(set) var restartQueued = false

    // Per check.
    private var feedLoaded = false
    private var logged = false
    private var choiceNotes: [String] = []
    private var choiceReason: String?
    private var downloadedNow = false

    init(running: RunningBuild, settings: UpdateSettings) {
        self.running = running
        self.settings = settings
        route = UpdateRoute.make(state: .of(enrolled: settings.enrolled, running: running.channel),
                                 settings: settings, betaFeedFailed: false)
    }

    var state: UpdaterState { route.state }

    // Called as each check starts. A failed beta-feed check sends this one to the stable feed.
    mutating func startCheck(settings: UpdateSettings) {
        if settings.enrolled != self.settings.enrolled { betaFeedFailed = false }
        self.settings = settings
        let state = UpdaterState.of(enrolled: settings.enrolled, running: running.channel)
        if state == .stable { betaFeedFailed = false }
        route = UpdateRoute.make(state: state, settings: settings, betaFeedFailed: betaFeedFailed)
        betaFeedFailed = false
        feedLoaded = false
        logged = false
        choiceNotes = []
        choiceReason = nil
        downloadedNow = false
    }

    mutating func feedDidLoad() {
        feedLoaded = true
    }

    // nil leaves the choice to Sparkle (stable state); .some(nil) means no item is valid.
    mutating func choose(_ items: [FeedItem]) -> Int?? {
        guard route.choosesItems else { return nil }
        let choice = ItemChoice.choose(items, running: running, allowed: route.allowedChannels)
        for note in choice.notes where !choiceNotes.contains(note) { choiceNotes.append(note) }
        if choiceReason == nil { choiceReason = choice.reason }
        return .some(choice.index)
    }

    // Sparkle found an update, from the feed or by resuming one it downloaded before.
    mutating func found(_ item: FeedItem, feedURL: String?) -> String? {
        let resumed = !feedLoaded
        if resumed, pending?.item != item { pending = PendingUpdate(item: item, stage: .resumable) }
        return line(feedURL: feedURL, outcome: "chosen=\(item.described)", resumed: resumed)
    }

    mutating func notFound(reason: String, feedURL: String?) -> String? {
        if pending?.stage == .resumable { pending = nil }
        return line(feedURL: feedURL, outcome: "chosen=none (\(choiceReason ?? reason))", resumed: false)
    }

    // The cycle ended. Returns the log line if the check ended without one, as a failed one does.
    // A beta feed that could not be fetched or read sends the next check to the stable feed.
    // authorizeLater: the user put off authorizing the install, so Sparkle keeps the download.
    mutating func finished(error: String?, feedFailed: Bool, authorizeLater: Bool = false, feedURL: String?) -> String? {
        if error != nil, feedFailed, !feedLoaded, route.feed == .beta { betaFeedFailed = true }
        // A download that finished is waiting for quit or kept to resume by now: this one stopped.
        if pending?.stage == .downloading { pending = nil }
        // Any other error after this check's download finished (extracting it, say): Sparkle drops it.
        if downloadedNow, error != nil, !authorizeLater, pending?.stage == .resumable { pending = nil }
        let outcome = error.map { "chosen=none (check failed: \($0))" } ?? "chosen=none (no result)"
        return line(feedURL: feedURL, outcome: outcome, resumed: false)
    }

    // Sparkle can't stop a download it started, and installs it on quit once it finishes.
    mutating func downloading(_ item: FeedItem) {
        pending = PendingUpdate(item: item, stage: .downloading)
    }

    // The download finished. Sparkle keeps it whether it installs now, on quit or after a reminder.
    mutating func downloaded(_ item: FeedItem) {
        pending = PendingUpdate(item: item, stage: .resumable)
        downloadedNow = true
    }

    mutating func waitingForQuit(_ item: FeedItem) {
        pending = PendingUpdate(item: item, stage: .waitingForQuit)
    }

    // Sparkle shows a downloaded update again. Logs one the current state no longer allows.
    mutating func resuming(_ item: FeedItem) -> String? {
        if pending?.item != item { pending = PendingUpdate(item: item, stage: .resumable) }
        return outsideState(item).map { "update: resuming \($0)" }
    }

    // The preference changed. The cycle restarts now, or once the session in progress ends.
    mutating func preferenceChanged(enrolled: Bool, sessionInProgress: Bool) -> PreferenceAction {
        guard enrolled != settings.enrolled else { return .none }
        settings.enrolled = enrolled
        betaFeedFailed = false
        if sessionInProgress {
            restartQueued = true
            return .none
        }
        reroute()
        return restartAction
    }

    mutating func sessionEnded() -> PreferenceAction {
        guard restartQueued else { return .none }
        restartQueued = false
        reroute()
        return restartAction
    }

    private var restartAction: PreferenceAction { settings.enrolled ? .restartCycleAndCheck : .restartCycle }
    private var preferredState: UpdaterState { .of(enrolled: settings.enrolled, running: running.channel) }

    // Sparkle asks for the feed and channels before the next check starts (resetUpdateCycle
    // compares them with the last check's), so they follow the preference at once.
    private mutating func reroute() {
        route = UpdateRoute.make(state: preferredState, settings: settings, betaFeedFailed: false)
    }

    func prediction(enrolled: Bool) -> UpdatePrediction {
        .make(running: running, enrolled: enrolled, pending: pending)
    }

    private func outsideState(_ item: FeedItem) -> String? {
        let state = preferredState
        guard let channel = item.channel, !state.allowedChannels.contains(channel) else { return nil }
        return "\(item.described), which the \(state.rawValue) state does not allow; Sparkle installs it anyway"
    }

    // F0.9: one line per check.
    private mutating func line(feedURL: String?, outcome: String, resumed: Bool) -> String? {
        guard !logged else { return nil }
        logged = true
        var parts = ["update check: state=\(route.state.rawValue)",
                     "feed=\(resumed ? "not fetched" : feedURL ?? "unknown")",
                     "running=\(running.build ?? "unknown") (\(running.channel.rawValue))",
                     outcome]
        if let pending {
            var text = "pending=\(resumed ? "resumed" : pending.stage.rawValue) \(pending.item.described)"
            if let outside = outsideState(pending.item) { text += ": \(outside)" }
            parts.append(text)
        } else {
            parts.append("pending=none")
        }
        let notes = route.notes + choiceNotes
        if !notes.isEmpty { parts.append("notes: " + notes.joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}
