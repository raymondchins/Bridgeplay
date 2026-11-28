import SwiftUI
import BridgeplayUI

// The top of the Status page: the landing page's aurora behind one plain answer to "can I
// play?", with the engine, graphics and Steam state as chips underneath.
struct StatusHero: View {
    let snapshot: StatusSnapshot
    @Environment(SystemStatus.self) private var status

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Ambient motion stops while the window is in the background
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack(alignment: .leading) {
            // Only the aurora redraws per frame; the grid and the text stay put
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
                let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate * 0.6
                Aurora(t: t, lean: lean)
            }
            GridLines()
                HStack(spacing: 18) {
                    BridgeplayMark(size: 52)
                        .shadow(color: BP.violet.opacity(0.45), radius: 18)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline)
                            .font(BP.sans(24, .semibold))
                            .tracking(-0.7)
                            .foregroundStyle(ready ? AnyShapeStyle(BP.iridescent) : AnyShapeStyle(BP.fg))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityAddTraits(.isHeader)
                        Text(detail)
                            .font(BP.sans(13))
                            .foregroundStyle(BP.fg2)
                            .lineLimit(2)
                            .help(detail)
                        HeroChips(chips: chips)
                    }
                    Spacer(minLength: 12)
                    actions
                }
                .padding(.horizontal, 24)
        }
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        .padding(.horizontal, BP.pageMargin)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(BP.bg)
    }

    private var state: HeroState { HeroState.make(snapshot) }
    private var ready: Bool { state.ready }
    private var headline: String { state.headline }
    private var detail: String { state.detail }

    private var lean: Float {
        switch snapshot.steam {
        case .installed: 0.5
        case .outdated: 0.8
        default: 0.15
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !state.actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(state.actions, id: \.self) { action in
                    switch action {
                    case .openSteam:
                        Button("Open Steam") { status.openSteam() }
                            .buttonStyle(.pill)
                    case .pause:
                        Button("Pause") { Task { await status.setSteamPaused(true) } }
                            .buttonStyle(.pillSecondary)
                            .help(String(localized: "Off from Steam's next start."))
                    case .resume:
                        Button("Resume") { Task { await status.setSteamPaused(false) } }
                            .buttonStyle(.pill)
                            .help(String(localized: "On from Steam's next start."))
                    case .tryAgain:
                        Button("Try Again") { Task { await status.tryAgainInSteam() } }
                            .buttonStyle(.pill)
                            .help(String(localized: "Quit Steam first."))
                    }
                }
            }
            .disabled(!status.isIdle)
            .fixedSize()
        }
    }

    private var chips: [String] {
        var chips: [String] = []
        let engines = snapshot.currentFreeEngines
        let preferred = engines.contains(FreeEngineWinecx.current.build) ? FreeEngineWinecx.current.build : engines.sorted().last
        if let preferred { chips.append(Self.engineName(preferred)) }
        chips.append(snapshot.gptkSource == nil ? "DXMT" : "D3DMetal")
        if snapshot.steamRunning { chips.append(String(localized: "Steam running")) }
        if snapshot.health.mode != nil, snapshot.health.health?.channel == "publicbeta" {
            chips.append(String(localized: "Steam Beta"))
        }
        return chips
    }

    // "winecx-11.17" reads as "WineCX 11.17".
    static func engineName(_ build: String) -> String {
        let parts = build.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return build }
        let family = FreeEngine.family(ofBuild: build) ?? parts[0]
        return "\(family) \(parts[1])"
    }
}

// A hero's chips, read by VoiceOver as one line ("WineCX 11.17, D3DMetal, Steam running").
struct HeroChips: View {
    let chips: [String]

    var body: some View {
        // The hero has a fixed height, so a row too wide for a narrow window or a longer
        // language drops its last chips rather than wrapping or breaking one mid-word.
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(chips.count, 1)).reversed(), id: \.self) { count in
                row(Array(chips.prefix(count)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chips.joined(separator: ", "))
    }

    private func row(_ shown: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, chip in
                HeroChip(text: chip, index: index)
            }
        }
    }
}

// A fact under a hero headline: near-white text on a quiet pill, with the colour kept to a
// small dot in one of the brand's three hues.
struct HeroChip: View {
    let text: String
    let index: Int

    var body: some View {
        let hue = [BP.violet, BP.blue, BP.pink][index % 3]
        HStack(spacing: 6) {
            Circle()
                .fill(hue)
                .frame(width: 6, height: 6)
            Text(text)
                .font(BP.sans(12, .medium))
                .foregroundStyle(BP.fg)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(BP.chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(BP.chipLine, lineWidth: 1))
    }
}

enum HeroAction: Hashable, Sendable {
    case openSteam, pause, resume, tryAgain
}

// The hero's answer to "can I play?", from what is installed and what the dylib reported from
// this user's Steam (SteamHealth). Kept apart from the view so tests can walk every state.
struct HeroState: Equatable {
    var headline: String
    var detail: String
    var ready = false
    var actions: [HeroAction] = []

    // offModes: Pause, the crash-loop breaker and the pause list (SteamHealthStore.offModesEnabled).
    static func make(_ snapshot: StatusSnapshot,
                     offModes: Bool = SteamHealthStore.offModesEnabled) -> HeroState {
        // Steam can hold a newer Bridgeplay than this app (an older copy was opened).
        if snapshot.installContent == .newerInstalled {
            return HeroState(headline: String(localized: "Newer build in Steam"),
                             detail: String(localized: "Open the newer app."))
        }
        switch snapshot.steam {
        case .installed: break
        case .outdated:
            return HeroState(headline: String(localized: "Update ready"),
                             detail: String(localized: "Install it into Steam below."))
        case .notInstalled:
            return HeroState(headline: String(localized: "Not set up"),
                             detail: String(localized: "Install below or run Setup Assistant."))
        case .steamMissing:
            return HeroState(headline: String(localized: "Steam not found"),
                             detail: String(localized: "Install Steam or choose its folder."))
        case .foreign:
            return HeroState(headline: String(localized: "Steam modified"),
                             detail: String(localized: "Another tool changed it. Repair Steam."))
        }

        // Installed: playable once Steam has every file and an engine is set up. CrossOver
        // alone counts; the free engine is not required.
        if !snapshot.payload.isSteamComplete {
            return HeroState(headline: String(localized: "Almost ready"),
                             detail: String(localized: "Reinstall into Steam below."))
        }
        switch snapshot.runner {
        case .none:
            return HeroState(headline: String(localized: "Almost ready"),
                             detail: String(localized: "Install an engine below."))
        case .unpatched:
            return HeroState(headline: String(localized: "Almost ready"),
                             detail: String(localized: "Set up the engine again below."))
        case .ready: break
        }

        let health = snapshot.health
        let runningHere = snapshot.steamRunningHere
        let pause: [HeroAction] = offModes ? [.pause] : []
        if offModes, let state = offModeState(health, runningHere: runningHere) {
            return state
        }
        // Steam Helper writes the web file; one older than this start's health file is stale.
        let webShort = health.web.map { web in
            !web.isComplete && (web.written ?? .distantPast) >= (health.health?.written ?? .distantFuture)
        } ?? false
        if health.freshness == .live, health.health?.isComplete == false || webShort {
            return HeroState(
                headline: String(localized: "Partly working"),
                detail: String(localized: "Games may run with some features missing."),
                actions: pause)
        }
        // Steam is up, but this start left no report: the dylib never loaded or died early.
        // A .lastStart report is from an earlier start, so it says nothing about this one.
        if runningHere, health.freshness == .stale || health.freshness == .lastStart {
            return HeroState(
                headline: String(localized: "Not confirmed"),
                detail: String(localized: "Restart Steam. If it stays, send a report."),
                actions: pause)
        }
        // Games still play on the older WineCX, so this stays ready and says what's waiting.
        let upgrade = WinecxUpgrade.offer(snapshot).map {
            String(localized: "\(StatusHero.engineName($0.to)) is available below.")
        }
        if runningHere {
            return HeroState(headline: String(localized: "Ready to play"),
                             detail: upgrade ?? String(localized: "Press Play on any Windows game."),
                             ready: true, actions: pause)
        }
        return HeroState(headline: String(localized: "Ready to play"),
                         detail: upgrade ?? String(localized: "Open Steam and press Play."),
                         ready: true, actions: [.openSteam] + pause)
    }

    // Pause, the crash-loop breaker and the pause list. Steam started without the hooks
    // configures Windows games for macOS and drops their content, so these stay off
    // (SteamHealthStore.offModesEnabled) until an off mode keeps the compat layer on.
    private static func offModeState(_ health: HealthReading, runningHere: Bool) -> HeroState? {
        // Resumed while this Steam still runs without Bridgeplay: on again from its next start.
        // With Steam closed, the next start is a normal one.
        if !health.paused, health.mode == .off, runningHere {
            return HeroState(
                headline: String(localized: "Paused in Steam"),
                detail: String(localized: "Restart Steam to resume."),
                actions: [.pause])
        }
        if health.paused {
            // Pause takes effect at Steam's next start; until then Bridgeplay stays on.
            if runningHere, health.mode != .off, health.mode != .passive {
                return HeroState(
                    headline: String(localized: "Pausing at restart"),
                    detail: String(localized: "Still on until Steam restarts."),
                    actions: [.resume])
            }
            return HeroState(
                headline: String(localized: "Paused in Steam"),
                detail: String(localized: "Resume to play."),
                actions: [.resume])
        }
        // The signed pause list names this Steam build. Try Again can't lift it: a fixed
        // Bridgeplay, or the list dropping the build, does.
        if health.mode == .passive, let report = health.health, report.pausedByList {
            let detail = report.pauseFixedIn.map {
                String(localized: "Update to Bridgeplay \($0), then restart Steam.")
            } ?? String(localized: "Waiting on a Bridgeplay fix.")
            return HeroState(headline: String(localized: "Paused for this build"), detail: detail)
        }
        if health.mode == .passive {
            return HeroState(
                headline: String(localized: "Turned off"),
                detail: String(localized: "Steam kept closing at startup."),
                actions: [.tryAgain])
        }
        return nil
    }
}
