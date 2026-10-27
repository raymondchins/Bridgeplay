// Self-explanatory

import SwiftUI

struct BridgeplayApp: App {

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    @State private var pane: Pane = .status
    @State private var showsSetup = false
    private let updater = AppUpdater.shared

    var body: some Scene {
        Window("Bridgeplay", id: "main") {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 800, minHeight: 600)
                .onChange(of: pane) { prefixes.forgetOutcome() }
                .onChange(of: status.snapshot?.installedRunners.map(\.id)) {
                    if prefixes.hasLoaded { Task { await prefixes.load() } }
                }
                .task { await MigrationLaunch.shared.finishWhenPossible(status) }
                .onChange(of: status.snapshot == nil, initial: true) {
                    if MigrationLaunch.shared.pending { return }
                    if SetupAssistant.shouldShow(status.snapshot) {
                        showsSetup = true
                    } else if status.snapshot != nil {
                        checkSteamPatch("launch")
                    }
                }
                // A Steam client update rewrites Steam.app and drops Bridgeplay with it, so
                // look again whenever the user comes back and every few minutes.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    checkSteamPatch("foreground")
                    PlayReports.shared.scan()
                }
                .task { PlayReports.shared.scan() }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: SteamPatchKeeper.pollInterval)
                        checkSteamPatch("timer")
                    }
                }
                .onChange(of: status.snapshot?.steam, initial: true) { refreshAfterUpdate() }
                .onChange(of: status.isIdle) { refreshAfterUpdate() }
                .sheet(isPresented: $showsSetup) {
                    SetupAssistantView()
                        .environment(status)
                        .interactiveDismissDisabled()
                }
        }
        .defaultSize(width: 900, height: 760)
        .commands { menus }
    }

    private func checkSteamPatch(_ trigger: String) {
        guard status.snapshot != nil, !MigrationLaunch.shared.pending else { return }
        Task { await status.checkSteamPatch(trigger: trigger, setupShowing: showsSetup) }
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .appInfo) {
            Button("About Bridgeplay") { AboutPanel.show() }
            Button("Check for Updates…") { updater.check() }
        }

        CommandGroup(after: .sidebar) {
            Button("Status") { pane = .status }
                .keyboardShortcut("1", modifiers: .command)
            Button("Prefixes") { pane = .prefixes }
                .keyboardShortcut("2", modifiers: .command)
            Button("Prefix Backups") { pane = .backups }
                .keyboardShortcut("3", modifiers: .command)
            Button("Guide") { pane = .guide }
                .keyboardShortcut("4", modifiers: .command)
            Button("Game Defaults") { pane = .gameDefaults }
                .keyboardShortcut("5", modifiers: .command)

            Divider()

            Button("Refresh") {
                Task {
                    switch pane {
                    case .status, .guide, .gameDefaults: await status.refresh()
                    case .prefixes, .backups: await prefixes.load()
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(pane == .status || pane == .guide || pane == .gameDefaults ? !status.isIdle : prefixes.isLoading)

            Divider()
        }

        CommandMenu("Setup") {
            Button("Setup Assistant…") { showsSetup = true }
                .disabled(!status.isIdle || MigrationLaunch.shared.pending)

            Divider()

            Button("Install") { Task { await status.requestInstall() } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!status.canInstall)

            Button("Set Up Compatibility Tool") { Task { await status.requestCompatibilityTool() } }
                .disabled(!status.canInstall || status.setupSource == nil)

            Button("Fetch Valve Binaries") { Task { await status.fetchValveBinaries() } }
                .disabled(!status.canInstall)

            Divider()

            updateBlockCommand

            Button("Repair Steam") { status.pendingConfirmation = .replaceSteam }
                .disabled(!status.isIdle)

            Divider()

            Button("Reveal Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
            }
        }

        prefixMenu
    }

    // After Sparkle relaunches into a newer build, bring the patch in Steam up to date
    // once it is safe to; the setup assistant handles a first install itself.
    private func refreshAfterUpdate() {
        guard !showsSetup, !MigrationLaunch.shared.pending else { return }
        Task { await PostUpdateRefresh.runIfNeeded(status) }
    }

    @CommandsBuilder
    private var prefixMenu: some Commands {
        CommandMenu("Prefix") {
            Button("Run Program…") {
                if let prefix = prefixTarget { prefixes.chooseExecutable(for: prefix) }
            }
            .disabled(prefixTarget == nil)

            Divider()

            ForEach(WineTool.allCases, id: \.self) { tool in
                Button(tool.label) {
                    if let prefix = prefixes.selectedPrefix { prefixes.open(tool, for: prefix) }
                }
                .disabled(prefixTarget == nil)
            }

            Divider()

            Button("Reveal in Finder") {
                if let prefix = prefixes.selectedPrefix { prefixes.reveal(prefix) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(prefixes.selectedPrefix == nil)

            Button("Report Your Games…") { PlayReports.shared.openBulk() }
            Toggle("Share Play Reports Automatically", isOn: Binding(
                get: { PlayReports.shared.autoShare }, set: { PlayReports.shared.setAutoShare($0) }))

            Divider()

            Button(PrefixPrompt.backUpButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .backUp(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)

            if prefixes.tools.count > 1 {
                Menu(PrefixPrompt.rebuildButton(selectionTargets)) {
                    ForEach(prefixes.tools) { tool in
                        Button(tool.display) {
                            prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                        }
                    }
                }
                .disabled(selectionTargets.isEmpty)
            } else {
                Button(PrefixPrompt.rebuildButton(selectionTargets)) {
                    if let tool = prefixes.tools.first, !selectionTargets.isEmpty {
                        prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                    }
                }
                .disabled(selectionTargets.isEmpty || prefixes.tools.isEmpty)
            }

            Button(PrefixPrompt.deleteButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .delete(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)
        }
    }

    private var prefixTarget: WinePrefix? {
        prefixes.isBusy ? nil : prefixes.selectedPrefix
    }

    private var selectionTargets: [WinePrefix] {
        prefixes.isBusy ? [] : prefixes.selectedPrefixes
    }

    @ViewBuilder
    private var updateBlockCommand: some View {
        if status.snapshot?.updateBlocked == true {
            Button("Allow Client Updates") { Task { await status.setUpdateBlock(false) } }
                .disabled(!status.isIdle)
        } else {
            Button("Block Client Updates") { status.pendingConfirmation = .blockUpdates }
                .disabled(!status.isIdle || status.snapshot == nil)
        }
    }
}
