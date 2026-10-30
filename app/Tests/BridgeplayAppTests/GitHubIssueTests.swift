import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Bug report links")
struct GitHubIssueTests {

    private func fields(of url: URL) throws -> [String: String] {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
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
