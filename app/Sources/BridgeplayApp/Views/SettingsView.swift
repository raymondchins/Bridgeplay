import SwiftUI
import BridgeplayUI

// Bridgeplay › Settings… (⌘,): the app's own preferences, the same controls the Status page and
// the menus have, gathered in one place.
struct SettingsView: View {
    @Environment(SystemStatus.self) private var status
    @Environment(\.openWindow) private var openWindow
    @State private var askingBlock = false
    @State private var background = BackgroundItem.State.off
    @State private var backgroundMode = BackgroundCheck.Mode.off
    @State private var backgroundError: String?
    // A failed Choose… or Block Updates, shown on its row: Settings has no failure banner.
    @State private var steamFailure: String?
    @State private var blockFailure: String?

    var body: some View {
        Form {
            steamSection
            Section {
                StatusRow(
                    title: "Bridgeplay \(ProductVersion.short)",
                    action: StatusAction(label: String(localized: "Check for Updates…")) { AppUpdater.shared.check() }
                )
            } header: {
                Text(verbatim: "Bridgeplay")
            }
            BetaUpdatesSection()
            Section("Privacy") {
                StatusRow(
                    title: String(localized: "Auto-Share Reports"),
                    toggle: autoShare
                )
            }
            Section("Troubleshooting") {
                StatusRow(
                    title: String(localized: "Bridgeplay Log"),
                    value: AppLog.file.path(percentEncoded: false),
                    secondaryAction: StatusAction(label: String(localized: "Report a Problem…")) { HelpLinks.reportProblem() },
                    action: StatusAction(label: String(localized: "Show Log")) { ErrorReport.showLog() }
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BP.bg)
        .frame(width: 600)
        .frame(minHeight: 420)
        .font(BP.sans(13))
        .tint(BP.accent)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            String(localized: "Block Steam client updates?"),
            isPresented: $askingBlock,
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                setUpdateBlock(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The same words as the Status page's dialog.
            Text("Blocking updates can keep Bridgeplay working, but Steam will miss security fixes.")
        }
    }

    private var steamSection: some View {
        Section("Steam") {
            StatusRow(
                title: String(localized: "Location"),
                value: SupportPaths.Steam.app.path(percentEncoded: false),
                tone: steamFailure != nil ? .warning : nil,
                detail: steamFailure,
                action: StatusAction(
                    label: String(localized: "Choose\u{2026}"),
                    isEnabled: status.isIdle
                ) { Task { steamFailure = await failure { await status.chooseSteam() } } }
            )
            let blocked = status.snapshot?.updateBlocked ?? false
            StatusRow(
                title: String(localized: "Block Steam Updates"),
                value: blocked
                    ? String(localized: "Security fixes are blocked too.")
                    : String(localized: "Updates may break Bridgeplay."),
                tone: blocked || blockFailure != nil ? .warning : nil,
                detail: blockFailure,
                toggle: Binding(
                    get: { status.snapshot?.updateBlocked ?? false },
                    set: { wanted in
                        if wanted { askingBlock = true } else { setUpdateBlock(false) }
                    }
                )
            )
            .disabled(!status.isIdle || status.snapshot == nil)
            backgroundRow
        }
    }

    private func setUpdateBlock(_ blocked: Bool) {
        Task { blockFailure = await failure { await status.setUpdateBlock(blocked) } }
    }

    // The failure this action set, or nil when it worked, was cancelled or never ran.
    private func failure(of action: () async -> Void) async -> String? {
        let before = status.failureCount
        await action()
        return status.failureCount != before ? status.failure : nil
    }

    // Opt-in: a login agent that notices a Steam update while Bridgeplay is closed.
    private var backgroundRow: some View {
        let on = background == .on || background == .needsApproval
        let value = switch background {
        case .off: String(localized: "Alerts while Bridgeplay is closed.")
        case .on: backgroundMode == .reapply
            ? String(localized: "Restores Bridgeplay after Steam quits.")
            : String(localized: "Alerts when Steam drops Bridgeplay.")
        case .needsApproval: String(localized: "Allow it in Login Items.")
        case .unavailable: String(localized: "Not in this build.")
        }
        return StatusRow(
            title: String(localized: "Background Check"),
            value: value,
            tone: background == .needsApproval || backgroundError != nil ? .warning : nil,
            detail: backgroundError,
            action: background == .needsApproval
                ? StatusAction(label: String(localized: "Open Login Items")) { BackgroundItem.openLoginItems() }
                : nil,
            menu: on ? [StatusAction(label: backgroundMode == .reapply
                                        ? String(localized: "Notify Only")
                                        : String(localized: "Auto-Restore")) {
                setBackground(backgroundMode == .reapply ? .notify : .reapply)
            }] : [],
            toggle: Binding(get: { on }, set: { setBackground($0 ? .notify : .off) })
        )
        .disabled(background == .unavailable)
        .onAppear(perform: readBackground)
        // Login Items approval and the agent's mode change outside the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readBackground()
        }
    }

    private func setBackground(_ mode: BackgroundCheck.Mode) {
        do {
            background = try BackgroundItem.set(mode)
            backgroundError = nil
        } catch {
            AppLog.note("background check: \(mode.rawValue) failed: \(error.localizedDescription)")
            backgroundError = error.localizedDescription
        }
        readBackground()
    }

    private func readBackground() {
        background = BackgroundItem.current()
        backgroundMode = BackgroundCheck.mode()
    }

    // Turning it on the first time asks for consent, in the main window like every other report.
    private var autoShare: Binding<Bool> {
        Binding(
            get: { PlayReports.shared.autoShare },
            set: { on in
                PlayReports.shared.setAutoShare(on)
                if PlayReports.shared.consentRequest != nil { openWindow(id: "main") }
            }
        )
    }
}
