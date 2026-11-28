// Every installed Windows game, across every library. The list comes from GamesModel; sizes,
// backups and every action from PrefixesModel, so this page asks the same questions as Prefixes.

import AppKit
import BridgeplayUI
import SwiftUI

struct GamesView: View {

    @Environment(GamesModel.self) private var games
    @Environment(PrefixesModel.self) private var prefixes
    @State private var selection: InstalledGame.ID?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\GameRow.lastLaunch, order: .reverse)]

    var body: some View {
        Group {
            if !games.hasLoaded {
                SkeletonTable(label: String(localized: "Looking for games"))
            } else if games.games.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Windows Games"),
                    systemImage: "gamecontroller",
                    description: Text("Launch a Windows game with Bridgeplay.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle("Games")
        .searchable(text: $search, placement: .toolbar)
        .safeAreaInset(edge: .bottom) {
            if let failed = prefixes.report {
                bar(StatusRow(
                    title: String(localized: "Failed"),
                    value: failed.message,
                    tone: .bad,
                    action: failed.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) { Remedy.openSettings(pane) }
                    },
                    menu: ErrorReport.actions(failed.message, in: "Games")
                ))
            } else if let outcome = prefixes.outcome {
                bar(StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Play", systemImage: "play.fill") {
                    if let game = selected { play(game) }
                }
                .disabled(selected == nil)
                .help("Play in Steam.")

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(games.isLoading || prefixes.isLoading)
                .help("Reload the list.")
            }
        }
        .task { await refresh() }
        // A trash, rebuild or restore changes what is on disk: list again (no sizes walked).
        .onChange(of: prefixes.prefixes) { Task { await games.load() } }
        .prefixDialogs()
    }

    private func refresh() async {
        await games.load()
        await prefixes.load()
    }

    private var selected: InstalledGame? {
        guard let selection else { return nil }
        return games.games.first { $0.id == selection }
    }

    // PrefixesModel's own copy, so its confirmations name the same prefix as the Prefixes page.
    private func prefix(of game: InstalledGame) -> WinePrefix {
        prefixes.prefixes.first { $0.id == game.id } ?? game.prefix
    }

    private func play(_ game: InstalledGame) {
        guard let url = GamesLibrary.playURL(game) else { return }
        NSWorkspace.shared.open(url)
    }

    private struct GameRow: Identifiable {
        let game: InstalledGame
        let title: String
        let lastLaunch: Date
        let backend: String
        let engine: String
        let size: Int64
        let library: String

        var id: InstalledGame.ID { game.id }
    }

    private func engine(_ game: InstalledGame) -> String? {
        games.engine(game) ?? (game.hasPrefix ? prefixes.lastEngine(prefix(of: game)) : nil)
    }

    private var rows: [GameRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return games.games
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.appID == query }
            .map { game in
                GameRow(
                    game: game,
                    title: game.title,
                    lastLaunch: games.lastLaunch(game) ?? .distantPast,
                    backend: game.backend.map(GamesLibrary.backendLabel) ?? "",
                    engine: engine(game) ?? "",
                    size: game.hasPrefix ? prefixes.usage[game.id]?.bytes ?? -1 : 0,
                    library: game.prefix.library.displayName
                )
            }
            .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Game", value: \.title) { row in
                HStack(spacing: 8) {
                    icon(row.game)
                    Text(row.title).lineLimit(1).help(row.title)
                    if prefixes.busy.contains(row.id) {
                        ProgressView().controlSize(.small).accessibilityLabel("Working…")
                    }
                }
            }
            .width(min: 120, ideal: 150)

            // F4b: the compatibility verdict column (compat.json, keyed by row.game.appID) goes here.

            TableColumn("Last Launch", value: \.lastLaunch) { row in
                lastLaunchCell(row)
            }
            .width(min: TextWidth.of(String(localized: "Last Launch")) + TextWidth.cellPadding, ideal: 115)

            TableColumn("Graphics", value: \.backend) { row in
                Text(row.backend.isEmpty ? String(localized: "None") : row.backend)
                    .modifier(CellGrey(faint: row.backend.isEmpty))
            }
            .width(min: 50, ideal: 82)

            TableColumn("Engine", value: \.engine) { row in
                Text(row.engine.isEmpty ? String(localized: "None") : row.engine)
                    .lineLimit(1).truncationMode(.tail)
                    .modifier(CellGrey(faint: row.engine.isEmpty))
                    .help(row.engine)
            }
            .width(min: 60, ideal: 110)

            TableColumn("Prefix Size", value: \.size) { row in
                if !row.game.hasPrefix {
                    Text("None").modifier(CellGrey(faint: true))
                } else if row.size >= 0 {
                    Text(row.size.formatted(.byteCount(style: .file))).monospacedDigit().modifier(CellGrey())
                } else {
                    Text("Calculating…").modifier(CellGrey(faint: true))
                }
            }
            .width(min: TextWidth.of(String(localized: "Prefix Size")) + TextWidth.cellPadding, ideal: 80)

            TableColumn("Library", value: \.library) { row in
                Text(row.library).modifier(CellGrey()).help(row.library)
            }
            .width(min: 44, ideal: 60)
        }
        .contextMenu(forSelectionType: InstalledGame.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let game = games.games.first(where: { $0.id == id }) {
                actions(for: game)
            }
        } primaryAction: { ids in
            if let id = ids.first, ids.count == 1, let game = games.games.first(where: { $0.id == id }) {
                play(game)
            }
        }
    }

    private func lastLaunchCell(_ row: GameRow) -> some View {
        let verdict = games.verdict(row.game)
        let text = row.lastLaunch == .distantPast
            ? String(localized: "Never")
            : row.lastLaunch.formatted(date: .abbreviated, time: .omitted)
        return HStack(spacing: 4) {
            if verdict?.failed == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(BP.orange)
                    .accessibilityHidden(true)
            }
            Text(text).modifier(CellGrey(faint: row.lastLaunch == .distantPast))
        }
        .help(verdict?.sentence ?? text)
        .accessibilityElement(children: .combine)
        .accessibilityValue(verdict?.sentence ?? "")
    }

    @ViewBuilder
    private func icon(_ game: InstalledGame) -> some View {
        if let image = games.icons[game.id] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gamecontroller")
                .foregroundStyle(BP.fg3)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func actions(for game: InstalledGame) -> some View {
        let target = prefix(of: game)
        Button("Play") { play(game) }
        Divider()
        Menu("Open Log") {
            ForEach(PrefixLog.allCases, id: \.self) { log in
                Button(log.label) { prefixes.open(log, for: target) }
                    .disabled(!prefixes.hasLog(log, for: target))
            }
        }
        Button("Report This Game…") { PlayReports.shared.ask(about: target) }
        if game.hasPrefix {
            Button("Reveal in Finder") { prefixes.reveal(target) }
            Divider()
            Group {
                if prefixes.tools.count > 1 {
                    Menu(PrefixPrompt.rebuildButton([target])) {
                        ForEach(prefixes.tools) { tool in
                            Button(tool.display) { prefixes.pendingConfirmation = .rebuild([target], tool) }
                        }
                    }
                } else if let tool = prefixes.tools.first {
                    Button(PrefixPrompt.rebuildButton([target])) {
                        prefixes.pendingConfirmation = .rebuild([target], tool)
                    }
                }
                let kept = prefixes.backups(of: target)
                if !kept.isEmpty {
                    Menu("Restore Backup") {
                        ForEach(kept) { backup in
                            Button(backup.taken?.formatted(date: .abbreviated, time: .shortened) ?? backup.url.lastPathComponent) {
                                prefixes.pendingConfirmation = .restore(backup)
                            }
                        }
                    }
                }
                if !(prefixes.shaderCaches[game.id]?.isEmpty ?? true) {
                    Button(PrefixPrompt.clearShaderCacheButton([target]) + "…") {
                        prefixes.pendingConfirmation = .clearShaderCache([target])
                    }
                }
                Button(PrefixPrompt.deleteButton([target]), role: .destructive) {
                    prefixes.pendingConfirmation = .delete([target])
                }
            }
            .disabled(prefixes.isBusy)
        }
    }

    private func bar(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
