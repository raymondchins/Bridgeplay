import BridgeplayUI
import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Bug report links")
struct GitHubIssueTests {

    private func fields(of url: URL) throws -> [String: String] {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    @Test("Every field survives the link, whatever it holds")
    func fieldsRoundTrip() throws {
        let awkward = "a&b=c+d #e?f\nsecond line"
        let url = try #require(GitHubIssue.bugReport(
            title: awkward, what: awkward, version: awkward, mac: awkward, logs: awkward))

        let sent = try fields(of: url)

        #expect(sent["template"] == "bug-report.yml")
        for name in ["title", "what", "version", "macos", "logs"] {
            #expect(sent[name] == awkward, "\(name) was changed on the way")
        }
    }

    // GitHub drops a prefill whose name is not a field of the form, and says nothing.
    @Test("Every prefilled field exists in the issue form")
    func fieldsMatchTheForm() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let form = try String(contentsOf: repo.appending(path: ".github/ISSUE_TEMPLATE/bug-report.yml"), encoding: .utf8)
        let ids = form.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("id: ") ? String(trimmed.dropFirst(4)) : nil
        }
        let url = try #require(GitHubIssue.bugReport(title: "t", what: "w", version: "v", mac: "m", logs: "l"))

        let names = Set(try fields(of: url).keys).subtracting(["template", "title"])

        #expect(names == Set(ids))
    }

    @Test("A title is the failure's first line, cut to 80 characters")
    func summaryIsOneShortLine() {
        #expect(GitHubIssue.summary("first\nsecond") == "first")
        #expect(GitHubIssue.summary(String(repeating: "x", count: 200)) == String(repeating: "x", count: 80))
        #expect(GitHubIssue.summary("") == "")
    }

    @Test("The log's tail keeps to its line and size limits")
    func tailIsCapped() throws {
        let dir = try scratchDirectory("issue-tail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "app.log")
        try Data("one\ntwo\nthree\nfour".utf8).write(to: log)

        #expect(GitHubIssue.tail(of: log, lines: 2) == "three\nfour")
        #expect(GitHubIssue.tail(of: log, lines: 2, maxCharacters: 4) == "four")
        #expect(GitHubIssue.tail(of: dir.appending(path: "missing.log")) == "")
    }

    @Test("A failure's home path stays out of the title as well as the body")
    func failureIsRedactedEverywhere() throws {
        let dir = try scratchDirectory("error-report")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "app.log")
        try Data("wrote \(NSHomeDirectory())/Library/x\n".utf8).write(to: log)
        let failure = "Replacing \(NSHomeDirectory())/Library/Application Support/bridgeplay/x failed."

        let url = try #require(ErrorReport.url(failure, in: "Set up Steam", log: log))
        let sent = try fields(of: url)

        #expect(sent["title"]?.hasPrefix("Set up Steam: Replacing ~/Library") == true)
        #expect(sent["what"]?.contains("~/Library/Application Support/bridgeplay/x failed.") == true)
        #expect(sent["logs"]?.contains("wrote ~/Library/x") == true)
        for value in sent.values {
            #expect(!value.contains(NSHomeDirectory()))
        }
    }
}
