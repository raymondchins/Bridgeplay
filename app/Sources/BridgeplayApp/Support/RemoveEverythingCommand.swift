import Foundation

enum RemoveEverythingCommand {
    static let flag = "--remove-everything"

    // `--trash-prefixes all` or a comma-separated list of app ids: those prefixes go to the Trash.
    static let trashFlag = "--trash-prefixes"

    static func run() -> Never {
        Task.detached {
            let paths = UninstallPaths.live
            let plan = UninstallPlan.make(paths: paths)
            let picked: [WinePrefix]
            do {
                picked = try prefixes(CommandLine.arguments, in: plan.prefixes.map(\.prefix))
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(AppLog.finished(2))
            }
            guard confirmQuittingSteam() else {
                FileHandle.standardError.write(Data("Nothing was changed.\n".utf8))
                exit(AppLog.finished(1))
            }
            let code = await perform(remove: {
                try await Uninstall.run(leftovers: .live, report: $0, trashPrefixes: picked)
            }, finish: { outcome in
                UninstallChecklist.make(plan: plan, outcome: outcome, paths: paths,
                                        verification: .run(paths: UninstallPaths.live)).text
            })
            exit(AppLog.finished(code))
        }
        dispatchMain()
    }

    struct UnknownPrefix: LocalizedError {
        let ids: [String]
        var errorDescription: String? {
            "No prefix for app id \(ids.joined(separator: ", ")). --uninstall-plan lists them. Nothing was changed."
        }
    }

    static func prefixes(_ arguments: [String], in found: [WinePrefix]) throws -> [WinePrefix] {
        guard let index = arguments.firstIndex(of: trashFlag) else { return [] }
        let value = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        if value == "all" { return found }
        let ids = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let missing = ids.filter { id in !found.contains { $0.appID == id } }
        guard !ids.isEmpty, missing.isEmpty else { throw UnknownPrefix(ids: ids.isEmpty ? [value] : missing) }
        return found.filter { ids.contains($0.appID) }
    }

    // Asks on a terminal only; a script that runs --remove-everything has already asked.
    static func confirmQuittingSteam(
        interactive: Bool = isatty(STDIN_FILENO) == 1,
        steamRunning: () -> Bool = { SteamBundle.isRunningForThisUser },
        answer: () -> String? = { readLine() },
        ask: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    ) -> Bool {
        guard interactive, steamRunning() else { return true }
        ask("Steam is running. Quit Steam and remove Bridgeplay? [y/N] ")
        return ["y", "yes"].contains(answer()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
    }

    static func perform(
        remove: @Sendable (@escaping @Sendable (UninstallPhase) -> Void) async throws -> UninstallOutcome = {
            try await Uninstall.run(leftovers: .live, report: $0)
        },
        finish: @Sendable (UninstallOutcome) -> String? = { _ in nil }
    ) async -> Int32 {
        do {
            let output = Output()
            let result = try await remove { phase in
                if case .restoring(.finished) = phase { return }
                output.say(phase.label)
            }
            output.say(
                result.partialRemoval ?? (result.steamNeedsRedownload
                    ? "Bridgeplay has been removed. Steam could not be restored. "
                        + "Reinstall Steam from steampowered.com before using it again."
                    : "Bridgeplay has been removed.")
            )
            if let kept = result.keptGamefixes {
                output.say("Your own game fixes were kept in \(kept.path(percentEncoded: false)).")
            }
            if let checklist = finish(result) { output.say(checklist) }
            return result.partialRemoval == nil ? 0 : 1
        } catch {
            AppLog.note("command line failed: \(failureMessage(error))")
            FileHandle.standardError.write(Data("\(failureMessage(error))\n".utf8))
            return 1
        }
    }

    static func failureMessage(_ error: Error) -> String {
        guard let refused = error as? WriteRefused else { return error.localizedDescription }
        // The app's advice, except where the command line asks for something else.
        let advice = switch refused.remedy {
        case .appManagement:
            "Allow your terminal app in System Settings > Privacy & Security > App Management, then run it again."
        case .otherAccount:
            "Steam was installed by another account on this Mac. Run this again while logged in to that account."
        case .rootOwned, .ownership:
            refused.remedy.advice
        }
        return "Could not write \(refused.path). \(advice)"
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var last: String?

        func say(_ line: String) {
            lock.withLock {
                guard line != last else { return }
                last = line
                FileHandle.standardOutput.write(Data("\(line)\n".utf8))
            }
        }
    }
}
