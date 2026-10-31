import AppKit

// Between Play and the game's first window Steam only says Running, and a first launch spends
// most of a minute building the prefix before Wine opens anything. The run script starts this
// beside the launch, after any anti-cheat prompt, and writes the step it is on to
// bridgeplay-launch-step. Nothing here can hold the launch up: the script never waits on it.
enum LaunchProgressCommand {
    // compat_run.sh looks for it in this binary before passing it, so it must stay over 15
    // bytes: Swift keeps shorter strings inside the code, where the search cannot find them.
    static let flag = "--launch-progress"
    // Shared with compat_run.sh.
    static let stepName = "bridgeplay-launch-step"

    // <compatdata> <1 when the prefix is new> <the launcher's Wine log> <the run script's pid>.
    // Never returns.
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count == 4, arguments[0].hasPrefix("/"), arguments[2].hasPrefix("/"),
            let launcher = pid_t(arguments[3])
        else { exit(1) }
        let compatdata = arguments[0]
        // The run script started this, so any other parent means the launch has ended, even
        // one that ended before this got here.
        guard getppid() == launcher else { exit(0) }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            let watcher = LaunchProgressWatcher(
                compatdata: compatdata, progress: LaunchProgress(firstLaunch: arguments[1] == "1"),
                launcher: launcher, wineLog: arguments[2])
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { watcher.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            NSApp.run()
        }
        exit(0)
    }
}

enum LaunchStep: String {
    case setup, prepare, start
    // A Bridgeplay alert is up, which the panel must not cover.
    case dialog
    case ended
}

struct LaunchProgress {
    // A later launch that shows its window within this many seconds shows nothing. Hell Maiden
    // took 12s from the run script to its window on an M4, so most relaunches would never show
    // the panel at 20s; 3s still skips a launch that fails straight away but catches those.
    static let laterDelay: TimeInterval = 3
    // Long enough that a launch failing straight away does not flash the panel.
    static let firstDelay: TimeInterval = 1
    // In case the game hangs before opening anything; Steam's Stop still ends it.
    static let limit: TimeInterval = 15 * 60

    let firstLaunch: Bool

    enum Action: Equatable {
        case hidden
        case shown(LaunchStep?)
        case quit
    }

    func action(step: LaunchStep?, elapsed: TimeInterval, launchEnded: Bool, gameWindow: Bool) -> Action {
        if launchEnded || gameWindow || step == .ended || elapsed >= Self.limit { return .quit }
        if step == .dialog || elapsed < (firstLaunch ? Self.firstDelay : Self.laterDelay) { return .hidden }
        return .shown(step)
    }

    static func message(game name: String?) -> String {
        name.map { String(localized: "Bridgeplay is starting \($0).") }
            ?? String(localized: "Bridgeplay is starting this game.")
    }

    // Without a step the script is somewhere it does not report, so this says no more than that.
    static func phase(_ step: LaunchStep?) -> String {
        switch step {
        case .setup: String(localized: "Setting up Windows for this game…")
        case .prepare: String(localized: "Getting the game ready…")
        case .start: String(localized: "Waiting for the game to open…")
        default: String(localized: "Still starting…")
        }
    }

    var note: String? {
        firstLaunch
            ? String(localized: "The first launch takes longer. The game may show a black screen for a while after it opens.")
            : nil
    }
}

@MainActor
final class LaunchProgressWatcher {
    private let compatdata: String
    private let progress: LaunchProgress
    private let launcher: pid_t
    private let wineLog: String
    private let started = ProcessInfo.processInfo.systemUptime
    private lazy var name = Self.gameName(compatdata: compatdata)
    private var panel: ProgressPanel?
    // The step on screen, nil while hidden.
    private var showing: LaunchStep??
    // Whether each window owner is this game's, by pid and start time so a reused pid is
    // looked at again. A process keeps the files it was started with.
    private var owners: [pid_t: (started: UInt64, game: Bool)] = [:]

    init(compatdata: String, progress: LaunchProgress, launcher: pid_t, wineLog: String) {
        self.compatdata = compatdata
        self.progress = progress
        self.launcher = launcher
        self.wineLog = wineLog
    }

    func tick() {
        let text = try? String(contentsOfFile: compatdata + "/" + LaunchProgressCommand.stepName, encoding: .utf8)
        let step = text.flatMap { LaunchStep(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let action = progress.action(
            step: step, elapsed: ProcessInfo.processInfo.systemUptime - started,
            launchEnded: getppid() != launcher, gameWindow: gameWindowShown())
        switch action {
        case .quit:
            exit(0)
        case .hidden:
            guard showing != nil else { return }
            panel?.panel.orderOut(nil)
            showing = nil
        case .shown(let step):
            guard showing != .some(step) else { return }
            let panel = panel ?? makePanel()
            panel.show(message: LaunchProgress.message(game: name), phase: LaunchProgress.phase(step),
                       note: progress.note)
            panel.present()
            showing = .some(step)
        }
    }

    private func makePanel() -> ProgressPanel {
        let made = ProgressPanel(title: "Bridgeplay", activates: false)
        // Closed by the player: the launch goes on without it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: made.panel, queue: .main) { _ in exit(0) }
        panel = made
        return made
    }

    // Any window of this game's Wine, the game's own or an error Wine shows. Wine forks its
    // processes away from the launcher, and macOS hides other processes' environments, but
    // they all keep the launcher's log as stderr, and that log is this game's alone.
    private func gameWindowShown() -> Bool {
        var log = stat()
        // The launcher creates it, so before the game starts there is nothing to find.
        guard stat(wineLog, &log) == 0 else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = Self.windowOwner(window), pid != getpid() else { continue }
            let started = Self.startTime(of: pid)
            let game: Bool
            if let started, let known = owners[pid], known.started == started {
                game = known.game
            } else {
                game = Self.holdsOpen(device: log.st_dev, inode: log.st_ino, pid: pid)
                if let started { owners[pid] = (started, game) }
            }
            if game { return true }
        }
        return false
    }

    // A full-screen game draws above layer 0 (Megabonk is on 26), so any layer counts: whose
    // window it is decides, and the menu bar and Dock hold no game's log.
    nonisolated static func windowOwner(_ window: [String: Any]) -> pid_t? {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
            let pid = window[kCGWindowOwnerPID as String] as? pid_t,
            let bounds = window[kCGWindowBounds as String] as? [String: Double],
            (bounds["Width"] ?? 0) >= 32, (bounds["Height"] ?? 0) >= 32
        else { return nil }
        return pid
    }

    // Microseconds since 1970 at which the process started, nil when it cannot be read.
    nonisolated static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    nonisolated static func holdsOpen(device: dev_t, inode: ino_t, pid: pid_t) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let wanted = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, wanted) == wanted else { continue }
            let file = info.pvip.vip_vi.vi_stat
            if file.vst_dev == device && file.vst_ino == inode { return true }
        }
        return false
    }

    nonisolated static func gameName(compatdata: String) -> String? {
        let root = URL(filePath: compatdata)
        let steamapps = root.deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent().lastPathComponent == "compatdata",
            steamapps.lastPathComponent == "steamapps"
        else { return nil }
        return PrefixStore.appName(appID: root.lastPathComponent, in: SteamLibrary(root: steamapps.deletingLastPathComponent()))
    }
}
