import Darwin
import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Wine processes that keep a runner busy")
struct RunnerProcessesTests {

    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(pid_t, Int32)] = []
        func add(_ pid: pid_t, _ sig: Int32) { lock.withLock { sent.append((pid, sig)) } }
        var all: [(pid_t, Int32)] { lock.withLock { sent } }
        var kinds: [Int32] { all.map(\.1) }
    }

    private static func process(_ pid: pid_t, _ name: String) -> RunnerProcess {
        RunnerProcess(pid: pid, name: name, build: "winecx-11.17")
    }

    private static let leftover = RunnerActivity(
        build: "winecx-11.17", processes: [process(10, "wineserver"), process(11, "explorer.exe")])

    @Test("ps lines keep paths with spaces and skip what is not a pid")
    func parsesPidLines() {
        let lines = RunnerInstaller.pidLines("""
              123 /Users/a/Library/Application Support/Bridgeplay/runners/crossover-27/bin/wineserver
            45\tC:\\windows\\system32\\explorer.exe /desktop
            junk line
              9
            """)
        #expect(lines.map(\.0) == [123, 45])
        #expect(lines[0].1 == "/Users/a/Library/Application Support/Bridgeplay/runners/crossover-27/bin/wineserver")
        #expect(lines[1].1 == "C:\\windows\\system32\\explorer.exe /desktop")
    }

    @Test("A process is named by its Windows program, or else by its command")
    func namesProcesses() {
        #expect(RunnerInstaller.processName(args: "C:\\windows\\system32\\explorer.exe /desktop", command: "/r/bin/wine") == "explorer.exe")
        #expect(RunnerInstaller.processName(args: "Z:\\Games\\My Game\\Game.EXE -windowed", command: "/r/bin/wine") == "Game.EXE")
        #expect(RunnerInstaller.processName(args: "/r/bin/wineserver", command: "/r/bin/wineserver") == "wineserver")
        #expect(RunnerInstaller.processName(args: nil, command: "/r/bin/wine-preloader") == "wine-preloader")
    }

    @Test("Processes under a clone are listed with their names, others are not")
    func listsProcessesUnderAClone() throws {
        let fm = FileManager.default
        let dir = URL(filePath: try scratchDirectory("runner-processes").path(percentEncoded: false)).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let root = runners.appending(path: "crossover-winecx-11.17").path(percentEncoded: false)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let ps = dir.appending(path: "ps")
        try """
            #!/bin/sh
            case "$*" in
            *comm=*) printf '  10 %s/CrossOver/bin/wineserver\\n  11 %s/CrossOver/bin/wine\\n  12 /usr/bin/other\\n  13 %sx/bin/wine\\n' "\(root)" "\(root)" "\(root)" ;;
            *) printf '10 %s/CrossOver/bin/wineserver\\n11 C:\\\\windows\\\\system32\\\\explorer.exe /desktop\\n' "\(root)" ;;
            esac
            """.write(to: ps, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))

        let found = try #require(RunnerInstaller.processes(in: runners, ps: ps.path(percentEncoded: false)))
        #expect(found == [Self.process(10, "wineserver"), Self.process(11, "explorer.exe")])
        #expect(RunnerInstaller.processes(in: runners, ps: "/nonexistent/ps") == nil)
        #expect(RunnerInstaller.processes(in: dir.appending(path: "none"), ps: "/nonexistent/ps") == [])
    }

    @Test("Only Wine processes with no run script live count as leftovers")
    func decidesLeftovers() throws {
        let runners = try scratchDirectory("runner-activity")
        defer { try? FileManager.default.removeItem(at: runners) }
        try FileManager.default.createDirectory(at: runners.appending(path: "crossover-winecx-11.17"), withIntermediateDirectories: true)
        let found = Self.leftover.processes

        let left = try #require(RunnerInstaller.activity(in: runners, processes: { _ in found }, launching: { nil }))
        #expect(left.isLeftover)
        #expect(left.build == "winecx-11.17")

        let starting = try #require(RunnerInstaller.activity(in: runners, processes: { _ in found }, launching: { "winecx-11.17" }))
        #expect(!starting.isLeftover)

        let scriptOnly = try #require(RunnerInstaller.activity(in: runners, processes: { _ in [] }, launching: { "winecx-11.17" }))
        #expect(scriptOnly.launching && scriptOnly.processes.isEmpty && !scriptOnly.isLeftover)

        // ps failing still counts the clone as busy, but nothing is offered for stopping.
        let unknown = try #require(RunnerInstaller.activity(in: runners, processes: { _ in nil }, launching: { nil }))
        #expect(unknown.build == "winecx-11.17" && !unknown.isLeftover)

        #expect(RunnerInstaller.activity(in: runners, processes: { _ in [] }, launching: { nil }) == nil)

        // ps failing for the run scripts may hide a game that is starting: never a leftover.
        let blind = try #require(RunnerInstaller.activity(in: runners, processes: { _ in found },
                                                          launching: { throw RunnerInstaller.ProcessListFailed() }))
        #expect(blind.launching && !blind.isLeftover)
        #expect(RunnerInstaller.activity(in: runners, processes: { _ in [] },
                                         launching: { throw RunnerInstaller.ProcessListFailed() }) == nil)
    }

    @Test("The refusal names what runs, and only leftovers carry an offer")
    func refusalNamesProcesses() {
        let named = Self.leftover.refusal(step: "Repair Steam", plain: "plain", named: "named: \(Self.leftover.names).")
        #expect(named.detail.hasPrefix("named: wineserver"))
        #expect(named.detail.contains("explorer.exe"))
        #expect(named.busyRunner == Self.leftover)

        var starting = Self.leftover
        starting.launching = true
        let game = starting.refusal(step: "Repair Steam", plain: "plain", named: "named")
        #expect(game.detail == "named")
        #expect(game.busyRunner?.isLeftover == false)

        let bare = RunnerActivity(build: "27.0.0").refusal(step: "Repair Steam", plain: "plain", named: "named")
        #expect(bare.detail == "plain" && bare.busyRunner == nil)
    }

    @Test("The leftover hint says it for one process name, they for several")
    func leftoverHintAgrees() {
        #expect(Self.leftover.refusal(step: "s", plain: "p", named: "n").detail.contains("so they are"))
        let one = RunnerActivity(build: "winecx-11.17", processes: [
            RunnerProcess(pid: 1, name: "wineserver", build: "winecx-11.17"),
            RunnerProcess(pid: 2, name: "wineserver", build: "winecx-11.17"),
        ])
        #expect(one.refusal(step: "s", plain: "p", named: "n").detail.contains("so it is"))
    }

    @Test("Nothing is stopped while Steam is open or a game is starting")
    func refusesToStopUnderAGame() {
        let signals = Signals()
        #expect(throws: StepFailure.self) {
            try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { true }, busy: { Self.leftover },
                                              signal: signals.add, pause: {})
        }
        var starting = Self.leftover
        starting.launching = true
        #expect(throws: StepFailure.self) {
            try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false }, busy: { starting },
                                              signal: signals.add, pause: {})
        }
        #expect(signals.all.isEmpty)
    }

    @Test("Leftovers get SIGTERM, and SIGKILL only if they outlast it")
    func stopsLeftovers() throws {
        let gentle = Signals()
        try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                          busy: { gentle.all.isEmpty ? Self.leftover : nil },
                                          signal: gentle.add, pause: {})
        #expect(gentle.all.map(\.0) == [10, 11])
        #expect(gentle.kinds == [SIGTERM, SIGTERM])

        // explorer.exe ignores SIGTERM and only gets SIGKILL from the second pass.
        let stubborn = Signals()
        let stuck = RunnerActivity(build: "winecx-11.17", processes: [Self.process(11, "explorer.exe")])
        try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                          busy: { stubborn.kinds.contains(SIGKILL) ? nil : (stubborn.all.isEmpty ? Self.leftover : stuck) },
                                          signal: stubborn.add, pause: {}, patience: 3)
        #expect(stubborn.kinds == [SIGTERM, SIGTERM, SIGKILL])
        #expect(stubborn.all.last?.0 == 11)

        let immortal = Signals()
        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false }, busy: { stuck },
                                              signal: immortal.add, pause: {}, patience: 2)
        }
        #expect(failure.detail.contains("explorer.exe"))
        #expect(immortal.kinds == [SIGTERM, SIGKILL])
    }

    @Test("A game starting while leftovers stop ends the stop before SIGKILL")
    func gameStartingStopsTheStop() {
        let signals = Signals()
        var starting = Self.leftover
        starting.launching = true
        #expect(throws: StepFailure.self) {
            try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                              busy: { signals.all.isEmpty ? Self.leftover : starting },
                                              signal: signals.add, pause: {})
        }
        #expect(signals.kinds == [SIGTERM, SIGTERM])
    }

    @Test("Only processes the user confirmed get a signal, even ones Wine starts while it stops")
    func signalsOnlyConfirmedProcesses() throws {
        // A process on another clone that the dialog never named is left alone.
        let other = RunnerProcess(pid: 20, name: "notepad.exe", build: "crossover-27")
        let both = RunnerActivity(build: "winecx-11.17", processes: Self.leftover.processes + [other])
        let skipped = Signals()
        try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                          busy: { skipped.all.isEmpty ? both : RunnerActivity(build: "crossover-27", processes: [other]) },
                                          signal: skipped.add, pause: {})
        #expect(skipped.all.map(\.0) == [10, 11])

        // A child started during the SIGTERM wait is neither terminated nor killed.
        let spawned = Signals()
        let child = Self.process(30, "winedevice.exe")
        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                              busy: { spawned.all.isEmpty ? Self.leftover
                                                      : RunnerActivity(build: "winecx-11.17", processes: [Self.process(10, "wineserver"), child]) },
                                              signal: spawned.add, pause: {}, patience: 2)
        }
        #expect(!spawned.all.contains { $0.0 == 30 })
        #expect(spawned.all.map(\.0) == [10, 11, 10])
        #expect(failure.detail.contains("wineserver") && !failure.detail.contains("winedevice.exe"))

        // Nothing confirmed still runs: no signal, and the retry looks again.
        let none = Signals()
        try RunnerInstaller.stopLeftovers(Self.leftover, steamRunning: { false },
                                          busy: { RunnerActivity(build: "winecx-11.17", processes: [child]) },
                                          signal: none.add, pause: {})
        #expect(none.all.isEmpty)
    }

    @Test("Leftovers on two clones name both builds")
    func namesEveryBuild() {
        let two = RunnerActivity(build: "winecx-11.17", processes: Self.leftover.processes
                                 + [RunnerProcess(pid: 20, name: "wineserver", build: "crossover-27")])
        #expect(two.builds.contains("winecx-11.17") && two.builds.contains("crossover-27"))
        #expect(two.names.components(separatedBy: "wineserver").count == 2)
        #expect(RunnerActivity(build: "27.0.0").builds == "27.0.0")
    }
}
