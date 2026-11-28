import Foundation
import Testing

@testable import BridgeplayApp

// Fixture folders only: every path is passed in, the signature check and the Trash are stubs,
// so nothing here reads or writes this Mac's Steam, support folders or Trash.
@Suite("Uninstall plan and verify")
struct UninstallPlanTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    private struct Fixture {
        let root: URL
        let paths: UninstallPaths
        let library: SteamLibrary
        var support: URL { root.appending(path: "home/Library/Application Support/bridgeplay") }
        var legacySupport: URL { root.appending(path: "home/Library/Application Support/notproton") }
        var app: URL { paths.app }
        func prefix(_ id: String) -> URL { library.compatdata.appending(path: id) }
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // modified: Steam.app as Bridgeplay leaves it, with every Bridgeplay file in Steam's folders.
    private func fixture(modified: Bool) throws -> Fixture {
        let root = try scratchDirectory("uninstall-plan")
        let home = root.appending(path: "home")
        let steamData = home.appending(path: "Library/Application Support/Steam")
        let app = root.appending(path: "Applications/Steam.app")
        let inner = steamData.appending(path: "Steam.AppBundle/Steam/Contents")
        let library = SteamLibrary(root: root.appending(path: "Library Drive"), volume: nil)
        let support = home.appending(path: "Library/Application Support/bridgeplay")
        let keptFixes = home.appending(path: "Library/Application Support/bridgeplay-gamefixes")
        let agents = home.appending(path: "Library/LaunchAgents")
        let bridgeplayApp = root.appending(path: "Applications/Bridgeplay.app")
        let users = root.appending(path: "Users")

        try write("1\n", support.appending(path: "dylib.version"))
        try write("old\n", home.appending(path: "Library/Application Support/notproton/app.log"))
        try write("x\n", home.appending(path: "Library/Caches/bridgeplay/a.zip"))
        try write("x\n", home.appending(path: ".bridgeplay/np-native"))
        try write("fix\n", keptFixes.appending(path: "123.conf"))
        try write("x", agents.appending(path: "com.notproton.helper.plist"))
        try write("x", agents.appending(path: "com.example.other.plist"))
        try write("x", bridgeplayApp.appending(path: "Contents/Info.plist"))
        try write("\"AppState\"\n{\n\t\"appid\"\t\t\"100\"\n\t\"name\"\t\t\"Game One\"\n}\n",
                  library.steamapps.appending(path: "appmanifest_100.acf"))
        try write(String(repeating: "s", count: 4096), library.compatdata.appending(path: "100/pfx/drive_c/save.dat"))
        try write("x", library.compatdata.appending(path: "200/pfx/user.reg"))
        for name in ["raymond", "steven", "Shared", ".localized"] {
            try FileManager.default.createDirectory(at: users.appending(path: name), withIntermediateDirectories: true)
        }
        try write("x", users.appending(path: "notauser"))

        let plist: [String: Any] = ["CFBundleIdentifier": SteamRepair.valveIdentifier]
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        if modified {
            var injected = plist
            injected[SteamBundle.environmentKey] = [SteamBundle.insertKey: "/x/\(SupportPaths.dylibName)"]
            try SteamBundle.writeInfoPlist(injected, at: app.appending(path: "Contents/Info.plist"))
            try SteamBundle.writeInfoPlist(injected, at: inner.appending(path: "Info.plist"))
            try write("x", app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)"))
            try write("\(UpdateBlock.contents)", steamData.appending(path: "steam.cfg"))
            try write("x", steamData.appending(path: "compatibilitytools.d/bridgeplay-proton-winecx/toolmanifest.vdf"))
            try write("x", inner.appending(path: "MacOS/legacycompat/Steam.dll"))
            try write("x", library.compatdata.appending(path: "notproton-template/crossover-1/x"))
            try FileManager.default.createDirectory(at: library.steamapps.appending(path: "common"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: library.steamapps.appending(path: "common/Steam.dll"),
                withDestinationURL: inner.appending(path: "MacOS/legacycompat/Steam.dll"))
        } else {
            try SteamBundle.writeInfoPlist(plist, at: app.appending(path: "Contents/Info.plist"))
            try SteamBundle.writeInfoPlist(plist, at: inner.appending(path: "Info.plist"))
        }
        // Not Bridgeplay's: stays in every case.
        try write("x", steamData.appending(path: "compatibilitytools.d/GE-Proton9-1/toolmanifest.vdf"))

        let paths = UninstallPaths(
            app: app,
            innerPlist: inner.appending(path: "Info.plist"),
            updateBlocks: [steamData.appending(path: "steam.cfg"), inner.appending(path: "MacOS/steam.cfg")],
            legacyCompat: inner.appending(path: "MacOS/legacycompat"),
            compatTools: steamData.appending(path: "compatibilitytools.d"),
            owned: [
                support, home.appending(path: "Library/Application Support/notproton"),
                home.appending(path: "Library/Caches/bridgeplay"), home.appending(path: "Library/Caches/notproton"),
                home.appending(path: ".bridgeplay"), home.appending(path: ".notproton"),
                home.appending(path: "Library/Application Support/bridgeplay-steam-bundles.json"),
            ],
            launchAgents: agents,
            keptGamefixes: keptFixes,
            libraries: [library],
            userdata: steamData.appending(path: "userdata"),
            appFiles: [bridgeplayApp, home.appending(path: "Library/Preferences/com.bridgeplay.Bridgeplay.plist")],
            users: users,
            userName: "raymond")
        return Fixture(root: root, paths: paths, library: library)
    }

    private func plan(_ fixture: Fixture, modified: Bool = true) -> UninstallPlan {
        UninstallPlan.make(paths: fixture.paths, steamModified: { _ in modified }, keptOffline: { true },
                           measure: { PrefixStore.directoryBytes($0) })
    }

    @Test("The plan lists this account's Bridgeplay files under new and old names, and only those")
    func planListsOwnedFiles() throws {
        let fixture = try fixture(modified: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = Set(plan(fixture).remove.map(\.url.lastPathComponent))

        #expect(names.isSuperset(of: ["bridgeplay", "notproton", ".bridgeplay", "com.notproton.helper.plist",
                                      "bridgeplay-proton-winecx", "legacycompat", "notproton-template", "Steam.dll"]))
        #expect(names.contains("bridgeplay") && names.contains("notproton"))
        // Absent folders are not listed, and nothing that is not Bridgeplay's is.
        #expect(!names.contains(".notproton"))
        #expect(!names.contains("GE-Proton9-1"))
        #expect(!names.contains("com.example.other.plist"))
        #expect(!names.contains("100") && !names.contains("200"))
        #expect(!names.contains("bridgeplay-gamefixes"))
    }

    @Test("Prefixes are offered with their sizes and stay unless picked")
    func prefixesAreOptional() throws {
        let fixture = try fixture(modified: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = plan(fixture)

        #expect(plan.prefixes.map(\.prefix.appID).sorted() == ["100", "200"])
        let game = try #require(plan.prefixes.first { $0.prefix.appID == "100" })
        #expect(game.prefix.title == "Game One")
        #expect(game.bytes >= 4096)
        #expect(plan.prefixBytes >= game.bytes)
        let kept = Set(plan.keeps.map(\.url))
        #expect(kept.contains(fixture.prefix("100")) && kept.contains(fixture.prefix("200")))
        #expect(kept.contains(fixture.paths.keptGamefixes))
        #expect(kept.contains(fixture.paths.appFiles[0]))
        // The preferences file does not exist in the fixture, so it is not claimed to stay.
        #expect(!kept.contains(fixture.paths.appFiles[1]))
        #expect(plan.steamModified && plan.steamKeptOffline)
    }

    @Test("Other accounts are named, without this one, Shared or plain files")
    func otherAccounts() throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.paths.otherUsers() == ["steven"])
    }

    @Test("Verify passes on Valve's Steam with nothing of Bridgeplay's in it")
    func verifyPassesWhenClean() throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = UninstallVerification.run(paths: fixture.paths, signature: { _ in .valve })

        #expect(result.leftInSteam.isEmpty)
        #expect(result.passed)
        #expect(result.text.contains("[ok]"))
        #expect(!result.text.contains("[!!]"))
    }

    @Test("Verify names every Bridgeplay file left in Steam")
    func verifyNamesLeftovers() throws {
        let fixture = try fixture(modified: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = UninstallVerification.run(paths: fixture.paths, signature: { _ in .valve })
        let names = Set(result.leftInSteam.map(\.url.lastPathComponent))

        #expect(!result.passed)
        #expect(names.isSuperset(of: [SupportPaths.dylibName, "Info.plist", "steam.cfg", "bridgeplay-proton-winecx",
                                      "legacycompat", "notproton-template", "Steam.dll"]))
        // Both plists: the outer bundle's and the inner one Steam runs from.
        #expect(result.leftInSteam.filter { $0.url.lastPathComponent == "Info.plist" }.count == 2)
        #expect(!names.contains("GE-Proton9-1"))
        #expect(result.leftForUser.contains { $0.url == fixture.support })
    }

    @Test("Verify fails when Steam is not Valve's, even with nothing of Bridgeplay's in it")
    func verifyNeedsValvesSignature() throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let adHoc = UninstallVerification.run(paths: fixture.paths, signature: { _ in .notValve("ad hoc") })
        #expect(!adHoc.passed)
        #expect(adHoc.text.contains("not signed by Valve"))
        #expect(!UninstallVerification.run(paths: fixture.paths, signature: { _ in .missing }).passed)
    }

    @Test("The real signature check rejects a bundle that is not Valve's")
    func liveSignatureRejectsFixture() throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(UninstallVerification.liveSignature(fixture.app) != .valve)
        #expect(UninstallVerification.liveSignature(fixture.root.appending(path: "None.app")) == .missing)
    }

    @Test("The checklist splits removed, trashed and kept, and says what could not go")
    func checklist() throws {
        let fixture = try fixture(modified: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = plan(fixture)
        let trashed = try #require(plan.prefixes.first { $0.prefix.appID == "100" })
        // Everything removed except the old notproton folder.
        for item in plan.remove where item.url != fixture.legacySupport {
            try? FileManager.default.removeItem(at: item.url)
        }
        try FileManager.default.removeItem(at: trashed.prefix.root)
        try FileManager.default.removeItem(at: fixture.app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)"))
        let clean: [String: Any] = ["CFBundleIdentifier": SteamRepair.valveIdentifier]
        try SteamBundle.writeInfoPlist(clean, at: fixture.app.appending(path: "Contents/Info.plist"))
        try SteamBundle.writeInfoPlist(clean, at: fixture.paths.innerPlist)
        try FileManager.default.removeItem(at: fixture.paths.updateBlocks[0])

        let outcome = UninstallOutcome(
            steamInstalled: true, restoredValveSignature: true, removed: [],
            trashed: [UninstallItem(url: trashed.prefix.root, bytes: trashed.bytes)],
            trashedPrefixes: [trashed.id])
        let verification = UninstallVerification.run(paths: fixture.paths, signature: { _ in .valve })
        let list = UninstallChecklist.make(plan: plan, outcome: outcome, paths: fixture.paths, verification: verification)

        #expect(verification.passed)
        #expect(!list.removed.contains { $0.url == fixture.legacySupport })
        #expect(list.removed.contains { $0.url == fixture.support })
        #expect(list.remains.contains { $0.url == fixture.legacySupport && $0.note == "Not removed" })
        #expect(list.trashed.map(\.url) == [trashed.prefix.root])
        #expect(list.remains.contains { $0.url == fixture.prefix("200") })
        #expect(!list.remains.contains { $0.url == fixture.prefix("100") })
        #expect(list.otherUsers == ["steven"])
        #expect(list.text.contains("Moved to the Trash:"))
        #expect(list.text.contains("steven"))
    }

    @Test("Remove Everything moves only the picked prefixes to the Trash and keeps old game fixes")
    func removalTrashesPickedPrefixes() async throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prefixes = PrefixStore.all(libraries: [fixture.library], userdata: fixture.paths.userdata)
        let picked = try #require(prefixes.first { $0.appID == "100" })
        try write("mine\n", fixture.legacySupport.appending(path: "gamefixes/42.conf"))
        let kept = fixture.root.appending(path: "kept-gamefixes")
        let trash = Recorder()
        let unloaded = Recorder()
        let leftovers = Uninstall.Leftovers(
            gamefixes: fixture.support.appending(path: "gamefixes"),
            legacyGamefixes: fixture.legacySupport.appending(path: "gamefixes"),
            keptGamefixes: kept,
            steamConfig: fixture.root.appending(path: "config.vdf"),
            defaultToolBackup: fixture.support.appending(path: "backups/steam-default-tool.json"),
            files: [],
            steamRunning: { false },
            launchAgents: fixture.paths.ourLaunchAgents(),
            unloadAgent: { unloaded.add($0) })

        let outcome = try await Uninstall.run(
            app: fixture.root.appending(path: "Missing/Steam.app"), innerPlist: fixture.paths.innerPlist,
            updateBlocks: fixture.paths.updateBlocks, legacyCompat: fixture.paths.legacyCompat,
            compatTools: [], directories: [fixture.support, fixture.legacySupport], libraries: [fixture.library],
            modifications: SteamModifications(file: fixture.root.appending(path: "bundles.json"),
                                              legacyRecord: fixture.support.appending(path: "install-build.json")),
            lockFolder: fixture.root, leftovers: leftovers,
            stop: { _, _ in false },
            trashPrefixes: [picked],
            trash: { trash.add($0) })

        #expect(trash.all == [picked.root])
        #expect(outcome.trashedPrefixes == [picked.id])
        #expect(outcome.notTrashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.prefix("200").path))
        #expect(unloaded.all.map(\.lastPathComponent) == ["com.notproton.helper.plist"])
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgents.appending(path: "com.notproton.helper.plist").path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.launchAgents.appending(path: "com.example.other.plist").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.legacySupport.path))
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "42.conf").path))
    }

    @Test("A prefix the Trash refuses stays and is reported, and the rest is still removed")
    func refusedTrashIsReported() async throws {
        let fixture = try fixture(modified: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prefixes = PrefixStore.all(libraries: [fixture.library], userdata: fixture.paths.userdata)
        let leftovers = Uninstall.Leftovers(
            gamefixes: fixture.support.appending(path: "gamefixes"), keptGamefixes: fixture.root.appending(path: "kept"),
            steamConfig: fixture.root.appending(path: "config.vdf"),
            defaultToolBackup: fixture.support.appending(path: "backups/x.json"), files: [], steamRunning: { false })

        let outcome = try await Uninstall.run(
            app: fixture.root.appending(path: "Missing/Steam.app"), innerPlist: fixture.paths.innerPlist,
            updateBlocks: fixture.paths.updateBlocks, legacyCompat: fixture.paths.legacyCompat,
            compatTools: [], directories: [fixture.support], libraries: [fixture.library],
            modifications: SteamModifications(file: fixture.root.appending(path: "bundles.json"),
                                              legacyRecord: fixture.support.appending(path: "install-build.json")),
            lockFolder: fixture.root, leftovers: leftovers,
            stop: { _, _ in false },
            trashPrefixes: prefixes,
            trash: { _ in throw CocoaError(.featureUnsupported) })

        #expect(outcome.trashed.isEmpty)
        #expect(outcome.notTrashed.count == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.prefix("100").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.support.path))
    }

    @Test("--trash-prefixes takes all or app ids, and refuses an unknown id before anything runs")
    func trashFlag() throws {
        let found = [
            WinePrefix(appID: "100", name: nil, library: SteamLibrary(root: URL(filePath: "/a")), lastUsed: nil),
            WinePrefix(appID: "200", name: nil, library: SteamLibrary(root: URL(filePath: "/a")), lastUsed: nil),
        ]
        let flag = RemoveEverythingCommand.trashFlag
        #expect(try RemoveEverythingCommand.prefixes(["x", "--remove-everything"], in: found).isEmpty)
        #expect(try RemoveEverythingCommand.prefixes([flag, "all"], in: found).count == 2)
        #expect(try RemoveEverythingCommand.prefixes([flag, "200"], in: found).map(\.appID) == ["200"])
        #expect(try RemoveEverythingCommand.prefixes([flag, "100, 200"], in: found).count == 2)
        #expect(throws: RemoveEverythingCommand.UnknownPrefix.self) {
            try RemoveEverythingCommand.prefixes([flag, "100,999"], in: found)
        }
        #expect(throws: RemoveEverythingCommand.UnknownPrefix.self) {
            try RemoveEverythingCommand.prefixes([flag], in: found)
        }
    }

    @Test("The command line asks before quitting Steam, on a terminal only")
    func asksBeforeQuittingSteam() {
        #expect(RemoveEverythingCommand.confirmQuittingSteam(interactive: false, steamRunning: { true }, answer: { nil }))
        #expect(RemoveEverythingCommand.confirmQuittingSteam(interactive: true, steamRunning: { false }, answer: { nil }))
        #expect(RemoveEverythingCommand.confirmQuittingSteam(interactive: true, steamRunning: { true }, answer: { "Y" }, ask: { _ in }))
        #expect(!RemoveEverythingCommand.confirmQuittingSteam(interactive: true, steamRunning: { true }, answer: { "" }, ask: { _ in }))
        #expect(!RemoveEverythingCommand.confirmQuittingSteam(interactive: true, steamRunning: { true }, answer: { nil }, ask: { _ in }))
    }

    @Test("The plan text names the shared Steam and the prefixes it keeps")
    func planText() throws {
        let fixture = try fixture(modified: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let text = UninstallCheckCommand.planText(plan(fixture))
        #expect(text.contains(fixture.support.plainPath))
        #expect(text.contains("no download"))
        #expect(text.contains("100  Game One"))
        #expect(text.contains("steven"))
        #expect(text.contains(fixture.paths.keptGamefixes.plainPath))
    }
}
