import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Leftover prefixes")
struct LeftoverPrefixesTests {

    private func touch(_ url: URL, _ text: String = "") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func prefix(_ appID: String, in library: SteamLibrary) throws {
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "\(appID)/pfx"), withIntermediateDirectories: true)
    }

    private func manifest(_ appID: String, name: String, in library: SteamLibrary) throws {
        try touch(library.steamapps.appending(path: "appmanifest_\(appID).acf"),
                  "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"name\"\t\t\"\(name)\"\n}\n")
    }

    @Test("Only a prefix whose game is gone from every library is a leftover")
    func findsUninstalled() throws {
        let dir = try scratchDirectory("leftover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = SteamLibrary(root: dir.appending(path: "Steam"))
        let external = SteamLibrary(root: dir.appending(path: "External"))

        try prefix("49520", in: main)              // uninstalled
        try prefix("1091500", in: main)            // installed here
        try manifest("1091500", name: "Cyberpunk 2077", in: main)
        try prefix("292030", in: main)             // moved to the other drive
        try manifest("292030", name: "The Witcher 3", in: external)
        try prefix("570", in: main)                // on an unplugged drive, still listed
        try prefix("0", in: main)                  // Steam's shared prefix
        try prefix("2147483649", in: main)         // a non-Steam shortcut
        try FileManager.default.createDirectory(   // no prefix inside
            at: main.compatdata.appending(path: "730"), withIntermediateDirectories: true)

        let scan = LeftoverPrefixes.scan(
            libraries: [main, external], listedApps: ["570"], kept: [], names: ["49520": "Borderlands 2"])
        #expect(scan.leftovers.map(\.appID) == ["49520"])
        #expect(scan.leftovers.first?.title == "Borderlands 2")
        #expect(scan.names == ["1091500": "Cyberpunk 2077", "292030": "The Witcher 3"])
    }

    @Test("A kept prefix isn't offered again")
    func skipsKept() throws {
        let dir = try scratchDirectory("leftover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = SteamLibrary(root: dir.appending(path: "Steam"))
        try prefix("49520", in: main)
        try prefix("8930", in: main)
        let kept = WinePrefix(appID: "49520", name: nil, library: main, lastUsed: nil).id

        let scan = LeftoverPrefixes.scan(libraries: [main], listedApps: [], kept: [kept], names: [:])
        #expect(scan.leftovers.map(\.appID) == ["8930"])
        #expect(scan.leftovers.first?.title == String(localized: "App 8930"))
    }

    @Test("Every library's apps are read, and nothing else")
    func readsListedApps() {
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/tester/Library/Application Support/Steam"
        \t\t"contentid"\t\t"123"
        \t\t"apps"
        \t\t{
        \t\t\t"480"\t\t"1906055"
        \t\t\t"49520"\t\t"0"
        \t\t}
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"/Volumes/Games/SteamLibrary"
        \t\t"apps"
        \t\t{
        \t\t\t"570"\t\t"30000000"
        \t\t}
        \t\t"time_last_update_verified"\t\t"0"
        \t}
        }
        """
        #expect(LeftoverPrefixes.listedApps(in: vdf) == ["480", "49520", "570"])
    }
}
