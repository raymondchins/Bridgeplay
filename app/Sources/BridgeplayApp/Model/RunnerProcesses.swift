// Which Wine processes keep a runner busy, and stopping the ones a quit game left behind (#4777).

import Darwin
import Foundation

struct RunnerProcess: Sendable, Hashable {
    let pid: pid_t
    let name: String
    let build: String
}

// What keeps the runners busy: Wine processes running from a clone, a Steam run script
// starting a game, or both.
struct RunnerActivity: Sendable, Equatable {
    let build: String
    var processes: [RunnerProcess] = []
    var launching = false

    // Wine processes while no run script is live: what a game that has quit left behind.
    var isLeftover: Bool { !launching && !processes.isEmpty }

    var names: String {
        var seen = Set<String>()
        return processes.map(\.name).filter { seen.insert($0).inserted }.formatted(.list(type: .and))
    }

    // Every build a listed process runs from, so leftovers on two clones are named together.
    var builds: String {
        var seen = Set<String>()
        let listed = processes.map(\.build).filter { seen.insert($0).inserted }
        return (listed.isEmpty ? [build] : listed).formatted(.list(type: .and))
    }

    // `plain` when no process could be named, `named` otherwise. Leftovers get a hint, and the
    // failure carries them so Status can offer to stop them.
    func refusal(step: String, plain: String, named: String) -> StepFailure {
        guard !processes.isEmpty else { return StepFailure(step: step, detail: plain) }
        let detail = isLeftover
            ? named + " " + (Set(processes.map(\.name)).count == 1
                ? String(localized: "No game is starting, so it is probably left over from a game that quit.")
                : String(localized: "No game is starting, so they are probably left over from a game that quit."))
            : named
        return StepFailure(step: step, detail: detail, busyRunner: self)
    }
}

extension RunnerInstaller {

    static let stopStep = String(localized: "Stopping leftover Wine processes")

    // Every busy runner at once, so a leftover is never mistaken for one while a game starts.
    static func activity(
        in runners: URL = SupportPaths.runners,
        processes: (URL) -> [RunnerProcess]? = { RunnerInstaller.processes(in: $0) },
        launching: () throws -> String? = { try RunnerInstaller.launchingScript() }
    ) -> RunnerActivity? {
        // When ps cannot say whether a run script is live, a game may be starting: its Wine
        // processes are then never taken for leftovers.
        let starting: String?, maybeStarting: Bool
        do {
            starting = try launching()
            maybeStarting = starting != nil
        } catch {
            starting = nil
            maybeStarting = true
        }
        guard let found = processes(runners) else {
            // ps failed: count every clone as busy, as isRunning does, without names.
            return (RunnerStore.clonedBuilds(in: runners).first ?? starting)
                .map { RunnerActivity(build: $0, launching: maybeStarting) }
        }
        if let first = found.first {
            return RunnerActivity(build: first.build, processes: found, launching: maybeStarting)
        }
        return starting.map { RunnerActivity(build: $0, launching: true) }
    }

    // The processes running from any clone in `runners`, or nil when ps fails.
    static func processes(in runners: URL = SupportPaths.runners, ps: String = "/bin/ps") -> [RunnerProcess]? {
        processes(under: RunnerStore.clonedBuilds(in: runners).map {
            (build: $0, root: SupportPaths.runnerRoot(forBuild: $0, runners: runners))
        }, ps: ps)
    }

    static func processes(under roots: [(build: String, root: URL)], ps: String = "/bin/ps") -> [RunnerProcess]? {
        guard !roots.isEmpty else { return [] }
        guard let listed = try? Shell.run(ps, ["-axww", "-o", "pid=", "-o", "comm="]), listed.succeeded
        else { return nil }
        let commands = pidLines(listed.stdout)
        var matched: [(pid: pid_t, command: String, build: String)] = []
        for (build, root) in roots {
            let prefixes = rootPrefixes(root)
            for (pid, command) in commands where prefixes.contains(where: { command.hasPrefix($0) }) {
                matched.append((pid, command, build))
            }
        }
        guard !matched.isEmpty else { return [] }
        // Wine puts the Windows path in a process's arguments; its command stays the loader.
        // ps exits 1 when one of the pids has gone, and still prints the others.
        let args = (try? Shell.run(ps, ["-ww", "-o", "pid=", "-o", "args=", "-p",
                                        matched.map { String($0.pid) }.joined(separator: ",")]))
            .map { Dictionary(pidLines($0.stdout), uniquingKeysWith: { first, _ in first }) } ?? [:]
        return matched.map { RunnerProcess(pid: $0.pid, name: processName(args: args[$0.pid], command: $0.command), build: $0.build) }
    }

    // "  123 /path with spaces/wineserver" -> (123, "/path with spaces/wineserver")
    static func pidLines(_ output: String) -> [(pid_t, String)] {
        output.split(separator: "\n").compactMap { line in
            let line = line.drop { $0 == " " || $0 == "\t" }
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = pid_t(line[..<space])
            else { return nil }
            let rest = line[space...].drop { $0 == " " || $0 == "\t" }
            return rest.isEmpty ? nil : (pid, String(rest))
        }
    }

    // explorer.exe for "C:\windows\system32\explorer.exe /desktop", wineserver for its path.
    static func processName(args: String?, command: String) -> String {
        if let args, let exe = args.range(of: ".exe", options: .caseInsensitive),
           let name = args[..<exe.upperBound].split(whereSeparator: { $0 == "\\" || $0 == "/" }).last {
            return String(name)
        }
        return String(command.split(separator: "/").last ?? Substring(command))
    }

    static func rootPrefixes(_ root: URL) -> [String] {
        // ps prints the resolved path, and a clone can be a link to another drive.
        let path = root.standardizedFileURL.path(percentEncoded: false)
        return [path, realpath(path, nil).map { defer { free($0) }; return String(cString: $0) }]
            .compactMap { $0 }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    // Stops the leftovers the user confirmed, never while Steam is open or a run script is
    // starting a game. SIGTERM first: wineserver saves the prefix's registry on it, and its
    // clients exit once it has gone. What is still there after `patience` gets SIGKILL.
    // A process that was not confirmed gets no signal; the retry names it again.
    static func stopLeftovers(
        _ confirmed: RunnerActivity,
        steamRunning: () -> Bool = { SteamBundle.isRunning },
        busy: () -> RunnerActivity? = { RunnerInstaller.activity() },
        signal: (pid_t, Int32) -> Void = { _ = kill($0, $1) },
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.25) },
        patience: Int = 40
    ) throws {
        let refused = StepFailure(step: stopStep, detail: String(localized: "A game is starting or Steam is open, so Bridgeplay stopped nothing."))
        guard var current = busy() else { return }
        guard current.isLeftover, !steamRunning() else { throw refused }
        func notStopped() -> StepFailure {
            StepFailure(step: stopStep, detail: String(localized: "Could not stop \(current.names). Restart the Mac to end the leftover processes."))
        }
        // Only confirmed pids the last look still found under a clone get a signal.
        current.processes = current.processes.filter(confirmed.processes.contains)
        for sig in [SIGTERM, SIGKILL] {
            guard !current.processes.isEmpty else { return }
            for process in current.processes { signal(process.pid, sig) }
            for _ in 0..<patience {
                pause()
                guard let now = busy() else { return }
                if now.launching || steamRunning() { throw refused }
                // ps failed, so nothing can be signalled safely.
                guard !now.processes.isEmpty else { throw notStopped() }
                let left = now.processes.filter(confirmed.processes.contains)
                if left.isEmpty { return }
                current.processes = left
            }
            AppLog.note("leftover Wine processes still running after signal \(sig): \(current.names)")
        }
        throw notStopped()
    }
}
