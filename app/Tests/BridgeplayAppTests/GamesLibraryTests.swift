import Foundation
import Testing

@testable import BridgeplayApp

// The Games page's list, read from synthetic libraries in a temporary folder.
@Suite("Games list")
struct GamesLibraryTests {

    private final class Fixture {
        let root: URL

        init() throws {
            root = URL.temporaryDirectory.appending(path: "bp-games-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func library(_ name: String) throws -> SteamLibrary {
            let library = SteamLibrary(root: root.appending(path: name))
            try FileManager.default.createDirectory(at: library.compatdata, withIntermediateDirectories: true)
            return library
        }

        func manifest(_ appID: String, _ name: String, in library: SteamLibrary) throws {
            try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"name\"\t\t\"\(name)\"\n}\n".utf8)
                .write(to: library.steamapps.appending(path: "appmanifest_\(appID).acf"))
        }

        @discardableResult
        func compatdata(_ appID: String, in library: SteamLibrary, pfx: Bool) throws -> URL {
            let folder = library.compatdata.appending(path: appID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if pfx { try FileManager.default.createDirectory(at: folder.appending(path: "pfx"), withIntermediateDirectories: true) }
            return folder
        }

        var userdata: URL { root.appending(path: "userdata") }
    }

    @Test("Installed games with a compatdata folder, on every library; leftovers are left out")
    func scansLibraries() throws {
        let fixture = try Fixture()
        let home = try fixture.library("internal")
        let external = try fixture.library("external")

        try fixture.manifest("100", "Hades", in: home)
        let hades = try fixture.compatdata("100", in: home, pfx: true)
        try Data("version=1\ncode=crashed\nexit=5\nseconds=40\nstopped=game\nbackend=d3dmetal\nengine=winecx-11.17\nended=1800000000\n".utf8)
            .write(to: hades.appending(path: LaunchRecord.fileName))

        // Never got as far as Wine: no pfx, still listed.
        try fixture.manifest("200", "Blocked Game", in: external)
        try fixture.compatdata("200", in: external, pfx: false)
        try Data("dxvk\nfrom the game's conf\n".utf8)
            .write(to: external.compatdata.appending(path: "200/notproton-backend"))

        // Uninstalled: a prefix with no manifest anywhere.
        try fixture.compatdata("300", in: home, pfx: true)
        // Installed but never run under a compatibility tool (macOS-native): no compatdata.
        try fixture.manifest("400", "Native Game", in: home)
        // Moved to the external drive: a compatdata on both, the one beside the install wins.
        try fixture.manifest("500", "Moved Game", in: external)
        try fixture.compatdata("500", in: home, pfx: true)
        try fixture.compatdata("500", in: external, pfx: true)
        // Not an appid.
        try fixture.compatdata("0", in: home, pfx: true)
        try FileManager.default.createDirectory(at: home.compatdata.appending(path: "tmp"), withIntermediateDirectories: true)

        let games = GamesLibrary.scan(libraries: [home, external], userdata: fixture.userdata)
        #expect(games.map(\.appID) == ["200", "100", "500"])

        let first = try #require(games.first { $0.appID == "100" })
        #expect(first.title == "Hades")
        #expect(first.hasPrefix)
        #expect(first.record?.verdict == .crashed)
        #expect(first.backend == "d3dmetal")
        #expect(first.record?.engine == "winecx-11.17")

        let blocked = try #require(games.first { $0.appID == "200" })
        #expect(!blocked.hasPrefix)
        #expect(blocked.record == nil)
        #expect(blocked.backend == "dxvk")
        #expect(blocked.prefix.library == external)

        let moved = try #require(games.first { $0.appID == "500" })
        #expect(moved.prefix.library == external)
    }

    @Test("No libraries or an empty one list nothing")
    func empty() throws {
        let fixture = try Fixture()
        #expect(GamesLibrary.scan(libraries: [], userdata: fixture.userdata).isEmpty)
        let library = try fixture.library("one")
        #expect(GamesLibrary.scan(libraries: [library], userdata: fixture.userdata).isEmpty)
    }

    @Test("Play opens Steam's rungameid; a shortcut's game id carries its appid in the high bits")
    func playURL() throws {
        let library = SteamLibrary(root: URL(filePath: "/nonexistent"))
        func game(_ appID: String) -> InstalledGame {
            InstalledGame(prefix: WinePrefix(appID: appID, name: "x", library: library, lastUsed: nil),
                          hasPrefix: false, record: nil, backendFile: nil, installedIn: library)
        }
        #expect(GamesLibrary.playURL(game("1091500"))?.absoluteString == "steam://rungameid/1091500")
        let shortcut: UInt64 = 0x8000_1234
        #expect(GamesLibrary.playURL(game(String(shortcut)))?.absoluteString
            == "steam://rungameid/\((shortcut << 32) | 0x0200_0000)")
    }

    @Test("The Prefix menu on Games follows the game its table selected")
    func prefixSelectionFollowsTheTable() {
        let library = SteamLibrary(root: URL(filePath: "/nonexistent"))
        func game(_ appID: String, prefix: Bool) -> InstalledGame {
            InstalledGame(prefix: WinePrefix(appID: appID, name: "x", library: library, lastUsed: nil),
                          hasPrefix: prefix, record: nil, backendFile: nil, installedIn: library)
        }
        let games = [game("10", prefix: true), game("20", prefix: false)]
        #expect(GamesLibrary.prefixSelection(games[0].id, in: games) == [games[0].prefix.id])
        #expect(GamesLibrary.prefixSelection(games[1].id, in: games).isEmpty)
        #expect(GamesLibrary.prefixSelection(nil, in: games).isEmpty)
        #expect(GamesLibrary.prefixSelection("gone", in: games).isEmpty)
    }

    @Test("Backend ids read as their projects write them")
    func backendLabels() {
        #expect(GamesLibrary.backendLabel("d3dmetal") == "D3DMetal")
        #expect(GamesLibrary.backendLabel("wined3d") == "WineD3D")
        #expect(GamesLibrary.backendLabel("dxmt") == "DXMT")
        #expect(GamesLibrary.backendLabel("dxmt-builtin") == "DXMT")
        #expect(GamesLibrary.backendLabel("dxvk") == "DXVK")
    }

    @Test("The icon is Steam's hash-named jpg, not the header or cover")
    func icon() throws {
        let fixture = try Fixture()
        let cache = fixture.root.appending(path: "librarycache")
        let folder = cache.appending(path: "100")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hash = String(repeating: "a1", count: 20)
        for name in ["header.jpg", "library_600x900.jpg", "\(hash).jpg"] {
            try Data([0xff]).write(to: folder.appending(path: name))
        }
        #expect(GamesLibrary.iconFile(appID: "100", cache: cache)?.lastPathComponent == "\(hash).jpg")
        #expect(GamesLibrary.iconFile(appID: "999", cache: cache) == nil)

        // Newer Steam keeps it one folder down.
        let nested = cache.appending(path: "200/abc")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0xff]).write(to: nested.appending(path: "\(hash).jpg"))
        #expect(GamesLibrary.iconFile(appID: "200", cache: cache)?.lastPathComponent == "\(hash).jpg")
    }

    @Test("The model lists first, then reads the run log for games without a record")
    @MainActor
    func modelLoads() async throws {
        let fixture = try Fixture()
        let library = try fixture.library("lib")
        try fixture.manifest("100", "Logged Game", in: library)
        try fixture.compatdata("100", in: library, pfx: true)
        let log = "=== bridgeplay run Wed Oct 21 20:00:00 WIB 2026 ===\nverb=waitforexitandrun\n=== aborted during engine check\n"
        try Data(log.utf8).write(to: PrefixLog.launch.url(for: WinePrefix(appID: "100", name: nil, library: library, lastUsed: nil)))

        let model = GamesModel(libraries: { [library] }, userdata: fixture.userdata,
                               iconCache: fixture.root.appending(path: "none"))
        await model.load()
        let game = try #require(model.games.first)
        #expect(model.hasLoaded)
        #expect(model.verdict(game) == .aborted)
        #expect(model.lastLaunch(game) != nil)
        #expect(model.engine(game) == nil)
    }

    @Test("The Engine column names an engine one way, from a launch record or a prefix's build record")
    func engineNameIsOneName() {
        let launch = SupportedRunners.displayVersion(forID: "winecx-11.17")
        #expect(SupportedRunners.engineName(build: "winecx-11.17", display: "Bridgeplay (WineCX 11.17)") == launch)
        #expect(SupportedRunners.engineName(build: "winecx-11.17", display: "WineCX 11.17 (msync, D3DMetal)") == launch)
        #expect(SupportedRunners.engineName(build: "some-unknown-build", display: "Proton 9") == "Proton 9")
        #expect(SupportedRunners.engineName(build: "some-unknown-build", display: nil) == "some-unknown-build")
    }
}
