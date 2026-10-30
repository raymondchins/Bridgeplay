import AppKit
import BridgeplayUI

// Any failure the app shows can go to GitHub as a bug report with the redacted end of
// app.log, which the user reviews before posting.
enum ErrorReport {
    static let reportLabel = String(localized: "Report on GitHub")

    @MainActor
    static func actions(_ failure: String, in place: String) -> [StatusAction] {
        [StatusAction(label: reportLabel) { open(failure, in: place) },
         StatusAction(label: String(localized: "Show Log")) { showLog() }]
    }

    @MainActor
    static func open(_ failure: String, in place: String) {
        AppLog.note("reporting from \(place): \(failure)")
        guard let url = url(failure, in: place) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
    }

    static func url(_ failure: String, in place: String, log: URL = AppLog.file) -> URL? {
        let clean = GameReport.redacted(failure)
        return GitHubIssue.bugReport(
            title: "\(place): \(GitHubIssue.summary(clean))",
            what: "\(place) showed:\n\n\(clean)",
            version: ProductVersion.display,
            mac: [SetupChecks.chipName, SetupChecks.macOSDisplay].filter { !$0.isEmpty }.joined(separator: ", "),
            logs: GameReport.redacted(GitHubIssue.tail(of: log)))
    }
}
