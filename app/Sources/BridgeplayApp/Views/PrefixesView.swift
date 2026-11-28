// Prefix management UI inside Bridgeplay, also see PrefixesModel

import BridgeplayUI
import SwiftUI

struct PrefixesView: View {

    @Environment(PrefixesModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\PrefixRow.lastUsed, order: .reverse)]
    @State private var winetricksPrefix: WinePrefix?
    @State private var winetricksVerbs = ""

    var body: some View {
        Group {
            if !model.hasLoaded {
                SkeletonTable(label: String(localized: "Looking for prefixes"))
            } else if model.prefixes.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Prefixes"),
                    systemImage: "externaldrive",
                    description: Text(
                        String(localized: "Launch a Windows game with Bridgeplay.")
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle("Prefixes")
        .safeAreaInset(edge: .bottom) {
            if let failed = model.report {
                report(
                    StatusRow(
                        title: String(localized: "Failed"),
                        value: failed.message,
                        tone: .bad,
                        action: failed.settingsPane.map { pane in
                            StatusAction(label: Remedy.settingsButton) { Remedy.openSettings(pane) }
                        },
                        menu: ErrorReport.actions(failed.message, in: "Prefixes")
                    )
                )
            } else if let outcome = model.outcome {
                report(
                    StatusRow(
                        title: String(localized: "Done"),
                        value: outcome,
                        tone: .ok
                    )
                )
            }
        }
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItemGroup(placement: .primaryAction) { strip }
                    .visibilityPriority(.high)
            } else {
                ToolbarItemGroup(placement: .primaryAction) { strip }
            }
        }
        .task { await model.load() }
        .prefixDialogs()
        .alert(
            "Winetricks",
            isPresented: Binding(
                get: { winetricksPrefix != nil },
                set: { if !$0 { winetricksPrefix = nil } }
            ),
            presenting: winetricksPrefix
        ) { prefix in
            TextField("vcrun2022 corefonts", text: $winetricksVerbs)
            Button("Install") {
                let verbs = winetricksVerbs
                Task { await model.winetricks(verbs, in: prefix) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(PrefixTools.winetricksVerbs(winetricksVerbs).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { prefix in
            Text("Verbs for \(prefix.title), separated by spaces.")
        }
    }

    @ViewBuilder
    private var strip: some View {
        Menu {
            toolButtons(for: model.selectedPrefix)
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(model.selectedPrefix == nil || model.isBusy)
        .help("Run a program or Wine tool.")

        Button("Reveal in Finder", systemImage: "folder") {
            if let prefix = model.selectedPrefix { model.reveal(prefix) }
        }
        .disabled(model.selectedPrefix == nil)
        .help("Show in Finder.")

        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("Reload the list.")
    }

    private func lastUsed(_ prefix: WinePrefix) -> String {
        prefix.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Never")
    }

    private var libraryWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(\.library.displayName)) ?? 120
    }

    private var toolWidth: CGFloat {
        TextWidth.widest(model.prefixes.compactMap(model.lastTool)) ?? 60
    }

    private var lastUsedWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(lastUsed)) ?? 110
    }

    private var gameWidth: CGFloat {
        let widths = model.prefixes.map { prefix -> CGFloat in
            var width = min(TextWidth.of(prefix.title), TextWidth.maxTitle)
            if model.isStale(prefix) { width += 22 }
            if prefix.name == nil {
                width += TextWidth.of(String(localized: "Uninstalled"), size: NSFont.smallSystemFontSize) + 6
            }
            return width
        }
        guard let widest = widths.max() else { return 240 }
        return widest + TextWidth.cellPadding
    }

    private struct PrefixRow: Identifiable {
        let prefix: WinePrefix
        let tool: String
        let appID: Int
        let size: Int64
        let title: String
        let library: String
        let lastUsed: Date
        let shaderCache: Int64

        var id: WinePrefix.ID { prefix.id }
    }

    private var rows: [PrefixRow] {
        model.prefixes.map { prefix in
            PrefixRow(
                prefix: prefix,
                tool: model.lastTool(prefix) ?? "",
                appID: Int(prefix.appID) ?? 0,
                size: model.usage[prefix.id]?.bytes ?? -1,
                title: prefix.title,
                library: prefix.library.displayName,
                lastUsed: prefix.lastUsed ?? .distantPast,
                shaderCache: model.shaderCaches[prefix.id]?.bytes ?? -1
            )
        }
        .sorted(using: sortOrder)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Game", value: \.title) { row in
                let prefix = row.prefix
                HStack(spacing: 6) {
                    if model.isStale(prefix) {
                        Menu {
                            rebuildChoices([prefix])
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(BP.orange)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isBusy || model.tools.isEmpty)
                        .accessibilityLabel("Needs rebuilding")
                        .help(String(localized: "Needs rebuilding"))
                    }
                    Text(prefix.title).lineLimit(1).help(prefix.title)
                    if prefix.name == nil {
                        Text("Uninstalled")
                            .font(.caption)
                            .modifier(CellGrey())
                            .fixedSize()
                    }
                    if model.busy.contains(prefix.id) {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Working…")
                    }
                }
            }
            .width(min: 60, ideal: gameWidth)

            TableColumn("Tool", value: \.tool) { row in
                let prefix = row.prefix
                if let tool = model.lastTool(prefix) {
                    Text(tool).modifier(CellGrey()).help(tool)
                } else {
                    Text("None")
                        .modifier(CellGrey(faint: true))
                }
            }
            .width(min: 60, ideal: toolWidth)

            TableColumn("App ID", value: \.appID) { row in
                Text(row.prefix.appID).monospacedDigit().modifier(CellGrey())
            }
            .width(min: 50, ideal: 80)

            TableColumn("Library", value: \.library) { row in
                Text(row.library)
                    .modifier(CellGrey())
                    .help(row.library)
            }
            .width(min: 44, ideal: libraryWidth)

            TableColumn("Size", value: \.size) { row in
                if let usage = model.usage[row.id] {
                    Text(usage.bytes.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .modifier(CellGrey())
                } else {
                    Text("Calculating…")
                        .modifier(CellGrey(faint: true))
                }
            }
            .width(min: 56, ideal: 90)

            TableColumn("Shaders", value: \.shaderCache) { row in
                if let cache = model.shaderCaches[row.id] {
                    if cache.isEmpty {
                        Text("None").modifier(CellGrey(faint: true))
                    } else {
                        Text(cache.bytes.formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                            .modifier(CellGrey())
                    }
                } else {
                    Text("Calculating…")
                        .modifier(CellGrey(faint: true))
                }
            }
            .width(min: 56, ideal: 90)

            TableColumn("Used", value: \.lastUsed) { row in
                Text(lastUsed(row.prefix))
                    .modifier(CellGrey())
                    .help(lastUsed(row.prefix))
            }
            .width(min: 60, ideal: lastUsedWidth)

        }
        .contextMenu(forSelectionType: WinePrefix.ID.self) { ids in
            actions(for: ids)
        }
        .onDeleteCommand {
            let targets = model.selectedPrefixes
            if !model.isBusy, !targets.isEmpty {
                model.pendingConfirmation = .delete(targets)
            }
        }
    }

    @ViewBuilder
    private func actions(for ids: Set<WinePrefix.ID>) -> some View {
        let targets = model.prefixes.filter { ids.contains($0.id) }
        Group {
            if let prefix = single(ids) {
                toolButtons(for: prefix)
                Divider()
                Button("Reveal in Finder") { model.reveal(prefix) }
                Menu("Open Log") {
                    ForEach(PrefixLog.allCases, id: \.self) { log in
                        Button(log.label) { model.open(log, for: prefix) }
                            .disabled(!model.hasLog(log, for: prefix))
                    }
                }
                Button("Report This Game…") { PlayReports.shared.ask(about: prefix) }
                let kept = model.backups(of: prefix)
                if !kept.isEmpty {
                    Menu("Restore Backup") {
                        ForEach(kept) { backup in
                            Button(taken(backup)) { model.pendingConfirmation = .restore(backup) }
                        }
                    }
                }
            }
            Button("Report Your Games…") { PlayReports.shared.openBulk() }
            if !targets.isEmpty {
                Divider()
                Button(PrefixPrompt.backUpButton(targets)) {
                    model.pendingConfirmation = .backUp(targets)
                }
                if model.tools.count > 1 {
                    Menu(PrefixPrompt.rebuildButton(targets)) { rebuildChoices(targets) }
                } else {
                    rebuildChoices(targets, label: PrefixPrompt.rebuildButton(targets))
                }
                let cached = targets.filter { !(model.shaderCaches[$0.id]?.isEmpty ?? true) }
                if !cached.isEmpty {
                    Button(PrefixPrompt.clearShaderCacheButton(cached) + "…") {
                        model.pendingConfirmation = .clearShaderCache(cached)
                    }
                }
                Button(PrefixPrompt.deleteButton(targets), role: .destructive) {
                    model.pendingConfirmation = .delete(targets)
                }
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func rebuildChoices(_ targets: [WinePrefix], label: String? = nil) -> some View {
        ForEach(model.tools) { tool in
            Button(label ?? tool.display) {
                model.pendingConfirmation = .rebuild(targets, tool)
            }
        }
    }

    @ViewBuilder
    private func toolButtons(for prefix: WinePrefix?) -> some View {
        Button("Run Program…") {
            if let prefix { model.chooseExecutable(for: prefix) }
        }
        Button("Winetricks…") {
            winetricksPrefix = prefix
        }
        Divider()
        ForEach(WineTool.allCases, id: \.self) { tool in
            Button(tool.label) {
                if let prefix { model.open(tool, for: prefix) }
            }
        }
    }

    private func taken(_ backup: PrefixBackup) -> String {
        backup.taken?.formatted(date: .abbreviated, time: .shortened) ?? backup.url.lastPathComponent
    }

    private func single(_ ids: Set<WinePrefix.ID>) -> WinePrefix? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.prefixes.first { $0.id == id }
    }

    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}

// A table cell's quiet text in the BP greys (Prefixes and Games). On a selected row it takes
// the system's, which turn light on the selection, where a fixed grey would be hard to read.
struct CellGrey: ViewModifier {
    var faint = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(faint && contrast != .increased ? .tertiary : .secondary)
        } else {
            content.foregroundStyle(faint ? BP.fg3 : BP.fg2)
        }
    }
}
