import SwiftUI
import BridgeplayUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case gameDefaults
    case prefixes
    case backups
    case guide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .gameDefaults: String(localized: "Game Defaults")
        case .prefixes: String(localized: "Prefixes")
        case .backups: String(localized: "Prefix Backups")
        case .guide: String(localized: "Guide")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .gameDefaults: "slider.horizontal.3"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .guide: "book"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane
    @Environment(SystemStatus.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .listItemTint(.monochrome)
            .scrollContentBackground(.hidden)
            .background(BP.bg)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 9) {
                    BridgeplayMark(size: 22)
                    Text(verbatim: "Bridgeplay")
                        .font(BP.display(13))
                        .foregroundStyle(BP.iridescent)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    credits
                    libraryCard
                    Text(verbatim: ProductVersion.display)
                        .font(BP.sans(11, .medium))
                        .foregroundStyle(BP.fg3)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch pane {
                case .status: StatusView()
                case .gameDefaults: GameDefaultsView()
                case .prefixes: PrefixesView()
                case .backups: BackupsView()
                case .guide: GuideView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // A failed move is reported on the Status page, with its buttons, instead.
                if MigrationLaunch.shared.pending, MigrationLaunch.shared.failure == nil {
                    MigrationBanner()
                } else if let banner = status.patchBanner {
                    PatchBanner(banner: banner)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let nudge = PlayReports.shared.nudge {
                    PlayReportCard(nudge: nudge)
                } else if PlayReports.shared.thanking {
                    PlayReportThanks()
                }
            }
            .scrollContentBackground(.hidden)
            .background(BP.bg)
            .toolbarBackground(BP.bg, for: .windowToolbar)
        }
        // While Report Your Games… is open, it presents the consent sheet itself.
        .sheet(isPresented: Binding(get: { PlayReports.shared.consentRequest != nil && PlayReports.shared.bulk == nil },
                                    set: { if !$0 { PlayReports.shared.consentRequest = nil } })) {
            PlayReportConsent()
        }
        .sheet(isPresented: Binding(get: { PlayReports.shared.bulk != nil },
                                    set: { if !$0 { PlayReports.shared.closeBulk() } })) {
            BulkReportSheet()
        }
        .font(BP.sans(13))
        .tint(BP.blue)
        .preferredColorScheme(.dark)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Credits")
                .font(BP.sans(11, .semibold))
                .foregroundStyle(BP.fg2)
            Text("A fork of [NotProton](https://github.com/NotProtonNot/NotProton), running on [CodeWeavers](https://www.codeweavers.com)' open-source Wine and Apple's Game Porting Toolkit.")
            Text("If CrossOver works for you, [buy it](https://www.codeweavers.com/crossover) to support Wine.")
        }
        .font(BP.sans(11))
        .foregroundStyle(BP.fg3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    // The landing page's games marquee in miniature, under the hero line.
    private var libraryCard: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .bottomLeading) {
                Aurora(t: t * 0.6, lean: 0.5)
                GameWall(t: t * 0.8)
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.92), location: 0.8)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Windows games.").foregroundStyle(BP.fg)
                    Text("In your Mac's Steam.").foregroundStyle(BP.iridescent)
                }
                .font(BP.sans(13, .semibold))
                .tracking(-0.2)
                .shadow(color: .black.opacity(0.8), radius: 6)
                .padding(12)
            }
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// Shown while the 3.0.0 folder move waits for Steam or a game to close.
private struct MigrationBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finishing the update to Bridgeplay 3")
                    .font(BP.sans(13, .semibold))
                Text(MigrationLaunch.shared.bannerMessage)
                    .font(BP.sans(12))
                    .foregroundStyle(BP.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BP.raise)
        .overlay(alignment: .bottom) { Rectangle().fill(BP.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}
