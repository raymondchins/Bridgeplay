import AppKit
import BridgeplayInstallerCore
import CoreServices
import Foundation

// `BridgeplayApp --background-check`, started by launchd at login once the user turns on
// Settings › Check Steam in the Background (BackgroundItem). It sleeps until something
// happens: Steam.app changes (FSEvents), Steam or the Bridgeplay app quits, or this app is
// updated. Then it decides with BackgroundCheck and either posts a notification or runs
// `--install-into-steam`, which takes the install lock and refuses a running Steam itself.
enum BackgroundAgent {
    static let flag = InstallerService.backgroundCheckFlag
    // launchd's KeepAlive starts it again after this, with the updated executable.
    static let restartStatus: Int32 = 75
    // Unattended: a Steam the user opens meanwhile is left running.
    static let installArguments = [InstallIntoSteamCommand.flag, InstallIntoSteamCommand.unattendedFlag]

    static func run() -> Never {
        MainActor.assumeIsolated { Loop.shared.start() }
        RunLoop.main.run()
        exit(AppLog.finished(0))
    }

    @MainActor
    final class Loop {
        static let shared = Loop()

        // Give the login and an auto-starting Steam time to settle before the first look.
        private let firstLook: TimeInterval = 60
        // When Steam.app or a quit says look again: past Steam's own settle quiet.
        private let afterEvent: TimeInterval = SteamPatchKeeper.settleQuiet
        // A safety net only while a re-apply waits for Steam to quit, in case a quit was missed.
        private let lateLook: TimeInterval = 30 * 60

        private var stream: FSEventStreamRef?
        private var watchedSteam: String?
        private var pending: DispatchWorkItem?
        private var late: DispatchWorkItem?
        private var exits: [pid_t: any DispatchSourceProcess] = [:]
        private var trying = false
        // Held while the install runs, so the installer doesn't replace Bridgeplay under it.
        private var inUse: AppInUseLock?
        private var lastSkip: BackgroundCheck.Skip?
        private let ownBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        private let defaults = UserDefaults.standard

        func start() {
            AppLog.note("background check: started, mode \(BackgroundCheck.mode(defaults).rawValue)")
            watchFiles()
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    if id == "com.valvesoftware.steam" || id == Bundle.main.bundleIdentifier {
                        Loop.shared.look(after: Loop.shared.afterEvent)
                    }
                }
            }
            look(after: firstLook)
        }

        func look(after seconds: TimeInterval) {
            pending?.cancel()
            let item = DispatchWorkItem { MainActor.assumeIsolated { Loop.shared.evaluate() } }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        private func evaluate() {
            guard !trying else { return }
            let mode = BackgroundCheck.mode(defaults)
            if mode == .off {
                AppLog.note("background check: turned off, leaving")
                exit(AppLog.finished(0))
            }
            if MigrationLaunch.shared.pending { return note(.installBlocked, "the 3.0 folder move is pending") }
            let app = SupportPaths.Steam.app
            if app.path(percentEncoded: false) != watchedSteam { watchFiles() }
            // Steam's updater is still writing: wait for the bundle to be quiet.
            if let changed = SteamPatchKeeper.lastChange(in: app),
               Date().timeIntervalSince(changed) < SteamPatchKeeper.settleQuiet {
                return look(after: afterEvent)
            }

            let version = AppVersion.bundled
            let seen = SteamPatchKeeper.capture(bundledVersion: version)
            let steamBuild = SteamHealthStore.installedSteamBuild(
                package: app.appending(path: "Contents/MacOS/package"))
            let deployed = SteamBundle.deployedVersion(at: SupportPaths.deployedVersion)
            var failed = defaults.bool(forKey: BackgroundCheck.lastTryFailedKey)
            if failed, !SteamPatchKeeper.failureStands(seen.deployment, lastAttemptFailed: true,
                                                       sealIsIntact: { SteamInstaller.sealIsIntact(app) }),
               case .installed = seen.deployment {
                failed = false
            }
            let inputs = BackgroundCheck.Inputs(
                mode: mode, deployment: seen.deployment, previouslyDeployed: seen.previouslyDeployed,
                steamRunning: seen.steamRunning, gameRunning: seen.gameRunning,
                appOpen: !appInstances().isEmpty,
                keeperPaused: defaults.bool(forKey: SteamPatchKeeper.pausedKey),
                installBlocked: DeploymentContent.current(version: version).blocksInstallation,
                health: SteamHealthStore.read(installedPatch: SteamHealthStore.patchBuild(deployed: deployed),
                                              installedSteam: steamBuild),
                steamBuild: steamBuild, bundledVersion: version,
                told: defaults.string(forKey: BackgroundCheck.toldKey),
                lastTry: defaults.object(forKey: BackgroundCheck.lastTryKey) as? Date,
                lastTryFailed: failed)
            let action = BackgroundCheck.decide(inputs)

            switch action {
            case .skip(.nothingToDo):
                // Steam carries Bridgeplay again: the next update is news again.
                for key in [BackgroundCheck.toldKey, BackgroundCheck.lastTryFailedKey] { defaults.removeObject(forKey: key) }
                note(.nothingToDo)
            case .skip(let why):
                note(why)
            case .notify(let notice):
                AppLog.note("background check: telling the user, \(notice.repair ? "repair" : "\(notice.kind)"), \(notice.blocker.map { "\($0)" } ?? "notify only")")
                post(notice.title, notice.body)
                defaults.set(notice.key, forKey: BackgroundCheck.toldKey)
                lastSkip = nil
            case .reapply(let kind):
                reapply(kind)
            }
            if BackgroundCheck.waitsForQuit(action, inputs: inputs) { waitForQuit() } else { late?.cancel() }
        }

        private func note(_ skip: BackgroundCheck.Skip, _ detail: String? = nil) {
            guard skip != lastSkip else { return }
            lastSkip = skip
            AppLog.note("background check: nothing to do, \(skip)\(detail.map { " (\($0))" } ?? "")")
        }

        // MARK: Re-applying

        private func reapply(_ kind: SteamPatchKeeper.Kind) {
            guard let executable = Bundle.main.executableURL else { return }
            switch AppInUseLock.take(appBundle: Bundle.main.bundleURL) {
            case .held(let lock): inUse = lock
            case .updating:
                // The new build's check restarts this one when the update lands.
                AppLog.note("background check: Bridgeplay is being updated, not re-applying now")
                return look(after: afterEvent)
            case .unavailable:
                AppLog.note("background check: could not open the update lock beside Bridgeplay, re-applying anyway")
            }
            trying = true
            lastSkip = nil
            defaults.set(Date(), forKey: BackgroundCheck.lastTryKey)
            AppLog.note("background check: re-applying on its own, \(kind)")
            let process = Process()
            process.executableURL = executable
            process.arguments = BackgroundAgent.installArguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { done in
                let status = done.terminationStatus
                DispatchQueue.main.async { MainActor.assumeIsolated { Loop.shared.finished(kind, status: status) } }
            }
            do {
                try process.run()
            } catch {
                AppLog.note("background check: could not start the install: \(error.localizedDescription)")
                finished(kind, status: 1)
            }
        }

        private func finished(_ kind: SteamPatchKeeper.Kind, status: Int32) {
            trying = false
            inUse?.release()
            inUse = nil
            let steamRunning = SteamBundle.isRunning
            let failed = BackgroundCheck.tryFailed(exitStatus: status, steamRunningAfter: steamRunning)
            defaults.set(failed, forKey: BackgroundCheck.lastTryFailedKey)
            AppLog.note("background check: install exited \(status)\(failed ? ", failed" : "")")
            if status == 0 {
                let body = switch kind {
                case .removedBySteam: String(localized: "Steam's update had removed it. Windows games start again.")
                case .outdated: String(localized: "Steam now has this version's files.")
                }
                post(String(localized: "Bridgeplay is back in Steam"), body)
            } else if !failed {
                // Steam opened during the try: the next quit tries again.
                defaults.removeObject(forKey: BackgroundCheck.lastTryKey)
                waitForQuit()
                return
            }
            look(after: afterEvent)
        }

        // MARK: Events

        private func watchFiles() {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            let steam = SupportPaths.Steam.app.path(percentEncoded: false)
            watchedSteam = steam
            let paths = [steam, Bundle.main.bundleURL.appending(path: "Contents/Info.plist").path(percentEncoded: false)]
            let callback: FSEventStreamCallback = { _, _, count, rawPaths, _, _ in
                let list = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
                let touched = Array(list.prefix(count))
                MainActor.assumeIsolated { Loop.shared.filesChanged(touched) }
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
                               | kFSEventStreamCreateFlagFileEvents)
            guard let created = FSEventStreamCreate(
                nil, callback, nil, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5, FSEventStreamCreateFlags(flags))
            else {
                AppLog.note("background check: could not watch \(steam)")
                return
            }
            FSEventStreamSetDispatchQueue(created, .main)
            FSEventStreamStart(created)
            stream = created
        }

        private func filesChanged(_ paths: [String]) {
            let ownPlist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist").path(percentEncoded: false)
            if paths.contains(ownPlist) {
                let onDisk = NSDictionary(contentsOfFile: ownPlist)?["CFBundleVersion"] as? String
                if let onDisk, onDisk != ownBuild {
                    AppLog.note("background check: Bridgeplay updated to build \(onDisk), restarting")
                    exit(AppLog.finished(BackgroundAgent.restartStatus))
                }
            }
            if paths.contains(where: { $0 != ownPlist }) { look(after: afterEvent) }
        }

        // Steam under any macOS account, and this user's Bridgeplay app.
        private func waitForQuit() {
            let steam = (try? Shell.run("/usr/bin/pgrep", ["-x", "steam_osx"]))?.stdout ?? ""
            let pids = steam.split(whereSeparator: \.isNewline).compactMap { pid_t($0) } + appInstances()
            for pid in pids where exits[pid] == nil {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        Loop.shared.exits.removeValue(forKey: pid)?.cancel()
                        Loop.shared.look(after: Loop.shared.afterEvent)
                    }
                }
                exits[pid] = source
                source.resume()
            }
            late?.cancel()
            let item = DispatchWorkItem { MainActor.assumeIsolated { Loop.shared.evaluate() } }
            late = item
            DispatchQueue.main.asyncAfter(deadline: .now() + lateLook, execute: item)
        }

        private func appInstances() -> [pid_t] {
            let id = Bundle.main.bundleIdentifier ?? "com.bridgeplay.Bridgeplay"
            return NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .map(\.processIdentifier).filter { $0 != getpid() }
        }

        // The same path the run script and the breaker use, so it carries Bridgeplay's name.
        private func post(_ title: String, _ body: String) {
            let open = Process()
            open.executableURL = URL(filePath: "/usr/bin/open")
            open.arguments = ["-n", "-g", "-a", Bundle.main.bundleURL.path(percentEncoded: false),
                              "--args", NotifyCommand.flag, title, body]
            open.standardOutput = FileHandle.nullDevice
            open.standardError = FileHandle.nullDevice
            do { try open.run() } catch { AppLog.note("background check: could not post: \(error.localizedDescription)") }
        }
    }
}
