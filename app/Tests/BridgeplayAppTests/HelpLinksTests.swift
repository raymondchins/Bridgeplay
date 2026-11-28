import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Help menu links")
struct HelpLinksTests {

    private func fields(of url: URL) throws -> [String: String] {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    @Test("The site pages are the ones the README already links")
    func pagesExistInTheReadme() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: repo.appending(path: "README.md"), encoding: .utf8)
        for url in [HelpLinks.guides, HelpLinks.faq, HelpLinks.compatibility] {
            #expect(readme.contains(url.absoluteString), "\(url) is not a page the README links")
        }
        #expect(HelpLinks.releaseNotes.absoluteString == "https://github.com/raymondchins/Bridgeplay/releases")
    }

    @Test("Report a Problem opens a blank bug report with the version and a redacted log")
    func problemReport() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "helplinks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "app.log")
        try "first\nopened \(NSHomeDirectory())/Library/x\nlast line\n".write(to: log, atomically: true, encoding: .utf8)

        let sent = try fields(of: try #require(HelpLinks.problemReport(log: log)))

        #expect(sent["template"] == "bug-report.yml")
        #expect(sent["title"] == "")
        #expect(sent["what"] == "")
        #expect(sent["version"] == ProductVersion.display)
        let logs = try #require(sent["logs"])
        #expect(logs.contains("last line"))
        #expect(!logs.contains(NSHomeDirectory()), "the home folder reached the report")
    }

    @Test("A missing log still gives a report")
    func noLog() throws {
        let url = try #require(HelpLinks.problemReport(log: URL(filePath: "/nonexistent-\(UUID().uuidString)/app.log")))
        #expect(try fields(of: url)["logs"] == "")
    }

    // Rules from bridgeplay-web's compat-slug.js, with its examples.
    @Test("Game slugs follow the site's rules")
    func slugs() {
        #expect(HelpLinks.slug("Pokémon Legends", appID: "1") == "pokemon-legends")
        #expect(HelpLinks.slug("Marvel’s Spider-Man Remastered", appID: "1") == "marvels-spider-man-remastered")
        #expect(HelpLinks.slug("Batman™: Arkham Knight", appID: "1") == "batman-arkham-knight")
        #expect(HelpLinks.slug("Command & Conquer", appID: "1") == "command-and-conquer")
        #expect(HelpLinks.slug("  --Hades II--  ", appID: "1") == "hades-ii")
        #expect(HelpLinks.slug("Ｆｕｌｌｗｉｄｔｈ ２", appID: "1") == "fullwidth-2")
        #expect(HelpLinks.slug("原神", appID: "1234") == "app-1234")
        // Cut to 80, then no dash at the end.
        #expect(HelpLinks.slug(String(repeating: "abcd ", count: 30), appID: "1")
                == Array(repeating: "abcd", count: 16).joined(separator: "-"))
    }

    @Test("See Reports opens the game's page; the site redirects <slug>-<appid> to it")
    func gamePage() {
        #expect(HelpLinks.gamePage(appID: "1145360", name: "Hades").absoluteString
                == "https://bridgeplay.dev/compatibility/hades-1145360")
        #expect(HelpLinks.gamePage(appID: "1145360", name: nil).absoluteString
                == "https://bridgeplay.dev/compatibility/1145360")
        #expect(HelpLinks.gamePage(appID: "1234", name: "原神").absoluteString
                == "https://bridgeplay.dev/compatibility/1234")
        // A non-Steam game has no Steam app id on the site, only its name.
        #expect(HelpLinks.gamePage(appID: "3000000000", name: "My Game").absoluteString
                == "https://bridgeplay.dev/compatibility/my-game")
        #expect(HelpLinks.gamePage(appID: "3000000000", name: nil) == HelpLinks.compatibility)
    }
}
