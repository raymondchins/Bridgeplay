import Foundation
import BridgeplayInstallerCore
import BridgeplayUI

enum InstallerReport {
    static func issueURL(failure: String, version: String, installed: String?) -> URL? {
        let clean = InstallerLog.redact(failure)
        return GitHubIssue.bugReport(
            title: "Installer: \(GitHubIssue.summary(clean))",
            what: "The installer stopped with:\n\n\(clean)",
            version: "Installer, offering \(version)" + (installed.map { ", installed \($0)" } ?? ""),
            mac: InstallerLog.system,
            logs: InstallerLog.tail())
    }
}
