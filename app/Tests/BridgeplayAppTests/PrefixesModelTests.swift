import Foundation
import Testing

@testable import BridgeplayApp

// Loading measures every prefix with du and find in turn, so it stays in flight long enough
// for a second to start on top. The libraries closure runs off the main actor, hence a lock.
private final class Libraries: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [SteamLibrary]

    init(_ value: [SteamLibrary]) { self.value = value }

    var current: [SteamLibrary] {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// Stands in for the wineboot a real rebuild runs, which a test has no runner for. Records
// the order the queue visits prefixes in and notices two ever being in flight at once.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var order: [String] = []
    private var clashed = false
    private let held: DispatchSemaphore?

    // A held turn blocks inside the rebuild until the test lets it go, so what the model
    // published stays readable instead of lasting only as long as a sleep.
    init(holdingEachTurn: Bool = false) {
        held = holdingEachTurn ? DispatchSemaphore(value: 0) : nil
    }

    struct Refused: LocalizedError {
        let appID: String
        var errorDescription: String? { "\(appID) refused" }
    }

    var visited: [String] { lock.withLock { order } }
    var overlapped: Bool { lock.withLock { clashed } }

    func releaseTurn() { held?.signal() }

    static func backup(of prefix: WinePrefix) -> URL {
        prefix.root.appending(path: "pfx.previous-20260101-120000")
    }

    @discardableResult
    func enter(_ prefix: WinePrefix, failing: Bool = false) throws -> URL? {
        lock.withLock {
            order.append(prefix.title)
            inFlight += 1
            if inFlight > 1 { clashed = true }
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let held {
            held.wait()
        } else {
            // Long enough that a queue running these concurrently would be caught holding
            // two at once. Without it every call returns before the next begins either way.
            Thread.sleep(forTimeInterval: 0.05)
        }
        if failing { throw Refused(appID: prefix.appID) }
        return Self.backup(of: prefix)
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []

    var calls: [String] { lock.withLock { made } }

    func add(_ appID: String, _ build: String, _ keep: Bool) {
        lock.withLock { made.append("\(appID) \(build) \(keep)") }
    }
}

private final class DelayedToolScan: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let tools: [InstalledTool]
    // Finishes once the first scan has started. Awaited, not timed: a busy test run can take
    // longer than any fixed timeout to get the first load this far.
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    let resume = DispatchSemaphore(value: 0)

    init(_ tools: [InstalledTool]) {
        self.tools = tools
        (entered, enteredContinuation) = AsyncStream.makeStream()
    }

    func list() -> [InstalledTool] {
        let first = lock.withLock {
            calls += 1
            return calls == 1
        }
        if first {
            enteredContinuation.yield()
            enteredContinuation.finish()
            resume.wait()
            return []
        }
        return tools
    }
}

@MainActor
@Suite("Loading prefixes")
struct PrefixesModelTests {

    nonisolated private static let tool = InstalledTool(
        tool: SupportedRunners.all[0].tools[0], build: SupportedRunners.all[0].id
    )

    private func makeLibrary(appIDs: [String]) throws -> (URL, SteamLibrary) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-model-\(UUID().uuidString)")
        let library = SteamLibrary(root: dir)
        for appID in appIDs {
            try FileManager.default.createDirectory(
                at: library.compatdata.appending(path: "\(appID)/pfx/drive_c/users/crossover"),
                withIntermediateDirectories: true)
        }
        return (dir, library)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("Only a prefix whose arch no installed tool runs is stale")
    func flagsStalePrefixes() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "253750", "447700", "71230"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let compatdata = library.compatdata
        try "\(Self.tool.build)\n\(Self.tool.display)\n".write(
            to: compatdata.appending(path: "1574480/\(PrefixTools.buildRecordName)"),
            atomically: true, encoding: .utf8)
        for (appID, machine) in [("253750", UInt16(0x8664)), ("71230", UInt16(0xAA64))] {
            let root = compatdata.appending(path: appID)
            try write("1.0.0.1\n", to: root.appending(path: PrefixTools.buildRecordName))
            var bytes = [UInt8](repeating: 0, count: 0x40)
            bytes[0x3c] = 0x40
            bytes += [0x50, 0x45, 0x00, 0x00, UInt8(machine & 0xff), UInt8(machine >> 8)]
            try FileManager.default.createDirectory(
                at: root.appending(path: "pfx/drive_c/windows/system32"), withIntermediateDirectories: true)
            try Data(bytes).write(to: root.appending(path: "pfx/drive_c/windows/system32/ntdll.dll"))
        }

        let model = PrefixesModel(libraries: { [library] }, installedTools: { [Self.tool] })
        await model.load()

        func prefix(_ appID: String) throws -> WinePrefix {
            try #require(model.prefixes.first { $0.appID == appID })
        }
        #expect(model.isStale(try prefix("1574480")) == false)
        #expect(model.lastTool(try prefix("1574480")) == Self.tool.display)
        // Another build of the same arch updates the prefix in place.
        #expect(model.isStale(try prefix("253750")) == false)
        #expect(model.lastTool(try prefix("253750")) == Self.tool.display)
        #expect(model.isStale(try prefix("71230")) == true)
        #expect(model.isStale(try prefix("447700")) == false)
        #expect(model.lastTool(try prefix("447700")) == nil)
    }

    @Test("The Prefixes table shows the short name of the tool that runs each prefix")
    func showsShortToolName() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let build = try #require(SupportedRunners.all.first { $0.tools.count == 2 })
        let tools = build.tools.map { InstalledTool(tool: $0, build: build.id) }
        let named = [
            ("1574480", "CrossOver Preview - ARM64 Build (FEX)", UInt16(0xAA64)),
            ("253750", "CrossOver Preview - ARM64 Build (Rosetta)", UInt16(0x8664)),
        ]
        for (appID, old, machine) in named {
            let root = library.compatdata.appending(path: appID)
            try write("\(build.id)\n\(old)\n", to: root.appending(path: PrefixTools.buildRecordName))
            var bytes = [UInt8](repeating: 0, count: 0x40)
            bytes[0x3c] = 0x40
            bytes += [0x50, 0x45, 0x00, 0x00, UInt8(machine & 0xff), UInt8(machine >> 8)]
            try FileManager.default.createDirectory(
                at: root.appending(path: "pfx/drive_c/windows/system32"), withIntermediateDirectories: true)
            try Data(bytes).write(to: root.appending(path: "pfx/drive_c/windows/system32/ntdll.dll"))
        }

        let model = PrefixesModel(libraries: { [library] }, installedTools: { tools })
        await model.load()

        func shown(_ appID: String) throws -> String? {
            model.lastTool(try #require(model.prefixes.first { $0.appID == appID }))
        }
        #expect(try shown("1574480") == "CrossOver 2026 08 21-ARM64 - FEX")
        #expect(try shown("253750") == "CrossOver 2026 08 21-ARM64 - Rosetta")
    }

    @Test("A load lists the prefixes and measures each one")
    func loadsAndMeasures() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PrefixesModel(libraries: { [library] })

        await model.load()

        #expect(model.prefixes.count == 2)
        #expect(Set(model.usage.keys) == Set(model.prefixes.map(\.id)))
        #expect(!model.isLoading)
    }

    // The regression: a superseded load kept writing into the dictionary the newer one had
    // emptied, and the first to finish cleared isLoading while the other was still measuring.
    @Test("A load that is superseded does not publish into the newer one")
    func supersededLoadPublishesNothing() async throws {
        let (oldDir, oldLibrary) = try makeLibrary(appIDs: ["1574480", "1649240", "3014330"])
        defer { try? FileManager.default.removeItem(at: oldDir) }
        let (newDir, newLibrary) = try makeLibrary(appIDs: ["4401430"])
        defer { try? FileManager.default.removeItem(at: newDir) }

        let libraries = Libraries([oldLibrary])
        let model = PrefixesModel(libraries: { libraries.current })

        let first = Task { await model.load() }
        // Let the first load get past listing and into measuring.
        await Task.yield()

        // What deleting a prefix does: the library changes, then a load starts on top of
        // the one still running.
        libraries.current = [newLibrary]
        let replacement = Task { await model.load() }

        _ = await first.value
        _ = await replacement.value

        // Whatever interleaving happened, the sizes must describe the listed prefixes
        // and nothing else, and nothing may still claim to be loading.
        #expect(Set(model.usage.keys) == Set(model.prefixes.map(\.id)))
        #expect(!model.isLoading)
    }

    @Test("A superseded tool scan cannot replace the newer prefix records", .timeLimit(.minutes(1)))
    func supersededToolScanPublishesNothing() async throws {
        let (oldDir, oldLibrary) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: oldDir) }
        let (newDir, newLibrary) = try makeLibrary(appIDs: ["4401430"])
        defer { try? FileManager.default.removeItem(at: newDir) }
        for (library, appID) in [(oldLibrary, "1574480"), (newLibrary, "4401430")] {
            try write("\(Self.tool.build)\n\(Self.tool.display)\n",
                      to: library.compatdata.appending(path: "\(appID)/\(PrefixTools.buildRecordName)"))
        }
        let libraries = Libraries([oldLibrary])
        let scan = DelayedToolScan([Self.tool])
        defer { scan.resume.signal() }
        let model = PrefixesModel(libraries: { libraries.current }, installedTools: { scan.list() })
        let first = Task { await model.load() }
        var entered = false
        for await _ in scan.entered { entered = true }
        try #require(entered)

        libraries.current = [newLibrary]
        await model.load()
        let current = try #require(model.prefixes.first)
        #expect(model.tools.map(\.build) == [Self.tool.build])
        #expect(Set(model.currentTools.keys) == [current.id])

        scan.resume.signal()
        await first.value
        #expect(model.prefixes.map(\.id) == [current.id])
        #expect(model.tools.map(\.build) == [Self.tool.build])
        #expect(Set(model.records.keys) == [current.id])
        #expect(Set(model.currentTools.keys) == [current.id])
        #expect(!model.isStale(current))
        #expect(!model.isStale(WinePrefix(appID: "1574480", name: nil, library: oldLibrary, lastUsed: nil)))
        #expect(!model.isLoading)
    }

    @Test("Loading again from a changed library replaces the previous results")
    func reloadReplacesResults() async throws {
        let (oldDir, oldLibrary) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: oldDir) }
        let (newDir, newLibrary) = try makeLibrary(appIDs: ["4401430"])
        defer { try? FileManager.default.removeItem(at: newDir) }

        // Swapped between loads, the way deleting a prefix changes what is there.
        let libraries = Libraries([oldLibrary])
        let model = PrefixesModel(libraries: { libraries.current })

        await model.load()
        #expect(model.prefixes.count == 2)

        libraries.current = [newLibrary]
        await model.load()

        #expect(model.prefixes.map(\.appID) == ["4401430"])
        #expect(Set(model.usage.keys) == Set(model.prefixes.map(\.id)))
        #expect(!model.isLoading)
    }

    // The toolbar, context menu and Prefix menu all act on the selection, so one pointing at a
    // prefix that is gone offers an action on nothing. Delete and rebuild both reload.
    @Test("A load drops selected prefixes that are no longer there")
    func loadPrunesStaleSelection() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(libraries: { [library] })
        await model.load()

        let survivor = try #require(model.prefixes.first { $0.appID == "1649240" })
        let doomed = try #require(model.prefixes.first { $0.appID == "1574480" })
        model.selection = [survivor.id, doomed.id]

        // A delete takes one appid out of the library it was in. Swapping the library instead
        // would move every prefix, since a prefix is keyed by library root as well as appid.
        try FileManager.default.removeItem(at: library.compatdata.appending(path: "1574480"))
        await model.load()

        #expect(model.prefixes.count == 1)
        #expect(!model.selection.contains(doomed.id))
        // Still selected, because it is still there. A load that cleared the selection
        // outright would pass the check above for the wrong reason.
        #expect(model.selection.count == 1)
    }

    // The wine tools and Reveal drive one prefix each, so more than one selected row has
    // to resolve to nothing rather than to one of them.
    @Test("Only a single selected prefix is a target for the per-prefix actions")
    func selectedPrefixIsSingleSelectionOnly() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PrefixesModel(libraries: { [library] })
        await model.load()

        #expect(model.selectedPrefix == nil)

        let one = try #require(model.prefixes.first)
        model.selection = [one.id]
        #expect(model.selectedPrefix == one)

        model.selection = Set(model.prefixes.map(\.id))
        #expect(model.selection.count == 2)
        #expect(model.selectedPrefix == nil)
    }

    @Test("Confirming the rebuild dialog runs it with the tool and backup choice it asked about")
    func confirmingRunsTheRebuild() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let asked = Asked()
        let model = PrefixesModel(
            libraries: { [library] },
            rebuild: { prefix, tool, keep in
                asked.add(prefix.appID, tool.build, keep)
                return nil
            })
        await model.load()

        #expect(model.confirmRebuild() == nil)

        model.pendingConfirmation = .rebuild(model.prefixes, Self.tool)
        await model.confirmRebuild(keepBackup: false)?.value
        #expect(model.pendingConfirmation == nil)

        model.pendingConfirmation = .rebuild(model.prefixes, Self.tool)
        await model.confirmRebuild()?.value

        let build = Self.tool.build
        #expect(asked.calls == ["1574480 \(build) false", "1574480 \(build) true"])
    }

    @Test("Declining the backup tells the rebuild not to keep one")
    func rebuildForwardsTheBackupChoice() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(
            libraries: { [library] },
            rebuild: { prefix, _, keep in keep ? Recorder.backup(of: prefix) : nil })
        await model.load()
        let targets = model.prefixes
        let title = try #require(targets.first).title

        await model.recreate(targets, as: Self.tool, keepBackup: false)
        #expect(model.outcome == "Rebuilt the prefix for \(title).")

        await model.recreate(targets, as: Self.tool)
        #expect(model.outcome?.contains("The original is at") == true)
    }

    @Test("Backing up reports where the copy landed")
    func backUpReportsTheSlot() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(
            libraries: { [library] }, makeBackup: { Recorder.backup(of: $0) })
        await model.load()
        let targets = model.prefixes
        let first = try #require(targets.first)

        await model.backUp([first])
        #expect(model.outcome == "Backed up the prefix for \(first.title).")
        #expect(model.failure == nil)

        await model.backUp(targets)
        #expect(model.outcome == "Backed up 2 prefixes.")
    }

    // Selecting every prefix that needs rebuilding used to offer nothing, so they had to be
    // picked and confirmed one at a time.
    @Test("Rebuilding takes every selected prefix, one after another")
    func rebuildTakesTheWholeSelection() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }

        // Records the order and asserts nothing overlaps: a second wineboot in the same
        // runner while the first is still going is the failure this queue exists to avoid.
        let log = Recorder()
        let model = PrefixesModel(
            libraries: { [library] }, rebuild: { prefix, _, _ in try log.enter(prefix) })
        await model.load()
        model.selection = Set(model.prefixes.map(\.id))

        let targets = model.selectedPrefixes
        #expect(targets.count == 3)
        await model.recreate(targets, as: Self.tool)

        #expect(log.visited == targets.map(\.title))
        #expect(!log.overlapped)
        #expect(model.outcome == "Rebuilt 3 prefixes. Each original is kept beside the game's "
            + "prefix. Check that your saves are present in the games, then delete the backups "
            + "to save space.")
        #expect(model.failure == nil)
        #expect(model.busy.isEmpty)
        #expect(!model.isBusy)
    }

    // A prefix whose game is running refuses, and it used to be the only one attempted.
    @Test("A prefix that refuses to rebuild does not stop the ones queued behind it")
    func rebuildReportsAPartialRun() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = Recorder()
        let model = PrefixesModel(
            libraries: { [library] },
            rebuild: { prefix, _, _ in try log.enter(prefix, failing: prefix.appID == "1649240") }
        )
        await model.load()
        let targets = model.prefixes
        await model.recreate(targets, as: Self.tool)

        #expect(log.visited.count == 3)
        #expect(model.outcome == "Rebuilt 2 prefixes. Each original is kept beside the game's "
            + "prefix. Check that your saves are present in the games, then delete the backups "
            + "to save space.")
        #expect(model.failure == "1649240 refused")
        #expect(model.busy.isEmpty)
    }

    // The pane used to keep the sentence and drop the error, so a refusal it could act on
    // arrived as a string with no remedy left in it.
    @Test("A refused rebuild reaches the pane with its remedy intact")
    func rebuildCarriesTheRemedy() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(
            libraries: { [library] },
            rebuild: { prefix, _, _ in
                throw WriteRefused(path: prefix.root.path(percentEncoded: false))
            }
        )
        await model.load()
        await model.recreate(model.prefixes, as: Self.tool)

        let report = try #require(model.report)
        #expect(report.remedy == .ownership, "a prefix the user owns was blamed on a permission")
        #expect(report.settingsPane == nil)
        // Two refusals, one sentence, because neither of them names its own path.
        #expect(
            report.message
                == "Could not write files. Check permissions, make sure your user owns the folder.")
    }

    @Test("One rebuilt prefix reports where the old one was parked")
    func rebuildOfOneReportsTheBackup() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = Recorder()
        let model = PrefixesModel(
            libraries: { [library] }, rebuild: { prefix, _, _ in try log.enter(prefix) })
        await model.load()
        let target = try #require(model.prefixes.first)

        await model.recreate([target], as: Self.tool)

        let backup = Recorder.backup(of: target).path(percentEncoded: false)
        #expect(model.outcome == "Rebuilt the prefix for \(target.title). The original is at "
            + "\(backup). Check that your save is present in the game, then delete the backup "
            + "to save space.")
        #expect(model.failure == nil)
    }

    @Test("A rebuild that parked nothing says nothing about a backup")
    func rebuildThatParkedNothingMentionsNoBackup() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(libraries: { [library] }, rebuild: { _, _, _ in nil })
        await model.load()
        let target = try #require(model.prefixes.first)

        await model.recreate([target], as: Self.tool)

        #expect(model.outcome == "Rebuilt the prefix for \(target.title).")
    }

    @Test("Backups from every prefix are listed newest first")
    func backupsAreListedNewestFirst() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try park(["1574480": ["20260101-120000"], "1649240": ["20260103-090000"]], in: library)

        let model = PrefixesModel(libraries: { [library] })
        await model.load()

        #expect(model.backups.count == 2)
        #expect(model.backups.map(\.prefix.appID) == ["1649240", "1574480"])
        #expect(model.backupBytes == model.backups.reduce(into: Int64(0)) { $0 += $1.bytes })
    }

    @Test("Deleting backups counts them rather than the prefixes")
    func deleteBackupsReportsTheCount() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try park(
            [
                "1574480": ["20260101-120000", "20260102-133000"],
                "1649240": ["20260101-120000", "20260102-133000"],
            ],
            in: library)

        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        #expect(model.backups.count == 4)

        await model.deleteBackups(model.backups)

        #expect(model.outcome == "Deleted 4 backups across 2 prefixes.")
        #expect(model.failure == nil)
        #expect(model.backups.isEmpty)
        #expect(model.prefixes.allSatisfy { PrefixStore.backups(of: $0).isEmpty })
    }

    @Test("Deleting the backups of one game names the game")
    func deleteBackupsOfOneGameNamesIt() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try park(
            ["1574480": ["20260101-120000", "20260102-133000"], "1649240": ["20260105-101500"]],
            in: library)

        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        let mine = model.backups.filter { $0.prefix.appID == "1574480" }
        #expect(mine.count == 2)

        await model.deleteBackups(mine)

        #expect(model.outcome == "Deleted 2 backups for \(mine[0].title).")
        #expect(model.backups.map(\.prefix.appID) == ["1649240"])
    }

    @Test("Deleting a single backup names the game once")
    func deleteOneBackupNamesTheGame() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try park(["1574480": ["20260101-120000"]], in: library)

        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        let only = try #require(model.backups.first)

        await model.deleteBackups([only])

        #expect(model.outcome == "Deleted the backup for \(only.title).")
        #expect(model.backups.isEmpty)
    }

    @Test("Deleting backups where there are none says nothing")
    func deleteBackupsWithNoneIsQuiet() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(libraries: { [library] })
        await model.load()

        await model.deleteBackups(model.backups)

        #expect(model.backups.isEmpty)
        #expect(model.outcome == nil)
        #expect(model.failure == nil)
    }

    private func park(_ stamps: [String: [String]], in library: SteamLibrary) throws {
        let fm = FileManager.default
        for (appID, taken) in stamps {
            for stamp in taken {
                let backup = library.compatdata.appending(path: "\(appID)/pfx.previous-\(stamp)")
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try Data("parked".utf8).write(to: backup.appending(path: "user.reg"))
            }
        }
    }

    @Test("Rebuilding nothing asks nothing of the disk")
    func rebuildOfAnEmptySelectionDoesNothing() async throws {
        let log = Recorder()
        let model = PrefixesModel(
            libraries: { [] }, rebuild: { prefix, _, _ in try log.enter(prefix) })
        model.outcome = "untouched"
        await model.recreate([], as: Self.tool)

        #expect(log.visited.isEmpty)
        #expect(model.outcome == "untouched")
    }

    // The spinner on a row comes off this set. Every selected row spins from the moment the
    // run starts, and a row stops as its own turn ends rather than when the queue does.
    @Test("Every selected row is busy from the start and each stops as its turn ends")
    func busyFollowsTheQueue() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = Recorder(holdingEachTurn: true)
        let model = PrefixesModel(
            libraries: { [library] }, rebuild: { prefix, _, _ in try log.enter(prefix) })
        await model.load()
        let targets = model.prefixes

        let running = Task { await model.recreate(targets, as: Self.tool) }

        // A prefix having started means the one before it is done and out of the set. The turn is
        // held inside the rebuild, so the set cannot move between the wait and the read.
        for (turn, remaining) in [(1, 3), (2, 2), (3, 1)] {
            while log.visited.count < turn { await Task.yield() }
            #expect(model.busy.count == remaining)
            log.releaseTurn()
        }
        await running.value

        #expect(model.busy.isEmpty)
    }

    // A rebuilt prefix has new sizes to measure and a deleted one must leave the list, so
    // both runs end by reading the libraries again rather than keeping what was read before.
    @Test("A finished rebuild reads the libraries again")
    func rebuildReloadsTheList() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let box = Libraries([library])
        let log = Recorder()
        let model = PrefixesModel(
            libraries: { box.current }, rebuild: { prefix, _, _ in try log.enter(prefix) })
        await model.load()
        let targets = model.prefixes
        #expect(targets.count == 2)

        // Taken away before the run finishes, so an empty list afterwards can only mean the
        // run went back to the libraries for it.
        box.current = []
        await model.recreate(targets, as: Self.tool)

        #expect(model.prefixes.isEmpty)
    }

    // Right-clicking four selected rows and deleting used to throw away one of them, which
    // left the other three selected and looking untouched.
    @Test("Deleting takes every selected prefix")
    func deleteTakesTheWholeSelection() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "1649240", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PrefixesModel(libraries: { [library] })
        await model.load()

        let doomed = model.prefixes.filter { $0.appID != "253750" }
        model.selection = Set(doomed.map(\.id))
        #expect(model.selectedPrefixes.count == 2)

        await model.delete(model.selectedPrefixes)

        #expect(model.prefixes.map(\.appID) == ["253750"])
        #expect(model.failure == nil)
        #expect(
                model.outcome
                    == "Deleted 2 prefixes. Steam will make a new prefix if a game is launched again.")
        #expect(model.busy.isEmpty)
        #expect(!model.isLoading)
    }

    @Test("Deleting one prefix says which one")
    func deleteOfOneNamesIt() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            """
            "AppState"
            {
            \t"name"\t\t"Agent 64: Spies Never Die"
            }
            """, to: library.steamapps.appending(path: "appmanifest_1574480.acf"))

        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        await model.delete(model.prefixes)

        #expect(model.prefixes.isEmpty)
        #expect(
            model.outcome
                == "Deleted the prefix for Agent 64: Spies Never Die. Steam will make a new prefix "
                        + "if the game is launched again.")
    }

    // A running game refuses, and it refuses in the middle of a list of them. Stopping
    // there would leave the rest selected with no word about why nothing happened to them.
    @Test("A prefix that refuses does not stop the others")
    func refusalDoesNotStopTheRest() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480", "253750"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        #expect(model.prefixes.count == 2)

        let busy = try #require(model.prefixes.first { $0.appID == "253750" })
        let held = try hold(busy)
        defer { held() }

        await model.delete(model.prefixes)

        // The refusal happens before anything is unlinked, so the whole prefix is still
        // there and still listed.
        #expect(model.prefixes.map(\.appID) == ["253750"])
        #expect(model.outcome?.contains("Deleted the prefix for App 1574480.") == true)
        #expect(model.failure?.contains("is running. Quit the game first.") == true)
        #expect(model.busy.isEmpty)
    }

    // The prefix lock keeps this test out of Wine's real socket directory.
    private func hold(_ prefix: WinePrefix) throws -> () -> Void {
        let lock = prefix.root.appending(path: ".notproton-prefix.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        do {
            try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        } catch {
            close(fd)
            throw error
        }
        return { FileLock.release(fd) }
    }

    @Test("Deleting nothing is not an operation")
    func deletingNothingDoesNothing() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = PrefixesModel(libraries: { [library] })
        await model.load()
        model.outcome = "untouched"

        await model.delete([])

        #expect(model.prefixes.count == 1)
        #expect(model.outcome == "untouched")
        #expect(model.failure == nil)
        #expect(!model.isLoading)
    }

    @Test("A library with no prefixes leaves nothing behind")
    func emptyLibraryClearsResults() async throws {
        let (dir, library) = try makeLibrary(appIDs: ["1574480"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let (emptyDir, emptyLibrary) = try makeLibrary(appIDs: [])
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let libraries = Libraries([library])
        let model = PrefixesModel(libraries: { libraries.current })
        await model.load()
        #expect(!model.usage.isEmpty)

        libraries.current = [emptyLibrary]
        await model.load()

        #expect(model.prefixes.isEmpty)
        #expect(model.usage.isEmpty)
        #expect(!model.isLoading)
    }
}
