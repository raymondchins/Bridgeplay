import Foundation

// --uninstall-plan lists what Remove Everything would remove and what stays, changing nothing.
// --verify-uninstall checks that Steam.app is Valve's signed copy with no Bridgeplay file left
// in Steam; it exits 0 only then.
enum UninstallCheckCommand {
    static let planFlag = "--uninstall-plan"
    static let verifyFlag = "--verify-uninstall"

    static var requested: String? {
        let arguments = CommandLine.arguments.dropFirst()
        return [planFlag, verifyFlag].first { arguments.contains($0) }
    }

    static func run(_ flag: String) -> Never {
        let paths = UninstallPaths.live
        if flag == planFlag {
            print(planText(UninstallPlan.make(paths: paths)))
            exit(AppLog.finished(0))
        }
        let verification = UninstallVerification.run(paths: paths)
        print(verification.text)
        if !verification.leftForUser.isEmpty {
            print("This account still has Bridgeplay files:")
            verification.leftForUser.forEach { print("  \($0.path)") }
        }
        exit(AppLog.finished(verification.passed ? 0 : 1))
    }

    static func planText(_ plan: UninstallPlan) -> String {
        var lines = ["Remove Everything would remove:"]
        lines += plan.remove.map { "  \($0.path)" + ($0.size.map { "  (\($0))" } ?? "") }
        if plan.remove.isEmpty { lines.append("  nothing: no Bridgeplay files found for this account") }
        lines.append(plan.steamModified
            ? (plan.steamKeptOffline
                ? "Steam.app: restored from Valve's signed copy kept on this Mac (no download)"
                : "Steam.app: restored from Valve's signed copy, downloaded from Valve")
            : "Steam.app: no Bridgeplay changes found")
        lines += plan.otherSteamCopies.map { "Also restored: \($0.plainPath)" }
        lines.append("Steam quits first. Steam's own settings are changed only after it has quit.")
        if !plan.prefixes.isEmpty {
            lines.append("Game prefixes (kept unless named with \(RemoveEverythingCommand.trashFlag) <appid,...|all>; then moved to the Trash):")
            lines += plan.prefixes.map { "  \($0.prefix.appID)  \($0.prefix.title)  \($0.size)  \($0.prefix.root.plainPath)" }
        }
        let stays = plan.keeps.filter { item in !plan.prefixes.contains { $0.prefix.root == item.url } }
        if !stays.isEmpty {
            lines.append("Stays:")
            lines += stays.map { "  \($0.path)" + ($0.note.map { "  (\($0))" } ?? "") }
        }
        if !plan.otherUsers.isEmpty {
            lines.append("Steam.app is shared: other accounts on this Mac (\(plan.otherUsers.joined(separator: ", "))) "
                + "stop getting Bridgeplay in Steam, and keep their own Bridgeplay files until they remove them.")
        }
        return lines.joined(separator: "\n")
    }
}
