import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Prefix store")
struct PrefixStoreTests {

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("Every library path in the file is found, in order, without duplicates")
    func readsLibraryPaths() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Shaped like the real file: nested blocks, tab separated, an apps block whose
        // keys are numbers, and a second library on another volume.
        let vdf = dir.appending(path: "libraryfolders.vdf")
        try write(
            """
            "libraryfolders"
            {
            \t"0"
            \t{
            \t\t"path"\t\t"/Users/tester/Library/Application Support/Steam"
            \t\t"label"\t\t""
            \t\t"apps"
            \t\t{
            \t\t\t"480"\t\t"1906055"
            \t\t}
            \t}
            \t"1"
            \t{
            \t\t"path"\t\t"/Volumes/External Games SSD/SteamLibrary"
            \t\t"label"\t\t""
            \t}
            }
            """, to: vdf)

        let libraries = PrefixStore.libraries(vdf: vdf)
        #expect(libraries.count == 2)
        #expect(libraries.first?.root.path(percentEncoded: false) == "/Users/tester/Library/Application Support/Steam")
        #expect(libraries.last?.root.lastPathComponent == "SteamLibrary")
        // A library path with a space in it has to survive, since the external one has two.
        #expect(libraries.last?.root.path(percentEncoded: false) == "/Volumes/External Games SSD/SteamLibrary")
        #expect(libraries.last?.compatdata.lastPathComponent == "compatdata")
    }

    // The migration unescaped these and Prefixes/Uninstall did not, so the two disagreed.
    @Test("Library paths come back with Steam's escapes undone")
    func libraryPathsAreUnescaped() {
        let text = "\t\t\"path\"\t\t\"/Volumes/A \\\"B\\\"/C\\\\D\"\n\t\t\"Path\"\t\t\"/Volumes/E\"\n\t\t\"label\"\t\t\"path\"\n"
        #expect(PrefixStore.libraryPaths(in: text) == ["/Volumes/A \"B\"/C\\D", "/Volumes/E"])
    }

    @Test("A missing or empty file still yields the default library")
    func fallsBackToTheDefaultLibrary() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = PrefixStore.libraries(vdf: dir.appending(path: "nothing.vdf"))
        #expect(missing.count == 1)
        #expect(missing.first?.root == SupportPaths.Steam.userData)

        let empty = dir.appending(path: "empty.vdf")
        try write("\"libraryfolders\"\n{\n}\n", to: empty)
        #expect(PrefixStore.libraries(vdf: empty).first?.root == SupportPaths.Steam.userData)
    }

    @Test("An entry without a pfx is not a prefix")
    func skipsEntriesWithoutAPrefix() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        // Steam keeps a compatdata/0 with no pfx inside it. Listing that as a prefix
        // would offer a delete and a winecfg for something that does not exist.
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)
        // A file named like an appid is not a directory and must not be walked.
        try write("", to: library.compatdata.appending(path: "9999"))

        let prefixes = PrefixStore.all(libraries: [library])
        #expect(prefixes.map(\.appID) == ["1574480"])
    }

    @Test("A name comes from the library's own appmanifest, and its absence is not a failure")
    func readsTheAppName() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1649240/pfx"), withIntermediateDirectories: true)
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"1574480"
            \t"name"\t\t"Agent 64: Spies Never Die"
            }
            """, to: library.steamapps.appending(path: "appmanifest_1574480.acf"))

        let prefixes = PrefixStore.all(libraries: [library])
        let named = prefixes.first { $0.appID == "1574480" }
        let orphan = prefixes.first { $0.appID == "1649240" }

        #expect(named?.name == "Agent 64: Spies Never Die")
        #expect(named?.title == "Agent 64: Spies Never Die")
        // A prefix outliving the game it belongs to is the case worth listing, not
        // hiding, so no name has to be survivable.
        #expect(orphan?.name == nil)
        #expect(orphan?.title == "App 1649240")
    }

    @Test("A quote inside the name survives the manifest's escaping")
    func readsAnEscapedAppName() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "5102100/pfx"), withIntermediateDirectories: true)
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"5102100"
            \t"name"\t\t"Rideshare \\"Stimulator\\" Demo"
            \t"installdir"\t\t"RideshareStimulatorDemo"
            }
            """, to: library.steamapps.appending(path: "appmanifest_5102100.acf"))

        let prefix = PrefixStore.all(libraries: [library]).first { $0.appID == "5102100" }
        #expect(prefix?.name == "Rideshare \"Stimulator\" Demo")
    }

    @Test("Newline, tab and backslash escapes in the name are decoded")
    func decodesManifestEscapes() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "5102101/pfx"), withIntermediateDirectories: true)
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"5102101"
            \t"name"\t\t"One\\nTwo\\tThree\\\\Four\\qFive"
            }
            """, to: library.steamapps.appending(path: "appmanifest_5102101.acf"))

        let prefix = PrefixStore.all(libraries: [library]).first { $0.appID == "5102101" }
        #expect(prefix?.name == "One\nTwo\tThree\\Four\\qFive")
    }

    @Test("A non-Steam shortcut prefix is named from shortcuts.vdf")
    func readsTheShortcutName() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir.appending(path: "library"))
        let userdata = dir.appending(path: "userdata")

        func entry(_ index: String, appID: UInt32, name: String) -> [UInt8] {
            var out: [UInt8] = [0x00] + Array(index.utf8) + [0]
            out += [0x02] + Array("appid".utf8) + [0]
            out += withUnsafeBytes(of: appID.littleEndian, Array.init)
            out += [0x01] + Array("AppName".utf8) + [0] + Array(name.utf8) + [0]
            out += [0x07] + Array("LastPlayTime".utf8) + [0] + [UInt8](repeating: 1, count: 8)
            out += [0x00] + Array("tags".utf8) + [0, 0x08]
            return out + [0x08]
        }
        var vdf: [UInt8] = [0x00] + Array("shortcuts".utf8) + [0]
        vdf += entry("0", appID: 0xf281_5b63, name: "Grand Theft Auto V Enhanced")
        vdf += entry("1", appID: 0x9ea9_860b, name: "Postal2")
        vdf += [0x08, 0x08]
        let file = userdata.appending(path: "54303850/config/shortcuts.vdf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(vdf).write(to: file)

        for appID in ["4068563811", "2661910027", "3000000000"] {
            try FileManager.default.createDirectory(
                at: library.compatdata.appending(path: "\(appID)/pfx"), withIntermediateDirectories: true)
        }

        let prefixes = PrefixStore.all(libraries: [library], userdata: userdata)
        func title(_ appID: String) -> String? { prefixes.first { $0.appID == appID }?.title }

        #expect(title("4068563811") == "Grand Theft Auto V Enhanced")
        #expect(title("2661910027") == "Postal2")
        #expect(title("3000000000") == "App 3000000000")
        #expect(PrefixStore.shortcutNames(vdf: Data(vdf.prefix(40))).isEmpty)
    }

    @Test("Sizing a prefix stops at a symlink instead of walking through it")
    func doesNotFollowLinksOutOfThePrefix() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        // CrossOver's template points Documents at the real home. Sizing that would tell the user
        // a prefix costs everything in their home folder, which makes the warning worthless.
        let outside = dir.appending(path: "outside-the-prefix")
        try write("host file one", to: outside.appending(path: "one.txt"))
        try write("host file two", to: outside.appending(path: "two.txt"))

        let profile = library.compatdata.appending(path: "1574480/pfx/drive_c/users/crossover")
        try write("in prefix", to: profile.appending(path: "AppData/Roaming/game/save.dat"))
        try FileManager.default.createSymbolicLink(
            at: profile.appending(path: "Documents"), withDestinationURL: outside)

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        #expect(PrefixStore.usage(of: prefix).bytes > 0)
    }

    @Test("A linked folder outside the prefix adds nothing to its size")
    func sizeSkipsLinkedFolders() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appending(path: "outside")
        let inside = dir.appending(path: "inside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4 << 20).write(to: outside.appending(path: "big"))
        try FileManager.default.createSymbolicLink(
            at: inside.appending(path: "Documents"), withDestinationURL: outside)

        #expect(PrefixStore.directoryBytes(outside) >= 4 << 20)
        #expect(PrefixStore.directoryBytes(inside) < 1 << 20)
    }

    @Test("Private bytes exclude shared clone extents until the source is deleted")
    func privateSizeExcludesSharedExtents() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "template")
        let clone = dir.appending(path: "clone")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        try bytes.write(to: source.appending(path: "ntdll.dll"))
        try #require(
            clonefile(source.path(percentEncoded: false), clone.path(percentEncoded: false), 0) == 0,
            "scratch volume cannot clone")

        #expect(PrefixStore.directoryBytes(clone) < 1 << 20)
        #expect(PrefixStore.directoryBytes(source) < 1 << 20)
        #expect(PrefixStore.directoryBytes(clone, metric: .allocated) >= 4 << 20)
        #expect(PrefixStore.directoryBytes(source, metric: .allocated) >= 4 << 20)

        try FileManager.default.removeItem(at: source)
        #expect(PrefixStore.directoryBytes(clone) >= 4 << 20)
    }

    @Test("A symlink passed as the size root is not traversed")
    func sizeDoesNotFollowLinkedRoot() throws {
        let dir = try scratchDirectory("pfx-size-root")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4 << 20).write(to: outside.appending(path: "big"))
        let link = dir.appending(path: "pfx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(PrefixStore.directoryBytes(link) < 1 << 20)
        #expect(PrefixStore.directoryBytes(link, metric: .allocated) < 1 << 20)
        let directoryURL = URL(filePath: link.path + "/", directoryHint: .isDirectory)
        #expect(PrefixStore.directoryBytes(directoryURL) < 1 << 20)
        #expect(PrefixStore.directoryBytes(directoryURL, metric: .allocated) < 1 << 20)
    }

    @Test("Hardlinks within a folder are counted once by device and inode")
    func sizeDeduplicatesHardlinks() throws {
        let dir = try scratchDirectory("pfx-hardlinks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "original")
        try Data(repeating: 7, count: 4 << 20).write(to: file)
        try FileManager.default.linkItem(at: file, to: dir.appending(path: "same-inode"))

        #expect(PrefixStore.directoryBytes(dir) >= 4 << 20)
        #expect(PrefixStore.directoryBytes(dir) < 5 << 20)
        #expect(PrefixStore.directoryBytes(dir, metric: .allocated) >= 4 << 20)
        #expect(PrefixStore.directoryBytes(dir, metric: .allocated) < 5 << 20)
    }

    @Test("The shell preparation lock marks a prefix in use before a server exists")
    func preparationLockIsInUse() throws {
        let dir = try scratchDirectory("pfx-preparing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        let root = dir.appending(path: "sockets")
        let lock = prefix.root.appending(path: ".notproton-prefix.lock")
        #expect(!PrefixStore.isInUse(prefix, root: root))
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)

        #expect(PrefixStore.isInUse(prefix, root: root))
        let deletion = try #require(throws: StepFailure.self) { try PrefixTools.delete(prefix) }
        #expect(deletion.detail.contains("is running"))
        let rebuild = try #require(throws: StepFailure.self) {
            try PrefixTools.recreate(prefix, runner: dir.appending(path: "runner"))
        }
        #expect(rebuild.detail.contains("is running"))
        let backup = try #require(throws: StepFailure.self) { try PrefixTools.backUp(prefix) }
        #expect(backup.detail.contains("is running"))
        #expect(PrefixStore.backups(of: prefix).isEmpty)
        #expect(FileManager.default.fileExists(atPath: prefix.pfx.path))
        try #require(flock(fd, LOCK_UN) == 0)
        #expect(!PrefixStore.isInUse(prefix, root: root))
    }

    @Test("A claim keeps the preparation lock until it is released")
    func claimHoldsThePreparationLock() throws {
        let dir = try scratchDirectory("pfx-claim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        let root = dir.appending(path: "sockets")

        let claim = try #require(PrefixStore.claim(prefix, root: root))
        #expect(PrefixStore.isInUse(prefix, root: root))
        #expect(PrefixStore.claim(prefix, root: root) == nil)
        claim.release()
        #expect(!PrefixStore.isInUse(prefix, root: root))
    }

    @Test("A linked preparation lock is not mistaken for an idle prefix")
    func linkedPreparationLockIsInUse() throws {
        let dir = try scratchDirectory("pfx-preparation-link")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        let outside = dir.appending(path: "outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: prefix.root.appending(path: ".notproton-prefix.lock"), withDestinationURL: outside)

        #expect(PrefixStore.isInUse(prefix, root: dir.appending(path: "sockets")))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    }

    @Test("Only the parked prefixes count as backups")
    func backupsIgnoreEverythingElseInTheEntry() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)
        let fm = FileManager.default

        let entry = library.compatdata.appending(path: "1574480")
        for folder in ["pfx", "pfx.rebuild", "notproton-msync",
                       "pfx.previous-20260101-120000", "pfx.previous-20260102-133000"] {
            try fm.createDirectory(
                at: entry.appending(path: folder), withIntermediateDirectories: true)
        }
        try write("not a prefix", to: entry.appending(path: "pfx.previous-note.txt"))

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)

        #expect(PrefixStore.backups(of: prefix).map(\.lastPathComponent)
            == ["pfx.previous-20260101-120000", "pfx.previous-20260102-133000"])
    }

    @Test("Backing up a prefix copies it into a listed slot and leaves the prefix alone")
    func backUpCopiesTheLivePrefix() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        try write("save", to: prefix.pfx.appending(path: "user.reg"))
        let taken = try #require(PrefixStore.backupClock().date(from: "20260101-120000"))

        let slot = try PrefixTools.backUp(prefix, now: taken)

        #expect(slot.lastPathComponent == "pfx.previous-20260101-120000")
        #expect(PrefixStore.backups(of: prefix).map(\.lastPathComponent)
            == ["pfx.previous-20260101-120000"])
        #expect(try String(contentsOf: slot.appending(path: "user.reg"), encoding: .utf8) == "save")
        #expect(
            try String(contentsOf: prefix.pfx.appending(path: "user.reg"), encoding: .utf8)
                == "save")
    }

    @Test("A backup that can't finish leaves no partial copy to trust")
    func failedBackUpLeavesNothing() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        try write("copied first", to: prefix.pfx.appending(path: "a.sav"))
        let unreadable = prefix.pfx.appending(path: "z.sav")
        try write("save", to: unreadable)
        let path = unreadable.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        #expect(throws: (any Error).self) { try PrefixTools.backUp(prefix) }

        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    @Test("Backing up refuses a game that has never made a prefix")
    func backUpRefusesAMissingPrefix() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        try FileManager.default.removeItem(at: prefix.pfx)

        let refusal = try #require(throws: StepFailure.self) { try PrefixTools.backUp(prefix) }
        #expect(refusal.detail.hasPrefix(prefix.title))
        #expect(refusal.detail.hasSuffix("."))
        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    @Test("A backup carries the time in its name back out as a date")
    func backupDetailsReadTheStamp() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        let entry = library.compatdata.appending(path: "1574480")
        try write("live", to: entry.appending(path: "pfx/drive_c/users/crossover/save.dat"))
        try write("older", to: entry.appending(path: "pfx.previous-20260101-120000/user.reg"))
        try write("newer", to: entry.appending(path: "pfx.previous-20260102-133000-2/user.reg"))

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        let details = PrefixStore.backupDetails(of: prefix)

        #expect(details.count == 2)
        #expect(details.allSatisfy { $0.bytes > 0 })
        #expect(details.map(\.prefix) == [prefix, prefix])

        let clock = PrefixStore.backupClock()
        #expect(details[0].taken == clock.date(from: "20260101-120000"))
        #expect(details[1].taken == clock.date(from: "20260102-133000"))
    }

    @Test("A parked prefix with no readable stamp still lists, without a date")
    func backupWithoutAStampHasNoDate() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        let entry = library.compatdata.appending(path: "1574480")
        try write("live", to: entry.appending(path: "pfx/user.reg"))
        try write("old", to: entry.appending(path: "pfx.previous/user.reg"))

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        let details = PrefixStore.backupDetails(of: prefix)

        #expect(details.count == 1)
        #expect(details[0].taken == nil)
        #expect(PrefixStore.backupDate(of: details[0].url) == nil)
    }

    @Test("A library on the boot volume is named by its folder alone")
    func bootVolumeLibraryIsNotQualified() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = PrefixStore.library(at: dir)
        #expect(library.volume == nil)
        #expect(library.displayName == dir.lastPathComponent)
        #expect(PrefixStore.volumeName(of: dir) == nil)
    }

    @Test("A library on another drive is named by the drive alone")
    func externalLibraryNamesTheDrive() {
        let root = URL(filePath: "/Volumes/External Games SSD/SteamLibrary")
        let library = SteamLibrary(root: root, volume: "External Games SSD")

        // Every library folder Steam makes is called SteamLibrary, so naming it beside the
        // drive spends the column on a word that is the same for every row.
        #expect(library.displayName == "External Games SSD")
        #expect(SteamLibrary(root: root).displayName == "SteamLibrary")
    }

    @Test("A prefix points at the game's install folder while the game is installed")
    func findsTheInstallDirectory() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)

        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"1574480"
            \t"installdir"\t\t"Agent 64"
            }
            """, to: library.steamapps.appending(path: "appmanifest_1574480.acf"))

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        #expect(PrefixStore.installDirectory(of: prefix) == nil)

        // The manifest can name a folder that is not there, which is what an uninstalled
        // game with a leftover prefix looks like.
        let installed = library.steamapps.appending(path: "common/Agent 64")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        #expect(
            PrefixStore.installDirectory(of: prefix)?.path(percentEncoded: false)
                == installed.path(percentEncoded: false))
    }

    // A prefix's ntdll, cut down to the two fields the arch is read out of: e_lfanew at
    // 0x3c, and the machine word four bytes past the signature it points at.
    private func writeNtdll(machine: UInt16?, in pfx: URL, lfanew: UInt32 = 0x40) throws {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        withUnsafeBytes(of: lfanew.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        if let machine {
            bytes += [0x50, 0x45, 0x00, 0x00]
            bytes += withUnsafeBytes(of: machine.littleEndian) { Array($0) }
        }
        let dll = pfx.appending(path: "drive_c/windows/system32/ntdll.dll")
        try FileManager.default.createDirectory(
            at: dll.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: dll)
    }

    private func prefix(in dir: URL) throws -> WinePrefix {
        let library = SteamLibrary(root: dir)
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)
        return try #require(PrefixStore.all(libraries: [library]).first)
    }

    // The one signal on disk that separates the two tools. system.reg says #arch=win64 for both
    // and carries no PROCESSOR_ARCHITECTURE, so the wrong flavor is invisible without a PE read.
    @Test("A prefix names the compatibility tool that built it through its own ntdll")
    func readsPrefixArch() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)

        for (machine, expected) in [
            (UInt16(0xaa64), PrefixArch.arm64),
            (UInt16(0x8664), PrefixArch.x86_64),
            (UInt16(0x014c), PrefixArch.i386),
        ] {
            try writeNtdll(machine: machine, in: prefix.pfx)
            #expect(PrefixStore.arch(of: prefix) == expected)
        }
    }

    // Every one of these is a prefix nothing can be said about, and a rebuild must not be
    // demanded on the strength of a header that was never read.
    @Test("An unreadable header is no arch rather than a wrong one")
    func unreadableArchIsNil() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)

        // Never booted, so wineboot has installed nothing.
        #expect(PrefixStore.arch(of: prefix) == nil)

        // A machine type wine does not build for.
        try writeNtdll(machine: 0x1234, in: prefix.pfx)
        #expect(PrefixStore.arch(of: prefix) == nil)

        // e_lfanew pointing past the end of the file.
        try writeNtdll(machine: 0xaa64, in: prefix.pfx, lfanew: 0x40000)
        #expect(PrefixStore.arch(of: prefix) == nil)

        // A DOS header with no PE header behind it.
        try writeNtdll(machine: nil, in: prefix.pfx)
        #expect(PrefixStore.arch(of: prefix) == nil)

        // Not a PE at all.
        let dll = prefix.pfx.appending(path: "drive_c/windows/system32/ntdll.dll")
        try write("just text", to: dll)
        #expect(PrefixStore.arch(of: prefix) == nil)

        // Six readable bytes where the PE header should be. The length checks pass, so only the
        // signature stands between a half written file and a word read out of whatever is there.
        var stub = [UInt8](repeating: 0, count: 0x40)
        withUnsafeBytes(of: UInt32(0x40).littleEndian) { stub.replaceSubrange(0x3c..<0x40, with: $0) }
        stub += [0x4d, 0x5a, 0x00, 0x00, 0x64, 0x86]
        try Data(stub).write(to: dll)
        #expect(PrefixStore.arch(of: prefix) == nil)
    }

    @Test("An idle prefix is not reported as in use")
    func idlePrefixIsNotInUse() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        // A freshly made directory has never had a wineserver, so the socket directory
        // named after its device and inode cannot exist.
        #expect(PrefixStore.serverDirectory(of: prefix) != nil)
        #expect(PrefixStore.isInUse(prefix) == false)
    }

    // Everything below needs the socket directory to be there, since a prefix whose directory
    // is absent is answered before lsof is reached at all.
    private func prefixWithServerDirectory() throws -> (WinePrefix, URL, URL) {
        let dir = try scratchDirectory("pfx")
        let library = SteamLibrary(root: dir)
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx"), withIntermediateDirectories: true)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        let root = dir.appending(path: "wine-sockets")
        let socket = try #require(PrefixStore.serverDirectory(of: prefix, root: root))
        try FileManager.default.createDirectory(at: socket, withIntermediateDirectories: true)
        return (prefix, root, dir)
    }

    private func stubLsof(in dir: URL, body: String) throws -> String {
        let path = dir.appending(path: "lsof")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path(percentEncoded: false))
        return path.path(percentEncoded: false)
    }

    @Test("A prefix whose socket directory is held open is reported as in use")
    func heldPrefixIsInUse() throws {
        let (prefix, root, dir) = try prefixWithServerDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = try #require(PrefixStore.serverDirectory(of: prefix, root: root))
            .appending(path: "socket")
        try Data("s".utf8).write(to: held)
        let handle = try FileHandle(forReadingFrom: held)
        defer { try? handle.close() }

        #expect(PrefixStore.isInUse(prefix, root: root))
    }

    // Delete, Rebuild and Back Up go through claim, and the launch lock is gone once a game is
    // up, so during play this is the only thing refusing them.
    @Test("A claim is refused while the server runs or can't be checked, and given when idle")
    func claimAnswersToTheServer() throws {
        let (prefix, root, dir) = try prefixWithServerDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PrefixStore.claim(
            prefix, root: root, lsof: dir.appending(path: "absent").path(percentEncoded: false)) == nil)
        #expect(PrefixStore.claim(
            prefix, root: root, lsof: try stubLsof(in: dir, body: "echo trouble >&2; exit 1")) == nil)
        #expect(PrefixStore.claim(
            prefix, root: root, lsof: try stubLsof(in: dir, body: "sleep 3 & exit 1"),
            drainTimeout: .milliseconds(200)) == nil)

        let claim = try #require(PrefixStore.claim(prefix, root: root))
        claim.release()

        let held = try #require(PrefixStore.serverDirectory(of: prefix, root: root))
            .appending(path: "socket")
        try Data("s".utf8).write(to: held)
        let handle = try FileHandle(forReadingFrom: held)
        defer { try? handle.close() }
        #expect(PrefixStore.claim(prefix, root: root) == nil)
    }

    // A wrong name here reads as "not running" for every game. Wine names the folder after
    // the prefix's device and inode, in hex.
    @Test("The server folder is the one Wine makes for the prefix")
    func serverDirectoryIsWines() throws {
        let dir = try scratchDirectory("pfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = try prefix(in: dir)
        var info = stat()
        try #require(stat(prefix.pfx.path(percentEncoded: false), &info) == 0)
        let name = String(format: "server-%llx-%llx", UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))

        #expect(PrefixStore.serverDirectory(of: prefix)?.lastPathComponent == name)
        #expect(PrefixStore.serverRoot.path(percentEncoded: false) == "/tmp/.wine-\(getuid())")
    }

    // Every one of these used to answer that the prefix was free, which is the answer that
    // deletes a prefix out from under a running game.
    @Test("lsof failing to answer is not read as the prefix being free")
    func anUnusableLsofIsNotReadAsFree() throws {
        let (prefix, root, dir) = try prefixWithServerDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Nothing to run at all.
        #expect(PrefixStore.isInUse(
            prefix, root: root, lsof: dir.appending(path: "absent").path(percentEncoded: false)))

        // Ran, said nothing, complained.
        #expect(PrefixStore.isInUse(
            prefix, root: root,
            lsof: try stubLsof(in: dir, body: "echo trouble >&2; exit 1")))

        // Ran, exited as lsof does when it finds nothing, but left its output open.
        #expect(PrefixStore.isInUse(
            prefix, root: root,
            lsof: try stubLsof(in: dir, body: "sleep 3 & exit 1"),
            drainTimeout: .milliseconds(200)))
    }

    // The other half of the same decision: a real lsof reporting nothing has to stay a no, or
    // no prefix could ever be rebuilt.
    @Test("An idle socket directory is still reported as free")
    func anIdleSocketDirectoryIsFree() throws {
        let (prefix, root, dir) = try prefixWithServerDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PrefixStore.isInUse(prefix, root: root) == false)
    }
}
