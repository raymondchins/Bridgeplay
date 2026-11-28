import AppKit
import BridgeplayUI

// The Help menu's pages. All of them exist already: the site's guides, FAQ and
// compatibility list, the GitHub releases, and the bug report form.
enum HelpLinks {
    static let guides = URL(string: "https://bridgeplay.dev/guides")!
    static let faq = URL(string: "https://bridgeplay.dev/faq")!
    static let compatibility = URL(string: "https://bridgeplay.dev/compatibility")!
    static let releaseNotes = URL(string: "https://github.com/raymondchins/Bridgeplay/releases")!
    static let antiCheatAlternatives = URL(string: "https://bridgeplay.dev/guides/anti-cheat-on-mac#alternatives")!

    // The game's page. The site redirects "<anything>-<appid>" to the game's slug, whichever
    // name it settled a collision with, and a game it lacks gets a page suggesting close names.
    // Non-Steam games have no Steam app id there, only their name.
    static func gamePage(appID: String, name: String?) -> URL {
        let shortcut = UInt32(appID).map { $0 & 0x8000_0000 != 0 } ?? false
        let words = name.map { slug($0, appID: appID) }.flatMap { $0 == "app-\(appID)" ? nil : $0 }
        let path: String? = switch (words, shortcut) {
        case (let words?, false): "\(words)-\(appID)"
        case (let words?, true): words
        case (nil, false): appID
        case (nil, true): nil
        }
        return path.map { compatibility.appending(path: $0) } ?? compatibility
    }

    // bridgeplay-web's compat-slug.js, rules 1 to 4.
    static func slug(_ name: String, appID: String) -> String {
        let marks: ClosedRange<UInt32> = 0x300...0x36F
        let kept = name.unicodeScalars.filter { !"™®©".unicodeScalars.contains($0) }
        let plain = String(String(kept).decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !marks.contains($0.value) })
        var out = ""
        var dash = false
        for scalar in plain.lowercased().replacing("&", with: " and ").unicodeScalars {
            if "'’‘`´".unicodeScalars.contains(scalar) { continue }
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if dash, !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        out = String(out.prefix(80))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "app-\(appID)" : out
    }

    // A blank bug report with the version, the Mac and the redacted end of app.log filled in.
    // The user writes the rest and reviews it on GitHub before posting.
    static func problemReport(log: URL = AppLog.file) -> URL? {
        GitHubIssue.bugReport(
            title: "",
            what: "",
            version: ProductVersion.display,
            mac: [SetupChecks.chipName, SetupChecks.macOSDisplay].filter { !$0.isEmpty }.joined(separator: ", "),
            logs: GameReport.redacted(GitHubIssue.tail(of: log)))
    }

    @MainActor
    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func reportProblem() {
        AppLog.note("help: report a problem")
        open(problemReport())
    }
}
