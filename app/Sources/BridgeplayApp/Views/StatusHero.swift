import SwiftUI
import BridgeplayUI

// The top of the Status page: the landing page's aurora behind one plain answer to "can I
// play?", with the engine, graphics and Steam state as chips underneath.
struct StatusHero: View {
    let snapshot: StatusSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate * 0.6
            ZStack(alignment: .leading) {
                Aurora(t: t, lean: lean)
                GridLines()
                HStack(spacing: 18) {
                    BridgeplayMark(size: 52)
                        .shadow(color: BP.violet.opacity(0.45), radius: 18)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline)
                            .font(BP.sans(24, .semibold))
                            .tracking(-0.7)
                            .foregroundStyle(ready ? AnyShapeStyle(BP.iridescent) : AnyShapeStyle(BP.fg))
                        Text(detail)
                            .font(BP.sans(13))
                            .foregroundStyle(BP.fg2)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            ForEach(chips, id: \.self) { chip in
                                Text(chip)
                                    .font(BP.sans(11, .semibold))
                                    .foregroundStyle(BP.fg)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
            }
        }
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(BP.bg)
    }

    private var ready: Bool {
        if case .installed = snapshot.steam { return !snapshot.currentFreeEngines.isEmpty }
        return false
    }

    // Steam can hold a newer Bridgeplay than this app (an older copy was opened).
    private var newerInSteam: Bool { snapshot.installContent == .newerInstalled }

    private var lean: Float {
        switch snapshot.steam {
        case .installed: 0.5
        case .outdated: 0.8
        default: 0.15
        }
    }

    private var headline: String {
        if newerInSteam { return String(localized: "Steam has a newer build") }
        return switch snapshot.steam {
        case .installed: ready ? String(localized: "Ready to play") : String(localized: "Almost ready")
        case .outdated: String(localized: "Update ready")
        case .notInstalled: String(localized: "Not set up yet")
        case .steamMissing: String(localized: "Steam not found")
        case .foreign: String(localized: "Steam is modified")
        }
    }

    private var detail: String {
        if newerInSteam { return String(localized: "This copy of Bridgeplay is older than the one in Steam. Open the newer app.") }
        return switch snapshot.steam {
        case .installed:
            ready ? String(localized: "Open Steam and press Play on any Windows game.")
                  : String(localized: "Install the WineCX engine below to finish.")
        case .outdated: String(localized: "Install the newer Bridgeplay into Steam below.")
        case .notInstalled: String(localized: "Install Bridgeplay into Steam below, or run the Setup Assistant.")
        case .steamMissing: String(localized: "Install Steam, or choose where your copy is.")
        case .foreign: String(localized: "Another tool changed Steam. Repair Steam to use Bridgeplay.")
        }
    }

    private var chips: [String] {
        var chips: [String] = []
        let engines = snapshot.currentFreeEngines
        let preferred = engines.contains(FreeEngineWinecx.current.build) ? FreeEngineWinecx.current.build : engines.sorted().last
        if let preferred { chips.append(Self.engineName(preferred)) }
        chips.append(snapshot.gptkSource == nil ? "DXMT" : "D3DMetal")
        if snapshot.steamRunning { chips.append(String(localized: "Steam running")) }
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
