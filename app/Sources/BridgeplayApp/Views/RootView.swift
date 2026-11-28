import SwiftUI
import BridgeplayUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case games
    case gameDefaults
    case prefixes
    case backups
    case guide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .games: String(localized: "Games")
        case .gameDefaults: String(localized: "Game Defaults")
        case .prefixes: String(localized: "Prefixes")
        case .backups: String(localized: "Prefix Backups")
        case .guide: String(localized: "Guide")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .games: "gamecontroller"
        case .gameDefaults: "slider.horizontal.3"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .guide: "book"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane
    var showsSetup = false
    @Environment(SystemStatus.self) private var status
    @Environment(PrefixesModel.self) private var prefixes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Ambient motion stops while the window is in the background
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(spacing: 0) {
            // Above NavigationSplitView, not inside its detail column: NavigationSplitView
            // mis-reconciles its two columns' geometry once the detail column's content has
            // resized more than once after the initial layout pass, which a banner that
            // only starts showing after launch (the patch check, a background update
            // finishing) and then keeps changing (an update's progress stages) reliably
            // triggers, shifting the whole window's content — sidebar included — off-screen.
            // Living outside the split view entirely sidesteps that.
            if MigrationLaunch.shared.pending, MigrationLaunch.shared.failure == nil {
                MigrationBanner()
            } else if let banner = status.patchBanner {
                PatchBanner(banner: banner)
            }
            UpdateNotice(busy: status.isBusy || prefixes.isBusy)

            NavigationSplitView {
                // Bridgeplay's own selection: near-white type on a hairline tile, not the
                // system's accent fill or its grey inactive one.
                // Plain buttons, not List rows: a table view takes the click first, which made
                // a page change feel like it hadn't registered.
                // No gaps between rows: each row's 2 pt margins are part of its click area
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Pane.allCases) { item in
                        SidebarItem(item: item, selected: pane == item) { pane = item }
                    }
                    Spacer(minLength: 0)
                }
                // The click that brings the window forward also picks the page, as in a
                // system sidebar, instead of only activating the window
                .allowsWindowActivationEvents(true)
                // 16 + the item's 10 puts the icons under the logo mark (leading 26)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // No background of its own: the sidebar floats as Liquid Glass over the
                // window, which sets it apart from the opaque page (HIG: Sidebars)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // The mark centred over the menu's icons, the wordmark over their labels
                    // (SidebarItem: 16 inset + 10 padding, an 18 wide icon, 9 spacing)
                    HStack(spacing: 9) {
                        BridgeplayMark(size: 26, tile: false)
                            .frame(width: 18)
                        Text(verbatim: "Bridgeplay")
                            .font(BP.display(14))
                            .foregroundStyle(BP.fg)
                        Spacer()
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 12)
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
                    case .status: StatusView(openPane: { pane = $0 })
                    case .games: GamesView()
                    case .gameDefaults: GameDefaultsView()
                    case .prefixes: PrefixesView()
                    case .backups: BackupsView()
                    case .guide: GuideView()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Not over a play report question. StarPrompt.check waits for the scan that may raise one.
                    let reports = PlayReports.shared
                    let shows = StarPrompt.shared.pending && !reports.isAsking && !showsSetup && !MigrationLaunch.shared.pending
                    ZStack {
                        if shows {
                            StarPromptCard()
                                .padding(16)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.45, bounce: 0.18), value: shows)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let nudge = PlayReports.shared.nudge {
                        PlayReportCard(nudge: nudge)
                    } else if PlayReports.shared.thanking {
                        PlayReportThanks()
                    }
                }
                .scrollContentBackground(.hidden)
                // The toolbar keeps the system's glass and scroll edge effect (HIG: Toolbars)
                .background(BP.bg)
            }
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
        .tint(BP.accent)
        .preferredColorScheme(.dark)
        // The window closed: a Later for the star card, which stays away this run.
        .onDisappear { StarPrompt.shared.later() }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One credit per line, each short enough not to wrap in the sidebar
            VStack(alignment: .leading, spacing: 2) {
                Text("Fork of [NotProton](https://github.com/NotProtonNot/NotProton)")
                Text("Wine by [CodeWeavers](https://www.codeweavers.com)")
                Text("Game Porting Toolkit by Apple")
            }
            Text("[Buy CrossOver](https://www.codeweavers.com/crossover) to support Wine.")
                // Wraps in a longer language rather than ending in "…" in a short window
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(BP.sans(11))
        .lineSpacing(2)
        .foregroundStyle(BP.fg3)
        .tint(BP.fg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var libraryCard: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
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

private struct SidebarItem: View {
    let item: Pane
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        // The Button gives Tab focus, Space and VoiceOver; the gesture picks the page earlier
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? BP.accent : BP.fg3)
                Text(item.label)
                    .font(BP.sans(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? BP.fg : BP.fg2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Color.white.opacity(selected ? 0.09 : (hovered ? 0.04 : 0))))
            .overlay(shape.strokeBorder(selected ? BP.line : .clear, lineWidth: 1))
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Picks the page on mouse down, as Finder's and Mail's sidebars do. A Button acts on
        // mouse up, and drops the click when the page redraws between down and up.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in if !selected { select() } })
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
