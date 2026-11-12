// What the hidden beta settings and the beta status rows show. Sparkle-free so it can be tested;
// BetaUpdatesSection draws it from AppUpdater.

import Foundation

enum BetaUpdatesUI {
    // Shows the "Get beta updates" switch. Like BetaUpdates, only a real boolean counts.
    static let shownKey = "BetaUpdatesUI"

    static func shown(_ defaults: UserDefaults) -> Bool {
        BetaUpdates.flag(defaults, key: shownKey)
    }

    // This account set the preference, on or off, at some point.
    static func preferenceSet(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: BetaUpdates.enrolledKey) != nil
    }

    // Nothing new is visible for a stable build with no keys set.
    static func visible(shown: Bool, state: UpdaterState, backOnStable: RunningBuild?) -> Bool {
        shown || state != .stable || backOnStable != nil
    }

    // Whether "No stable release includes your beta yet" shows after a check. A background check
    // leaves it as it was. A release this Mac can't run is not a missing one; Sparkle says why.
    static func leavingNothingFound(found: Bool, byUser: Bool, unsupported: Bool, state: UpdaterState,
                                    before: Bool) -> Bool {
        guard !found, state == .leaving else { return false }
        return byUser ? !unsupported : before
    }
}

// The "back on stable" notice. A beta build notes itself for this account; every stable build
// this account runs afterwards shows the notice until its OK acknowledges it.
enum BetaCatchUp {
    static let seenKey = "BetaBuildSeen"

    static func notice(running: RunningBuild, defaults: UserDefaults) -> RunningBuild? {
        if running.channel == .beta {
            let value = running.build ?? running.label
            if defaults.string(forKey: seenKey) != value { defaults.set(value, forKey: seenKey) }
            return nil
        }
        guard defaults.object(forKey: seenKey) != nil else { return nil }
        // Still enrolled: a stable build is part of the beta, not a return to stable.
        guard !BetaUpdates.enrolled(defaults) else {
            acknowledge(defaults)
            return nil
        }
        return running
    }

    static func acknowledge(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: seenKey)
    }
}

enum BetaStatus: Equatable, Sendable {
    case on(RunningBuild)
    case leaving(RunningBuild)
    // Leaving, and this account never set the preference: someone else's beta is installed.
    case anotherAccount(RunningBuild)

    static func make(state: UpdaterState, running: RunningBuild, preferenceSet: Bool) -> BetaStatus? {
        switch state {
        case .stable: nil
        case .beta: .on(running)
        case .leaving: preferenceSet ? .leaving(running) : .anotherAccount(running)
        }
    }
}

enum BetaAsk: Equatable, Sendable {
    case optIn, optOut

    var enrolls: Bool { self == .optIn }
}

// Flipping the switch only asks; the preference is written by the dialog's confirm button.
struct BetaSwitch: Equatable, Sendable {
    private(set) var asking: BetaAsk?

    mutating func request(_ on: Bool, enrolled: Bool) {
        guard on != enrolled else { return }
        asking = on ? .optIn : .optOut
    }

    mutating func cancel() {
        asking = nil
    }
}

struct BetaConfirmation: Equatable, Sendable {
    var title: String
    var message: String
    var button: String
}

// Labels can collide, so every message names the build too.
enum BetaCopy {
    static var toggle: String { String(localized: "Get beta updates") }
    static var footnote: String {
        String(localized: "Betas get new changes first and may have bugs. Your games, saves and settings carry over.")
    }

    // "0.7.70-beta.2 (build 91)"
    static func named(_ label: String, _ build: String?) -> String {
        guard let build else { return label }
        return String(localized: "\(label) (build \(build))")
    }

    static func named(_ running: RunningBuild) -> String { named(running.label, running.build) }

    static func confirmation(_ ask: BetaAsk, running: RunningBuild, pending: PendingUpdate?) -> BetaConfirmation {
        let prediction = UpdatePrediction.make(running: running, enrolled: ask.enrolls, pending: pending)
        var parts: [String]
        let title: String
        let button: String
        switch ask {
        case .optIn:
            title = String(localized: "Get beta updates?")
            button = String(localized: "Get Betas")
            parts = [String(localized: "Bridgeplay and its Steam patch are shared by every account on this Mac, so a beta you install is the version every account runs.")]
        case .optOut:
            title = String(localized: "Stop getting beta updates?")
            button = String(localized: "Stop Betas")
            parts = running.channel == .beta
                ? [String(localized: "This Mac runs the beta Bridgeplay \(named(running)). Bridgeplay never goes back to an older version: it stays on this build and moves to the next stable release that includes it.")]
                : [String(localized: "Bridgeplay goes back to stable updates only.")]
        }
        if let note = pendingNote(pending, prediction: prediction) { parts.append(note) }
        return BetaConfirmation(title: title, message: parts.joined(separator: " "), button: button)
    }

    // A downloaded update, or one downloading, installs whatever the switch says, so the change waits for it.
    static func pendingNote(_ pending: PendingUpdate?, prediction: UpdatePrediction) -> String? {
        guard let pending, prediction.installsPending else { return nil }
        let name = named(pending.item.label, pending.item.build)
        let installs = switch pending.stage {
        case .downloading: String(localized: "Bridgeplay \(name) is downloading. If it finishes before you quit, it installs when you quit.")
        case .waitingForQuit: String(localized: "Bridgeplay \(name) is already downloaded and installs when you quit.")
        case .resumable: String(localized: "Bridgeplay \(name) is already downloaded and installs the next time Bridgeplay updates.")
        }
        let after = switch prediction.state {
        case .beta: String(localized: "Beta updates start after that.")
        case .leaving: String(localized: "After that, Bridgeplay waits for a stable release that includes build \(prediction.build ?? prediction.label).")
        case .stable: String(localized: "Stable updates continue after that.")
        }
        return installs + " " + after
    }

    struct Row: Equatable, Sendable {
        var title: String
        var value: String
        var detail: String?
    }

    static func row(_ status: BetaStatus, nothingFound: Bool = false) -> Row {
        switch status {
        case .on(let running):
            return Row(title: String(localized: "Beta updates on"), value: named(running))
        case .leaving(let running), .anotherAccount(let running):
            let build = running.build ?? running.label
            let value = if case .anotherAccount = status {
                String(localized: "Another account on this Mac installed a beta. Bridgeplay \(named(running)) stays until a stable release includes build \(build).")
            } else {
                String(localized: "Waiting for a stable release that includes build \(build).")
            }
            let detail = nothingFound
                ? String(localized: "No stable release includes your beta yet. Bridgeplay stays on build \(build) and checks again later.")
                : nil
            return Row(title: String(localized: "Leaving the beta"), value: value, detail: detail)
        }
    }

    static func backOnStable(_ running: RunningBuild) -> Row {
        Row(title: String(localized: "You're back on stable updates"), value: named(running))
    }
}
