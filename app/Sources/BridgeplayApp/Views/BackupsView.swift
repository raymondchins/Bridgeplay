import SwiftUI

struct BackupsView: View {

    @Environment(PrefixesModel.self) private var model
    @State private var selection = Set<PrefixBackup.ID>()

    var body: some View {
        Group {
            if !model.hasLoaded {
                SkeletonTable(label: String(localized: "Looking for backups"), columns: [0.45, 0.3, 0.25])
            } else if model.backups.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Backups"),
                    systemImage: "externaldrive.badge.timemachine"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle("Prefix Backups")
        .navigationSubtitle(summary)
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
                        menu: ErrorReport.actions(failed.message, in: "Prefix Backups")
                    )
                )
            } else if let outcome = model.outcome {
                report(StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok))
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
        .task { if model.prefixes.isEmpty { await model.load() } }
        .onChange(of: model.backups) { _, kept in
            selection = selection.filter { id in kept.contains { $0.id == id } }
        }
        .confirmationDialog(
            PrefixPrompt.deleteBackupsTitle(clearing),
            isPresented: asking,
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.deleteBackupsButton(clearing), role: .destructive) {
                let targets = clearing
                model.pendingConfirmation = nil
                Task { await model.deleteBackups(targets) }
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(PrefixPrompt.deleteBackupsMessage(clearing))
        }
    }

    private var summary: String {
        guard !model.backups.isEmpty else { return "" }
        let size = model.backupBytes.formatted(.byteCount(style: .file))
        let count = model.backups.count == 1 ? String(localized: "1 backup") : String(localized: "\(model.backups.count) backups")
        return String(localized: "\(count), \(size) private size")
    }

    private var selected: [PrefixBackup] {
        model.backups.filter { selection.contains($0.id) }
    }

    private var clearing: [PrefixBackup] {
        if case .deleteBackups(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private var asking: Binding<Bool> {
        Binding(
            get: { isAsking },
            set: { shown in
                if !shown, isAsking { model.pendingConfirmation = nil }
            }
        )
    }

    private var isAsking: Bool {
        if case .deleteBackups = model.pendingConfirmation { return true }
        return false
    }

    @ViewBuilder
    private var strip: some View {
        Button("Reveal in Finder", systemImage: "folder") {
            if let backup = selected.first, selected.count == 1 { model.reveal(backup) }
        }
        .disabled(selected.count != 1)
        .help("Show the selected backup in the Finder.")

        Button("Delete", systemImage: "trash") {
            ask(selected)
        }
        .disabled(selected.isEmpty || model.isLoading)
        .help("Delete the selected backups.")

        Button("Delete All", systemImage: "externaldrive.badge.minus") {
            ask(model.backups)
        }
        .disabled(model.backups.isEmpty || model.isLoading)
        .help("Delete every backup that rebuilds have kept.")

        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("List the backups again and update their sizes.")
    }

    private var gameWidth: CGFloat {
        min(TextWidth.widest(model.backups.map(\.title)) ?? 240, TextWidth.maxTitle + TextWidth.cellPadding)
    }

    private var libraryWidth: CGFloat {
        TextWidth.widest(model.backups.map(\.prefix.library.displayName)) ?? 120
    }

    private var takenWidth: CGFloat {
        TextWidth.widest(model.backups.map(taken)) ?? 150
    }

    private var table: some View {
        Table(model.backups, selection: $selection) {
            TableColumn("Game") { backup in
                Text(backup.title).help(backup.title)
            }
            .width(min: 60, ideal: gameWidth)

            TableColumn("App ID") { backup in
                Text(backup.prefix.appID).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Library") { backup in
                Text(backup.prefix.library.displayName)
                    .foregroundStyle(.secondary)
                    .help(backup.prefix.library.displayName)
            }
            .width(min: 44, ideal: libraryWidth)

            TableColumn("Private Size") { backup in
                Text(backup.bytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 90)

            TableColumn("Backed up") { backup in
                Text(taken(backup))
                    .foregroundStyle(.secondary)
                    .help(taken(backup))
            }
            .width(min: 70, ideal: takenWidth)
        }
        .contextMenu(forSelectionType: PrefixBackup.ID.self) { ids in
            actions(for: ids)
        }
        .onDeleteCommand {
            ask(selected)
        }
    }

    @ViewBuilder
    private func actions(for ids: Set<PrefixBackup.ID>) -> some View {
        let targets = model.backups.filter { ids.contains($0.id) }
        Group {
            if targets.count == 1, let backup = targets.first {
                Button("Reveal in Finder") { model.reveal(backup) }
                Divider()
            }
            if !targets.isEmpty {
                Button(PrefixPrompt.deleteBackupsButton(targets), role: .destructive) {
                    ask(targets)
                }
            }
        }
        .disabled(model.isLoading)
    }

    private func taken(_ backup: PrefixBackup) -> String {
        guard let taken = backup.taken else { return String(localized: "Unknown") }
        return taken.formatted(date: .abbreviated, time: .shortened)
    }

    private func ask(_ targets: [PrefixBackup]) {
        guard !targets.isEmpty, !model.isLoading else { return }
        model.pendingConfirmation = .deleteBackups(targets)
    }

    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
