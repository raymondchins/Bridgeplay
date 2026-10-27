// 'Status' view, see SystemStatus for actual logic
import BridgeplayUI

import SwiftUI

enum StatusTone: Sendable {
    case ok, info, warning, bad, neutral

    var symbol: String {
        switch self {
        case .ok: "circle.fill"
        case .info: "circle"
        case .warning: "circle.fill"
        case .bad: "circle.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: BP.green
        case .info: BP.fg2
        case .warning: BP.orange
        case .bad: BP.red
        case .neutral: BP.fg3
        }
    }
}

struct StatusAction {
    let label: String
    var isProminent = false
    var role: ButtonRole?
    var help: String?
    var isEnabled = true
    var startsGroup = false
    let perform: () -> Void
}

enum StatusMetrics {
    static let symbolWidth: CGFloat = 10
    static let symbolSpacing: CGFloat = 8
    static var textInset: CGFloat { symbolWidth + symbolSpacing }
}

struct StatusRow: View {

    let title: String
    var value: String?

    var tone: StatusTone?
    var detail: String?
    var trailing: String?
    var secondaryAction: StatusAction?
    var action: StatusAction?
    var menu: [StatusAction] = []
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: StatusMetrics.symbolSpacing) {
                if let tone {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(tone.color)
                        .shadow(color: tone.color.opacity(tone == .ok || tone == .warning || tone == .bad ? 0.7 : 0), radius: 3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: StatusMetrics.symbolWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: StatusMetrics.symbolWidth, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BP.sans(13, .semibold))
                        .tracking(-0.1)
                    if let value {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if secondaryAction != nil || action != nil || !menu.isEmpty || toggle != nil || trailing != nil {
                Spacer(minLength: 12)
            }
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, action == nil && menu.isEmpty ? 0 : 8)
            }
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let secondaryAction {
                button(secondaryAction)
                    .disabled(!secondaryAction.isEnabled)
                    .help(secondaryAction.help ?? "")
                    .accessibilityLabel("\(secondaryAction.label), \(title)")
                    .padding(.trailing, 8)
            }
            if let action {
                button(action)
                    .disabled(!action.isEnabled)
                    .help(action.help ?? "")
                    .accessibilityLabel("\(action.label), \(title)")
            }
            if !menu.isEmpty {
                Menu {
                    menuItems(menu, hidingUnavailable: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions, \(title)")
                .padding(.leading, action == nil ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            menuItems([action, secondaryAction].compactMap { $0 } + menu, hidingUnavailable: true)
        }
    }

    @ViewBuilder
    private func menuItems(_ items: [StatusAction], hidingUnavailable: Bool) -> some View {
        let shown = hidingUnavailable ? items.filter(\.isEnabled) : items
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            Button(item.label, role: item.role, action: item.perform)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func button(_ action: StatusAction) -> some View {
        if action.isProminent {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.pill)
        } else {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.pillSecondary)
        }
    }
}

struct StatusView: View {
    @Environment(SystemStatus.self) private var status
    // Two of the Game Defaults (GameDefaults), read when the page opens; the switches write them straight away.
    @State private var metalHUD = GameDefaults.isOn(.metalHUD)
    @State private var highResolution = GameDefaults.isOn(.highResolution)
    @State private var gameDefaultsError: String?

    private static let updateBlockPrompt =
        String(localized: "Steam client updates may break Bridgeplay. If you don't want to wait for Bridgeplay to be updated to be compatible with future Steam versions at the cost of not getting updates to the Steam client, you can stop the Steam client from updating itself. You also miss Steam's security fixes.")

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Status")
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .confirmationDialog(
            String(localized: "Block Steam client updates?"),
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            String(localized: "Replace Steam with Valve's bundle?"),
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button("Replace Steam", role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(localized: "This will restore Steam itself to its original state but does not remove the support components used by Bridgeplay.")
            )
        }
        .confirmationDialog(
            status.pendingRemoval.map {
                String(localized: "Remove the \(SupportedRunners.displayVersion(forID: $0)) copy?")
            } ?? "",
            isPresented: asking(.removeBuild),
            titleVisibility: .visible
        ) {
            Button("Remove Copy", role: .destructive) {
                Task { await status.removePendingBuild() }
            }
            Button("Cancel", role: .cancel) { status.cancelBuildRemoval() }
        } message: {
            Text("CrossOver itself is not removed.")
        }
        .confirmationDialog(
            String(localized: "Remove everything Bridgeplay has created?"),
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Uninstall.confirmation())
        }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.installUnlicensed),
            titleVisibility: .visible
        ) {
            Button("Continue Anyway") {
                Task { await status.installIntoSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                CrossOverLicense.notActivatedAdvice
                    + String(localized: " Bridgeplay can be deployed, but the CrossOver compatibility tool cannot be installed without a valid license.")
            )
        }
        .task { if status.snapshot == nil { await status.refresh() } }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.toolUnlicensed),
            titleVisibility: .visible
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(CrossOverLicense.notActivatedAdvice)
        }
    }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func statusForm(_ snapshot: StatusSnapshot) -> some View {
        ScrollViewReader { proxy in
            form(snapshot)
                .onChange(of: status.highlightedRow) { _, row in
                    guard let row else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
        }
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            migrationRows

            if let failure = status.failure {
                StatusRow(
                    title: String(localized: "Failed"),
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    },
                    menu: ErrorReport.actions(failure, in: "Status")
                )
            } else if let outcome = status.outcome {
                StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok)
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: String(localized: "Template cleanup incomplete"), value: failure, tone: .warning)
            }

            if let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(DownloadMeter.shared.title ?? activity)
                        .foregroundStyle(.secondary)
                }
                DownloadStrip()
            }

            Section("Steam") {
                StatusRow(
                    title: String(localized: "Location"),
                    value: SupportPaths.Steam.app.path(percentEncoded: false),
                    action: StatusAction(
                        label: String(localized: "Choose\u{2026}"),
                        help: String(localized: "Use a copy of Steam from another folder or drive."),
                        isEnabled: status.isIdle
                    ) { Task { await status.chooseSteam() } }
                )
                steamRow(snapshot.steam, payload: snapshot.payload)
                if snapshot.steamRunning {
                    StatusRow(
                        title: String(localized: "Steam is running"),
                        value: String(localized: "Close Steam before continuing."),
                        tone: .info
                    )
                }
                updateBlockRow(snapshot.updateBlocked)
                controllerRow
                if status.signingIdentityReady == false {
                    StatusRow(
                        title: String(localized: "Trust Bridgeplay on this Mac"),
                        value: String(localized: "Keeps your controller working after Bridgeplay updates. Adds a certificate for this Mac to your login keychain. If macOS then asks for your password, choose Always Allow."),
                        tone: .info,
                        action: StatusAction(
                            label: String(localized: "Trust"),
                            isEnabled: status.isIdle
                        ) { Task { await status.trustThisMac() } }
                    )
                }
            }

            Section {
                crossOverSection(snapshot)
            } header: {
                Text("Engines")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add CrossOver\u{2026}") { Task { await status.addCrossOver() } }
                        .disabled(!status.isIdle)
                        .help("Add a copy of CrossOver from another folder.")
                }
            }

            gameDefaultsSection

            componentsSection(snapshot.payload)

            dangerSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) { StatusHero(snapshot: snapshot) }
    }

    // The 3.0 folder move: a failure blocks installing until it is tried again or skipped,
    // and files it could not move are named so they are not lost track of.
    @ViewBuilder
    private var migrationRows: some View {
        let migration = MigrationLaunch.shared
        if let failure = migration.failure {
            StatusRow(
                title: String(localized: "Moving to the Bridgeplay folders failed"),
                value: failure,
                tone: .bad,
                detail: String(localized: "Installing and setting up wait until the move is done. Skipping leaves your files in the old notproton folders and tries again at the next launch."),
                secondaryAction: StatusAction(
                    label: String(localized: "Skip"),
                    isEnabled: !migration.isRunning
                ) { migration.skip() },
                action: StatusAction(
                    label: String(localized: "Try Again"),
                    isProminent: true,
                    isEnabled: !migration.isRunning
                ) { Task { await migration.retry(status) } },
                menu: ErrorReport.actions(failure, in: "Folder move")
            )
        }
        if !migration.keptNotes.isEmpty {
            StatusRow(
                title: String(localized: "Some files stayed in the old folders"),
                value: String(localized: "The new Bridgeplay folders already had files with these names, so nothing was overwritten."),
                tone: .warning,
                detail: migration.keptNotes.joined(separator: "\n")
            )
        }
    }

    // A reset macOS refused leaves Steam's old approval in place, and macOS then blocks the
    // controller without asking. Only the user can clear it in System Settings.
    @ViewBuilder
    private var controllerRow: some View {
        if status.controllerResetFailures.isEmpty {
            StatusRow(
                title: String(localized: "Controller permission"),
                value: String(localized: "Clear Steam's controller permission so macOS asks for it again."),
                secondaryAction: StatusAction(label: String(localized: "Open Input Monitoring")) {
                    SystemStatus.openInputMonitoring()
                },
                action: StatusAction(
                    label: String(localized: "Reset"),
                    isEnabled: status.isIdle
                ) { Task { await status.resetControllerPermission() } }
            )
        } else {
            StatusRow(
                title: String(localized: "Controllers may not work"),
                value: String(localized: "macOS kept Steam's old controller permission. In Input Monitoring, turn Steam off and on again, then restart Steam."),
                tone: .warning,
                secondaryAction: StatusAction(
                    label: String(localized: "Try Again"),
                    isEnabled: status.isIdle
                ) { Task { await status.resetControllerPermission() } },
                action: StatusAction(label: String(localized: "Open Input Monitoring"), isProminent: true) {
                    SystemStatus.openInputMonitoring()
                }
            )
        }
    }

    private var gameDefaultsSection: some View {
        Section {
            StatusRow(title: String(localized: "Metal HUD"),
                      value: String(localized: "Shows frame rate and GPU details in a corner while you play."),
                      toggle: gameDefault(.metalHUD, $metalHUD))
            StatusRow(title: String(localized: "High Resolution"),
                      value: String(localized: "Sharper on Retina displays, but games run slower."),
                      toggle: gameDefault(.highResolution, $highResolution))
            if let gameDefaultsError {
                StatusRow(title: String(localized: "Something went wrong"), value: gameDefaultsError, tone: .bad,
                          menu: ErrorReport.actions(gameDefaultsError, in: "Game settings"))
            }
        } header: {
            Text("For Every Game")
        } footer: {
            Text("A game's own settings in Steam Properties › Bridgeplay win over these. Game Defaults has the rest.")
        }
    }

    private func gameDefault(_ setting: GameDefaults.Setting, _ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { on in
            value.wrappedValue = on
            do {
                try GameDefaults.set(setting, to: on)
                gameDefaultsError = nil
            } catch {
                gameDefaultsError = String(localized: "Bridgeplay could not save this setting. \(error.localizedDescription)")
            }
        })
    }

    private var dangerSection: some View {
        Section {
            StatusRow(
                title: String(localized: "Repair Steam"),
                value: String(localized: "Restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Repair"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: String(localized: "Remove Everything"),
                value: String(localized: "Remove Bridgeplay and restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Remove"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            AppUpdater.shared.check()
            Task {
                await status.refresh()
                await status.updateEverything()
            }
        }
        .help(String(localized: "Check for a Bridgeplay update and bring Steam and the engines up to date"))
        .disabled(!status.isIdle)
    }

    private func installAction(prominent: Bool, label: String = String(localized: "Install")) -> StatusAction {
        StatusAction(
            label: label,
            isProminent: prominent,
            help: String(localized: "Install Bridgeplay into Steam."),
            isEnabled: status.canInstall
        ) {
            Task { await status.requestInstall() }
        }
    }

    @ViewBuilder
    private func steamRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .notInstalled:
            if let content = status.snapshot?.installContent, content.blocksInstallation {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        case .installed, .outdated:
            if let content = status.snapshot?.installContent, content != .unchecked {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        default:
            deploymentRow(deployment, payload: payload)
        }
    }

    @ViewBuilder
    private func installedContentRow(_ content: DeploymentContent.Status, deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch content {
        case .unchecked, .current:
            let version: String? = switch deployment {
            case .installed(let version): version
            case .outdated(let deployed, _): deployed
            default: nil
            }
            deploymentRow(.installed(version: version), payload: payload)
        case .newerInstalled:
            StatusRow(title: "Bridgeplay", value: String(localized: "A newer build is installed."), tone: .neutral,
                      detail: String(localized: "Use the newer Bridgeplay app to update or repair the installed files."))
        case .unavailable(let reason):
            StatusRow(title: "Bridgeplay", value: String(localized: "Could not check installed files."), tone: .warning, detail: reason)
        case .update(let files):
            StatusRow(title: "Bridgeplay", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes newer files than those installed for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        case .repair(let files):
            StatusRow(title: "Bridgeplay", value: String(localized: "Installed files differ from this build."), tone: .warning,
                      detail: String(localized: "Restore the files included with this app."),
                      action: installAction(prominent: true, label: String(localized: "Repair")))
                .help(files.joined(separator: "\n"))
        case .unrecorded(let files):
            StatusRow(title: "Bridgeplay", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes updated files for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func deploymentRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .steamMissing:
            StatusRow(title: "Bridgeplay", value: String(localized: "Steam not found."), tone: .bad)
        case .notInstalled:
            StatusRow(
                title: "Bridgeplay",
                value: String(localized: "Not installed."),
                tone: .neutral,
                action: installAction(prominent: true)
            )
        case .installed(let version):
            if payload.isSteamComplete {
                StatusRow(
                    title: "Bridgeplay",
                    value: String(localized: "Installed") + (version.map { " (\(AppVersion.label(deployed: $0)))" } ?? ""),
                    tone: .ok
                )
            } else {
                StatusRow(
                    title: "Bridgeplay",
                    value: String(localized: "Steam integration needs repair."),
                    tone: .warning,
                    detail: steamRepairDetail(payload),
                    action: installAction(prominent: true)
                )
            }
        case .outdated:
            StatusRow(
                title: "Bridgeplay",
                value: String(localized: "Update available (\(ProductVersion.short))."),
                tone: .warning,
                action: installAction(prominent: true)
            )
        case .foreign:
            StatusRow(
                title: "Bridgeplay",
                value: String(localized: "Another dylib is present."),
                tone: .warning,
                detail: String(localized: "Repair your Steam install before installing Bridgeplay.")
            )
        }
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: String(localized: "Block Steam client updates"),
            value: blocked
                ? String(localized: "Steam updates are blocked, security fixes included.")
                : String(localized: "A Steam client update may break Bridgeplay."),
            tone: blocked ? .warning : nil,
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help("Steam client updates may break Bridgeplay.")
    }

    private var blockUpdates: Binding<Bool> {
        Binding(
            get: { status.snapshot?.updateBlocked ?? false },
            set: { wanted in
                if wanted {
                    status.pendingConfirmation = .blockUpdates
                } else {
                    Task { await status.setUpdateBlock(false) }
                }
            }
        )
    }

    @ViewBuilder
    private func crossOverSection(_ snapshot: StatusSnapshot) -> some View {
        let rows = status.crossOverRows
        if rows.isEmpty {
            StatusRow(
                title: "Wine Engine",
                value: String(localized: "None found. Download the free WineHQ or WineCX engine, or use CrossOver (\(SupportedRunners.versionList))."),
                tone: .bad
            )
        }
        let winehq = status.freeEngineState(FreeEngine.current.build)
        if winehq != .current {
            let outdated = winehq == .outdated
            StatusRow(
                title: "Free Wine Engine",
                value: outdated
                    ? "Needs \(FreeEngine.current.renderer.name) for fast Direct3D 11."
                    : "\(FreeEngine.current.bundleName.replacingOccurrences(of: ".app", with: "")) with \(FreeEngine.current.renderer.name), "
                        + "no CrossOver license needed.",
                tone: outdated ? .warning : .neutral,
                action: StatusAction(
                    label: outdated ? "Update & Set Up" : "Download & Set Up",
                    isProminent: rows.isEmpty,
                    help: "Download WineHQ and set the compatibility tool up from it.",
                    isEnabled: status.canInstall
                ) { Task { await status.installFreeEngine() } }
            )
        }
        let winecx = status.freeEngineState(FreeEngineWinecx.current.build)
        if winecx != .current {
            let outdated = winecx == .outdated
            StatusRow(
                title: "WineCX Engine",
                value: "\(FreeEngineWinecx.current.runner.releaseVersion) with msync and D3DMetal, "
                    + "no CrossOver license needed.",
                tone: outdated ? .warning : .neutral,
                action: StatusAction(
                    label: outdated ? "Update & Set Up" : "Download & Set Up",
                    isProminent: rows.isEmpty,
                    help: "Download WineCX and set the compatibility tool up from it.",
                    isEnabled: status.canInstall
                ) { Task { await status.installWinecxEngine() } }
            )
        }
        if let source = snapshot.gptkSource {
            StatusRow(
                title: "Game Porting Toolkit",
                value: "Linked from \(source).",
                tone: .ok
            )
        } else {
            StatusRow(
                title: "Game Porting Toolkit",
                value: "Not found. Copy the redist/lib folder of Apple's Game Porting Toolkit to "
                    + "~/Library/Application Support/\(SupportPaths.supportDirName)/gptk, then press Rescan.",
                tone: .neutral,
                action: StatusAction(
                    label: "Rescan",
                    help: "Look for the Game Porting Toolkit again and link it into the WineCX engine.",
                    isEnabled: status.canInstall
                ) { Task { await status.rescanGameportingToolkit() } }
            )
        }
        let tools = SupportedRunners.tools(for: snapshot.installedRunners)
        ForEach(rows) { row in
            StatusRow(
                title: row.title,
                value: crossOverValue(row),
                tone: crossOverTone(row),
                detail: crossOverDetail(row, tools: tools),
                trailing: row.copy == .ready ? buildSize(row.buildID) : nil,
                action: crossOverAction(row, prominent: snapshot.runner == .none),
                menu: crossOverMenu(row)
            )
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(-6)
                    .opacity(status.highlightedRow == row.id ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.3), value: status.highlightedRow == row.id)
            .id(row.id)
        }
        if case .ready = snapshot.runner, !snapshot.payload.missing(origin: .patched).isEmpty {
            StatusRow(
                title: String(localized: "Compatibility Tool"),
                value: String(localized: "Patched components are missing."),
                tone: .warning,
                action: StatusAction(
                    label: String(localized: "Repair"),
                    isProminent: true,
                    help: String(localized: "Set up the compatibility tool again."),
                    isEnabled: status.isIdle && status.setupSource != nil
                ) { Task { await status.requestCompatibilityTool() } }
            )
        }
    }

    private func crossOverValue(_ row: CrossOverRow) -> String {
        if let version = row.unsupportedVersion {
            return String(localized: "Version \(version) not supported (supported: \(SupportedRunners.versionList))")
        }
        let build = String(localized: "Build \(SupportedRunners.displayVersion(forID: row.buildID))")
        switch row.copy {
        case .ready: return build
        case .none: return build + (row.licensed == false ? String(localized: ", not set up or activated") : String(localized: ", not set up"))
        case .unpatched: return build + String(localized: ", not patched")
        case .damaged: return build + String(localized: ", copy damaged")
        case .unsupported: return build + String(localized: ", not supported")
        }
    }

    private func crossOverTone(_ row: CrossOverRow) -> StatusTone {
        if row.unsupportedVersion != nil { return .neutral }
        switch row.copy {
        case .none: return row.licensed == false ? .warning : .neutral
        case .ready: return .ok
        case .unpatched, .damaged, .unsupported: return .warning
        }
    }

    private func crossOverDetail(_ row: CrossOverRow, tools: [InstalledTool]) -> String? {
        var lines: [String] = []
        if row.copy == .ready || row.copy == .unpatched {
            let names = tools.filter { $0.build == row.buildID }.map(\.display)
            lines.append(contentsOf: names)
        }
        if row.copy == .none, row.licensed == false { lines.append("\(String(localized: "Open CrossOver to activate it.")) \(CrossOverLicense.trialUnsupported)") }
        if let install = row.install {
            var path = install.bundle.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            lines.append(path)
        } else if row.copy != .unsupported {
            lines.append(String(localized: "CrossOver app not found."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func crossOverAction(_ row: CrossOverRow, prominent: Bool) -> StatusAction? {
        let install = row.install
        switch row.copy {
        case .none where row.canSetUp:
            return StatusAction(
                label: String(localized: "Set Up"),
                isProminent: prominent,
                help: String(localized: "Copy \(row.title) and set up its compatibility tool."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unpatched where row.canSetUp, .damaged where row.canSetUp:
            return StatusAction(
                label: String(localized: "Repair"),
                isProminent: true,
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unsupported:
            return removeCopyAction(row.buildID, label: String(localized: "Remove\u{2026}"))
        default:
            return nil
        }
    }

    private func crossOverMenu(_ row: CrossOverRow) -> [StatusAction] {
        var items: [StatusAction] = []
        let install = row.install
        if row.copy == .ready {
            items.append(StatusAction(
                label: String(localized: "Reinstall"),
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall && row.canSetUp
            ) { Task { await status.requestCompatibilityTool(from: install, replacingExisting: true) } })
        }
        let shown = install?.bundle
            ?? (row.copy == .none ? nil : SupportPaths.runnerRoot(forBuild: row.buildID))
        if let shown {
            items.append(StatusAction(label: String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            })
        }
        if [.ready, .unpatched, .damaged].contains(row.copy) {
            var remove = removeCopyAction(row.buildID, label: String(localized: "Remove Copy\u{2026}"))
            remove.startsGroup = true
            items.append(remove)
        }
        if let install, row.isManual {
            items.append(StatusAction(
                label: String(localized: "Remove from List"),
                isEnabled: status.isIdle,
                startsGroup: !items.contains(where: \.startsGroup)
            ) { Task { await status.removeFromList(install) } })
        }
        return items
    }

    private func buildSize(_ build: String) -> String? {
        guard let runner = status.runnerSizes[build] else { return nil }
        let flavors = SupportedRunners.build(id: build)?.tools.map(\.flavor) ?? []
        return Self.sizeText(runner: runner, templates: status.templateSizes[build] ?? [:], flavors: flavors)
    }

    nonisolated static func sizeText(runner: Int64, templates: [CompatTool.Flavor: Int64], flavors: [CompatTool.Flavor]) -> String {
        let lines: [String]
        if flavors.count > 1 {
            lines = flavors.compactMap { flavor in
                guard let bytes = templates[flavor], bytes > 0 else { return nil }
                return String(localized: "\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))")
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? [String(localized: "Templates \(bytes.formatted(.byteCount(style: .file)))")] : []
        }
        return ([String(localized: "Runner \(runner.formatted(.byteCount(style: .file)))")] + lines).joined(separator: "\n")
    }

    private func removeCopyAction(_ build: String, label: String) -> StatusAction {
        StatusAction(
            label: label,
            role: .destructive,
            help: String(localized: "Delete Bridgeplay's copy of this build."),
            isEnabled: status.canInstall
        ) {
            status.requestBuildRemoval(build)
        }
    }

    private func steamRepairDetail(_ payload: PayloadState) -> String {
        if let problem = payload.manifestProblem { return problem }
        var names = payload.missingSteamFiles
        if payload.signatureDatabase == nil { names.append(String(localized: "Signature database")) }
        return String(localized: "Missing: \(names.joined(separator: ", ")). Install to restore these files for your macOS user.")
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: String(localized: "Fetch Valve Binaries"),
            isProminent: true,
            help: String(localized: "Download missing Valve binaries."),
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        if let problem = payload.manifestProblem {
            Section("Bridgeplay Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Component list unreadable."), tone: .bad, detail: problem)
            }
        } else if payload.isComplete {
            Section("Bridgeplay Components") {
                StatusRow(
                    title: String(localized: "Components"), value: String(localized: "Ready."), tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? String(localized: "Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))") : nil
                )
            }
        } else if payload.isEmpty {
            Section("Bridgeplay Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Not yet deployed."), tone: .neutral)
            }
        } else {
            Section("Bridgeplay Components") {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map(\.path).joined(separator: ", ")
                    StatusRow(
                        title: String(localized: "Missing."),
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: String(localized: "Overlay shim"), value: String(localized: "Missing."), tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: String(localized: "Signature database"), value: String(localized: "Missing."), tone: .bad)
                }
            }
        }
    }
}

// Shown above every pane when Steam lost Bridgeplay (or has an older copy) and Bridgeplay
// could not put it back on its own. One button; the install flow does the rest.
struct PatchBanner: View {
    @Environment(SystemStatus.self) private var status
    let banner: SteamPatchKeeper.Banner

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.headline)
                Text(banner.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if status.activity != nil {
                ProgressView().controlSize(.small)
            }
            Button(banner.button) { Task { await status.reapplyFromBanner() } }
                .buttonStyle(.borderedProminent)
                .disabled(!banner.canApply || !status.isIdle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
