import Foundation
import Testing

@testable import BridgeplayApp

// Delete goes to the Trash, Restore swaps folders by rename, and Clear Shader Cache touches
// only the caches it measured. None of these may lose a save without a permanent choice.
@Suite("Game data: Trash, Restore, shader caches")
struct GameDataSafetyTests {

    private struct Fixture {
        let dir: URL
        let library: SteamLibrary
        let prefix: WinePrefix
        let trash: URL
    }

    private func fixture(_ name: String) throws -> Fixture {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "bp-\(name)-\(UUID().uuidString)")
        let library = SteamLibrary(root: dir.appending(path: "library"))
        let pfx = library.compatdata.appending(path: "1574480/pfx")
        try fm.createDirectory(at: pfx.appending(path: "drive_c/users/crossover/Saved Games"), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: pfx.appending(path: "drive_c/users/crossover/Saved Games/slot1.sav"))
        let trash = dir.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        return Fixture(dir: dir, library: library, prefix: prefix, trash: trash)
    }

    // A stand-in for the volume's Trash: a rename into a folder, as trashItem does.
    private func fakeTrash(_ folder: URL) -> PrefixTools.Trash {
        { url in try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent)) }
    }

    private struct NoTrashHere: Error {}

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func makeBackup(_ prefix: WinePrefix, stamp: String, save: String) throws -> PrefixBackup {
        let url = prefix.root.appending(path: "pfx.previous-\(stamp)")
        let saves = url.appending(path: "drive_c/users/crossover/Saved Games")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data(save.utf8).write(to: saves.appending(path: "slot1.sav"))
        return PrefixBackup(prefix: prefix, url: url, taken: PrefixStore.backupDate(of: url), bytes: 4)
    }

    private func save(in pfx: URL) -> String? {
        try? String(contentsOf: pfx.appending(path: "drive_c/users/crossover/Saved Games/slot1.sav"), encoding: .utf8)
    }

    // MARK: Trash

    @Test("Delete moves the whole game folder, backups included, to the Trash")
    func deleteMovesToTrash() throws {
        let f = try fixture("trash")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")

        try PrefixTools.delete(f.prefix, trash: fakeTrash(f.trash))

        let trashed = f.trash.appending(path: "1574480")
        #expect(!exists(f.prefix.root))
        #expect(save(in: trashed.appending(path: "pfx")) == "save")
        #expect(exists(trashed.appending(path: "pfx.previous-20260101-120000")))
        #expect(exists(f.library.compatdata))
    }

    @Test("When the Trash refuses, nothing is deleted and the failure says so")
    func noTrashDeletesNothing() throws {
        let f = try fixture("notrash")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let backup = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")

        #expect(throws: TrashUnavailable.self) {
            try PrefixTools.delete(f.prefix, trash: { _ in throw NoTrashHere() })
        }
        #expect(throws: TrashUnavailable.self) {
            try PrefixTools.deleteBackup(backup.url, trash: { _ in throw NoTrashHere() })
        }
        #expect(save(in: f.prefix.pfx) == "save")
        #expect(save(in: backup.url) == "old")
    }

    @Test("A refused permission is reported as one, not offered as a permanent delete")
    func noPermissionIsNotNoTrash() throws {
        let f = try fixture("perm")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let denied: PrefixTools.Trash = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        #expect(throws: WriteRefused.self) { try PrefixTools.delete(f.prefix, trash: denied) }
        #expect(exists(f.prefix.pfx))
    }

    @Test("Delete refuses while the game holds its prefix and trashes nothing")
    func deleteRefusesWhileClaimed() throws {
        let f = try fixture("claimed")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let claim = try #require(PrefixStore.claim(f.prefix))
        defer { claim.release() }

        #expect(throws: StepFailure.self) { try PrefixTools.delete(f.prefix, trash: fakeTrash(f.trash)) }
        #expect(throws: StepFailure.self) { try PrefixTools.deletePermanently(f.prefix) }
        #expect(exists(f.prefix.pfx))
    }

    // Opt-in: makes and mounts a small case-sensitive APFS disk image, so the real trashItem
    // has a volume of its own. BRIDGEPLAY_TRASH_TEST=1 swift test --filter GameDataSafety
    @Test("On a case-sensitive APFS volume the prefix lands in that volume's Trash",
          .enabled(if: ProcessInfo.processInfo.environment["BRIDGEPLAY_TRASH_TEST"] == "1"))
    func realTrashOnCaseSensitiveVolume() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "bp-volume-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let image = work.appending(path: "library.dmg").path(percentEncoded: false)
        let mount = work.appending(path: "mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        #expect(try Shell.run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "Case-sensitive APFS",
                                                   "-volname", "BPTrash", image]).status == 0)
        #expect(try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint",
                                                   mount.path(percentEncoded: false), image]).status == 0)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path(percentEncoded: false)]) }

        let library = SteamLibrary(root: mount.appending(path: "SteamLibrary"))
        let pfx = library.compatdata.appending(path: "1574480/pfx/drive_c")
        try fm.createDirectory(at: pfx, withIntermediateDirectories: true)
        try fm.createDirectory(at: library.compatdata.appending(path: "1574480/pfx.previous-20260101-120000"),
                               withIntermediateDirectories: true)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)

        try PrefixTools.delete(prefix)

        let trash = mount.appending(path: ".Trashes/\(getuid())")
        let landed = try fm.contentsOfDirectory(atPath: trash.path(percentEncoded: false))
        let entry = try #require(landed.first { $0.hasPrefix("1574480") })
        #expect(exists(trash.appending(path: "\(entry)/pfx/drive_c")))
        #expect(exists(trash.appending(path: "\(entry)/pfx.previous-20260101-120000")))
        #expect(!exists(prefix.root))
    }

    // MARK: Restore

    @Test("Restore swaps the backup in and keeps the current data as a new backup")
    func restoreKeepsBoth() throws {
        let f = try fixture("restore")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        _ = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")
        // As the Backups page lists it, a directory URL from the folder listing.
        let backup = try #require(PrefixStore.backupDetails(of: f.prefix).first)
        try Data("winecx-11\nWineCX\n".utf8).write(to: f.prefix.root.appending(path: PrefixTools.buildRecordName))
        let now = try #require(PrefixStore.backupClock().date(from: "20260301-090000"))

        let kept = try #require(try PrefixTools.restore(backup, now: now))

        #expect(save(in: f.prefix.pfx) == "old")
        #expect(save(in: kept) == "save")
        #expect(kept.lastPathComponent == "pfx.previous-20260301-090000")
        #expect(!exists(backup.url))
        #expect(PrefixStore.backups(of: f.prefix).map(\.lastPathComponent) == [kept.lastPathComponent])
        // The record named the build of the data that is now the backup.
        #expect(!exists(f.prefix.root.appending(path: PrefixTools.buildRecordName)))
    }

    @Test("Restore with no current prefix just puts the backup in place")
    func restoreWithoutCurrent() throws {
        let f = try fixture("restore-none")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let backup = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")
        try FileManager.default.removeItem(at: f.prefix.pfx)

        #expect(try PrefixTools.restore(backup) == nil)
        #expect(save(in: f.prefix.pfx) == "old")
    }

    @Test("A failed second rename puts the current data back where it was")
    func restoreRollsBack() throws {
        let f = try fixture("restore-fail")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let backup = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")
        var moves = 0
        let failingSecond: (URL, URL) throws -> Void = { from, to in
            moves += 1
            if moves == 2 { throw NoTrashHere() }
            try FileManager.default.moveItem(at: from, to: to)
        }

        #expect(throws: NoTrashHere.self) { try PrefixTools.restore(backup, move: failingSecond) }
        #expect(save(in: f.prefix.pfx) == "save")
        #expect(save(in: backup.url) == "old")
        #expect(PrefixStore.backups(of: f.prefix).map(\.lastPathComponent) == [backup.url.lastPathComponent])
    }

    @Test("Restore refuses while the game holds its prefix, and a backup from elsewhere")
    func restoreRefuses() throws {
        let f = try fixture("restore-claimed")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let backup = try makeBackup(f.prefix, stamp: "20260101-120000", save: "old")

        let claim = try #require(PrefixStore.claim(f.prefix))
        #expect(throws: StepFailure.self) { try PrefixTools.restore(backup) }
        claim.release()

        let stray = PrefixBackup(prefix: f.prefix, url: f.dir.appending(path: "pfx.previous-x"), taken: nil, bytes: 0)
        try FileManager.default.createDirectory(at: stray.url, withIntermediateDirectories: true)
        #expect(throws: StepFailure.self) { try PrefixTools.restore(stray) }

        #expect(save(in: f.prefix.pfx) == "save")
        #expect(save(in: backup.url) == "old")
    }

    @Test("Back Up copies only when the copy fits or the volume clones")
    func backUpFits() {
        #expect(PrefixTools.backupFits(needed: 10, available: 5, clones: true))
        #expect(!PrefixTools.backupFits(needed: 10, available: 5, clones: false))
        #expect(PrefixTools.backupFits(needed: 10, available: 10, clones: false))
        #expect(PrefixTools.backupFits(needed: 10, available: nil, clones: nil))
    }

    // MARK: Model

    @MainActor
    @Test("A delete the Trash refuses asks about Delete Permanently and deletes nothing")
    func modelAsksBeforePermanent() async throws {
        let f = try fixture("model")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let library = f.library
        let model = PrefixesModel(libraries: { [library] }, trash: { _ in throw NoTrashHere() }, caches: nil)
        await model.load()
        let prefix = try #require(model.prefixes.first)

        await model.delete([prefix])

        #expect(model.pendingConfirmation == .deletePermanently([prefix], []))
        #expect(model.outcome == nil)
        #expect(save(in: prefix.pfx) == "save")

        model.pendingConfirmation = nil
        await model.deletePermanently([prefix], [])
        #expect(!exists(prefix.root))
        #expect(model.prefixes.isEmpty)
    }

    @MainActor
    @Test("A delete the Trash takes says so and asks nothing more")
    func modelTrashes() async throws {
        let f = try fixture("model-trash")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let library = f.library
        let model = PrefixesModel(libraries: { [library] }, trash: fakeTrash(f.trash), caches: nil)
        await model.load()
        let prefix = try #require(model.prefixes.first)

        await model.delete([prefix])

        #expect(model.pendingConfirmation == nil)
        #expect(model.outcome?.contains("Trash") == true)
        #expect(exists(f.trash.appending(path: "1574480/pfx")))
    }

    // MARK: Shader caches

    private func caches(in dir: URL, names: [String]) throws -> URL {
        let caches = dir.appending(path: "Caches")
        for name in names {
            let folder = caches.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appending(path: "cache.bin"))
        }
        return caches
    }

    @Test("A game's shader caches are its exe names' d3dm folders and its launcher's")
    func shaderCacheFindsTheGames() throws {
        let f = try fixture("shaders")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let install = f.dir.appending(path: "common/Game")
        let binaries = install.appending(path: "Game/Binaries/Win64")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try Data().write(to: binaries.appending(path: "Game-Win64-Shipping.exe"))
        try Data().write(to: install.appending(path: "Game.exe"))
        let caches = try caches(in: f.dir, names: [
            "d3dm/game-win64-shipping.exe/shaders.cache", "d3dm/Other.exe/shaders.cache",
            "d3dm/shaders.cache", "com.notproton.launcher.1574480", "com.notproton.launcher.253750",
        ])

        let usage = ShaderCache.usage(of: f.prefix, caches: caches, installDirectory: install)

        #expect(usage.folders.map(\.lastPathComponent).sorted()
            == ["com.notproton.launcher.1574480", "game-win64-shipping.exe"])
        #expect(usage.bytes > 0)
        #expect(ShaderCache.usage(of: f.prefix, caches: nil, installDirectory: install).isEmpty)
    }

    @Test("Clearing removes only the measured caches, never while the game runs")
    func shaderCacheClear() throws {
        let f = try fixture("shaders-clear")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let caches = try caches(in: f.dir, names: [
            "d3dm/Game.exe/shaders.cache", "d3dm/Other.exe/shaders.cache", "com.notproton.launcher.1574480",
        ])
        let mine = [caches.appending(path: "d3dm/Game.exe"), caches.appending(path: "com.notproton.launcher.1574480")]

        let claim = try #require(PrefixStore.claim(f.prefix))
        #expect(throws: StepFailure.self) { try ShaderCache.clear(f.prefix, folders: mine, caches: caches) }
        claim.release()
        #expect(mine.allSatisfy(exists))

        // A folder outside the caches, such as the prefix itself, is refused before anything goes.
        #expect(throws: StepFailure.self) {
            try ShaderCache.clear(f.prefix, folders: mine + [f.prefix.pfx], caches: caches)
        }
        #expect(mine.allSatisfy(exists))
        #expect(throws: StepFailure.self) {
            try ShaderCache.clear(f.prefix, folders: [caches.appending(path: "com.notproton.launcher.253750")], caches: caches)
        }

        try ShaderCache.clear(f.prefix, folders: mine, caches: caches)
        #expect(!mine.contains(where: exists))
        #expect(exists(caches.appending(path: "d3dm/Other.exe/shaders.cache")))
        #expect(save(in: f.prefix.pfx) == "save")
    }
}
