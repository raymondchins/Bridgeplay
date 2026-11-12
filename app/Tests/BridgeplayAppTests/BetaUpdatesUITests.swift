import Foundation
import Testing
@testable import BridgeplayApp

private let stableBuild = RunningBuild(label: "0.7.69", build: "90", channel: .stable)
private let betaBuild = RunningBuild(label: "0.7.70-beta.1", build: "91", channel: .beta)
private let nextBeta = FeedItem(label: "0.7.70-beta.2", build: "92", channel: "beta")
private let nextStable = FeedItem(label: "0.7.70", build: "93", channel: nil, containsBetas: "91-92")

@Suite("Beta updates UI")
struct BetaUpdatesUITests {

    @Test("A stable build with no keys set shows nothing new")
    func hiddenByDefault() {
        let defaults = scratchDefaults()
        let state = UpdaterState.of(enrolled: BetaUpdates.enrolled(defaults), running: stableBuild.channel)
        let back = BetaCatchUp.notice(running: stableBuild, defaults: defaults)
        #expect(!BetaUpdatesUI.shown(defaults))
        #expect(back == nil)
        #expect(BetaStatus.make(state: state, running: stableBuild, preferenceSet: BetaUpdatesUI.preferenceSet(defaults)) == nil)
        #expect(!BetaUpdatesUI.visible(shown: false, state: state, backOnStable: back))
        // Nothing was written for this account either.
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Beta") }.isEmpty)
    }

    @Test("Only a real boolean shows the switch")
    func uiKey() {
        let defaults = scratchDefaults()
        #expect(!BetaUpdatesUI.shown(defaults))
        defaults.set(true, forKey: "BetaUpdatesUI")
        #expect(BetaUpdatesUI.shown(defaults))
        for garbage: Any in ["1", "YES", 1] {
            defaults.set(garbage, forKey: "BetaUpdatesUI")
            #expect(!BetaUpdatesUI.shown(defaults), "\(garbage)")
        }
        #expect(BetaUpdatesUI.visible(shown: true, state: .stable, backOnStable: nil))
    }

    @Test("The status row shows without the key whenever the state is not stable")
    func visibleWhenNotStable() {
        #expect(BetaUpdatesUI.visible(shown: false, state: .beta, backOnStable: nil))
        #expect(BetaUpdatesUI.visible(shown: false, state: .leaving, backOnStable: nil))
        #expect(BetaUpdatesUI.visible(shown: false, state: .stable, backOnStable: stableBuild))
    }

    @Test("The switch asks first; cancel changes nothing")
    func switchAsks() {
        let defaults = scratchDefaults()
        var beta = BetaSwitch()
        beta.request(true, enrolled: false)
        #expect(beta.asking == .optIn)
        #expect(defaults.object(forKey: "BetaUpdates") == nil)
        beta.cancel()
        #expect(beta.asking == nil)
        #expect(defaults.object(forKey: "BetaUpdates") == nil)

        beta.request(false, enrolled: true)
        #expect(beta.asking == .optOut)
        #expect(beta.asking?.enrolls == false)
        beta.request(true, enrolled: true)
        #expect(beta.asking == .optOut, "a request matching the preference asks nothing new")

        // What the confirm button writes.
        BetaUpdates.set(enrolled: BetaAsk.optIn.enrolls, defaults: defaults)
        #expect(BetaUpdates.enrolled(defaults))
    }

    @Test("Opt-in explains the Mac-wide app; opt-out names the running beta")
    func confirmations() {
        let optIn = BetaCopy.confirmation(.optIn, running: stableBuild, pending: nil)
        #expect(optIn.title == "Get beta updates?")
        #expect(optIn.button == "Get Betas")
        #expect(optIn.message.contains("shared by every account on this Mac"))

        let optOut = BetaCopy.confirmation(.optOut, running: betaBuild, pending: nil)
        #expect(optOut.button == "Stop Betas")
        #expect(optOut.message.contains("0.7.70-beta.1 (build 91)"))
        #expect(optOut.message.contains("never goes back to an older version"))
        #expect(optOut.message.contains("next stable release that includes it"))

        let stableOptOut = BetaCopy.confirmation(.optOut, running: stableBuild, pending: nil)
        #expect(stableOptOut.message == "Bridgeplay goes back to stable updates only.")
    }

    @Test("Pending update, opting out with a beta waiting for quit: leaving after that")
    func pendingOptOutBeta() {
        let pending = PendingUpdate(item: nextBeta, stage: .waitingForQuit)
        let message = BetaCopy.confirmation(.optOut, running: betaBuild, pending: pending).message
        #expect(message.hasSuffix("Bridgeplay 0.7.70-beta.2 (build 92) is already downloaded and installs when you quit. After that, Bridgeplay waits for a stable release that includes build 92."))
    }

    @Test("Pending update, opting out while a beta downloads: it installs on quit if it finishes first")
    func pendingOptOutDownloading() {
        let pending = PendingUpdate(item: nextBeta, stage: .downloading)
        let message = BetaCopy.confirmation(.optOut, running: betaBuild, pending: pending).message
        #expect(message.hasSuffix("Bridgeplay 0.7.70-beta.2 (build 92) is downloading. If it finishes before you quit, it installs when you quit. After that, Bridgeplay waits for a stable release that includes build 92."))
    }

    @Test("Pending update, opting in with a stable waiting for quit: betas after that")
    func pendingOptInStable() {
        let item = FeedItem(label: "0.7.70", build: "93", channel: nil)
        let pending = PendingUpdate(item: item, stage: .waitingForQuit)
        let message = BetaCopy.confirmation(.optIn, running: stableBuild, pending: pending).message
        #expect(message.hasSuffix("Bridgeplay 0.7.70 (build 93) is already downloaded and installs when you quit. Beta updates start after that."))
    }

    @Test("Pending update, opting out with a stable catch-up kept to resume: stable after that")
    func pendingOptOutStableResumable() {
        let pending = PendingUpdate(item: nextStable, stage: .resumable)
        let message = BetaCopy.confirmation(.optOut, running: betaBuild, pending: pending).message
        #expect(message.hasSuffix("Bridgeplay 0.7.70 (build 93) is already downloaded and installs the next time Bridgeplay updates. Stable updates continue after that."))
    }

    @Test("No pending update, no pending sentence")
    func noPending() {
        let prediction = UpdatePrediction.make(running: betaBuild, enrolled: false, pending: nil)
        #expect(BetaCopy.pendingNote(nil, prediction: prediction) == nil)
    }

    @Test("Status rows for beta, leaving and another account")
    func rows() {
        let on = BetaCopy.row(.on(betaBuild))
        #expect(on.title == "Beta updates on")
        #expect(on.value == "0.7.70-beta.1 (build 91)")

        #expect(BetaStatus.make(state: .leaving, running: betaBuild, preferenceSet: true) == .leaving(betaBuild))
        let leaving = BetaCopy.row(.leaving(betaBuild))
        #expect(leaving.title == "Leaving the beta")
        #expect(leaving.value == "Waiting for a stable release that includes build 91.")
        #expect(leaving.detail == nil)

        #expect(BetaStatus.make(state: .leaving, running: betaBuild, preferenceSet: false) == .anotherAccount(betaBuild))
        let other = BetaCopy.row(.anotherAccount(betaBuild))
        #expect(other.value.hasPrefix("Another account on this Mac installed a beta."))
        #expect(other.value.contains("build 91"))

        let nothing = BetaCopy.row(.leaving(betaBuild), nothingFound: true)
        #expect(nothing.detail == "No stable release includes your beta yet. Bridgeplay stays on build 91 and checks again later.")
    }

    @Test("Back on stable shows after a beta build until acknowledged, only when not enrolled")
    func backOnStable() {
        let defaults = scratchDefaults()
        #expect(BetaCatchUp.notice(running: betaBuild, defaults: defaults) == nil)
        #expect(defaults.string(forKey: "BetaBuildSeen") == "91")
        #expect(BetaCatchUp.notice(running: stableBuild, defaults: defaults) == stableBuild)
        // Quit before pressing OK: the next launch shows it again.
        #expect(BetaCatchUp.notice(running: stableBuild, defaults: defaults) == stableBuild)
        BetaCatchUp.acknowledge(defaults)
        #expect(BetaCatchUp.notice(running: stableBuild, defaults: defaults) == nil)
        #expect(BetaCopy.backOnStable(stableBuild) == .init(title: "You're back on stable updates", value: "0.7.69 (build 90)"))

        // Still enrolled: a stable build is part of the beta, not a return to stable.
        _ = BetaCatchUp.notice(running: betaBuild, defaults: defaults)
        BetaUpdates.set(enrolled: true, defaults: defaults)
        #expect(BetaCatchUp.notice(running: stableBuild, defaults: defaults) == nil)
        #expect(defaults.object(forKey: "BetaBuildSeen") == nil)
    }

    @Test("No stable release found: shown only after a check the user asked for that found nothing it could run")
    func leavingNothingFound() {
        func after(found: Bool = false, byUser: Bool = true, unsupported: Bool = false,
                   state: UpdaterState = .leaving, before: Bool = false) -> Bool {
            BetaUpdatesUI.leavingNothingFound(found: found, byUser: byUser, unsupported: unsupported,
                                              state: state, before: before)
        }
        #expect(after())
        #expect(!after(unsupported: true), "a release that needs another macOS exists")
        #expect(!after(unsupported: true, before: true))
        #expect(!after(found: true, before: true))
        #expect(!after(state: .beta, before: true))
        #expect(!after(state: .stable, before: true))
        #expect(after(byUser: false, before: true), "a background check leaves it")
        #expect(!after(byUser: false, before: false))
    }

    @Test("A build without a number is named by its label")
    func unnamedBuild() {
        #expect(BetaCopy.named("0.7.70-beta.1", nil) == "0.7.70-beta.1")
    }
}
