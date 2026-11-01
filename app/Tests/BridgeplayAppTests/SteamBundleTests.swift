import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Steam bundle")
struct SteamBundleTests {

    @Test("A foreign insert names the tool when known, else its file, and ignores ours")
    func foreignToolNames() {
        let ours = "/Applications/Steam.app/Contents/MacOS/notproton.dylib"
        let cartouche = "/Applications/Steam.app/Contents/MacOS/cartouche.dylib"
        #expect(SteamBundle.foreignTool(in: cartouche, deployed: ours) == "Cartouche")
        #expect(SteamBundle.foreignTool(in: "\(ours):\(cartouche)", deployed: ours) == "Cartouche")
        #expect(SteamBundle.foreignTool(in: "/opt/other/hook.dylib", deployed: ours) == "hook.dylib")
        #expect(SteamBundle.foreignTool(in: ours, deployed: ours) == nil)
        #expect(SteamBundle.foreignTool(in: "\(ours):/x/other.dylib", deployed: ours) == "other.dylib")
        #expect(SteamBundle.foreignTool(in: ":\(ours)", deployed: ours) == nil)
        #expect(SteamBundle.foreignTool(in: "\(ours):", deployed: ours) == nil)
    }

    // The bug this guards was live: the sweep covered only the bundle being replaced, and the
    // helpers do not run from there, so an ipcserver survived a stop that reported success.
    @Test("The process sweep covers the helpers as well as the bundle being modified")
    func sweepCoversHelpers() {
        let patterns = SteamBundle.sweepPatterns(
            app: SupportPaths.Steam.app, helpers: [SupportPaths.Steam.innerApp]
        )

        #expect(patterns.count == 2)
        #expect(patterns.contains(#"/Applications/Steam\.app/"#))
        #expect(
            patterns.contains { $0.hasSuffix(#"/Steam\.AppBundle/Steam/"#) },
            "the inner bundle, where ipcserver and the helpers actually run, is not swept"
        )
    }

    // Without it, the pattern matches any process whose command line merely mentions the
    // path, including this test runner.
    @Test("Every pattern is directory-scoped")
    func patternsAreDirectoryScoped() {
        let patterns = SteamBundle.sweepPatterns(
            app: URL(filePath: "/tmp/Some.app"), helpers: [URL(filePath: "/tmp/Inner")]
        )

        #expect(patterns.allSatisfy { $0.hasSuffix("/") })
        #expect(patterns == [#"/tmp/Some\.app/"#, "/tmp/Inner/"])
    }

    @Test("Sweeping nothing is possible, so a test can stop short of killing helpers")
    func helpersCanBeEmpty() {
        let patterns = SteamBundle.sweepPatterns(app: URL(filePath: "/tmp/A.app"), helpers: [])
        #expect(patterns == [#"/tmp/A\.app/"#])
    }

    @Test("pkill gets the path with regular expression characters escaped")
    func patternsAreEscaped() {
        let patterns = SteamBundle.sweepPatterns(app: URL(filePath: "/Volumes/Games (SSD)+/Steam.app"), helpers: [])
        #expect(patterns == [#"/Volumes/Games \(SSD\)\+/Steam\.app/"#])
    }

    // MARK: Stopping Steam

    // A stand-in Steam: running here and in another account, which request it quits on,
    // and whether it is stuck after logging its shutdown.
    private final class FakeSteam: @unchecked Sendable {
        enum Request: Comparable { case exitURL, quit, kill, never }

        private let lock = NSLock()
        private var here: Bool
        private var elsewhere: Bool
        private let quitsOn: Request
        private let stuck: Bool
        private(set) var requests: [Request] = []
        private(set) var swept: [String] = []
        private(set) var hereChecks = 0

        init(here: Bool, elsewhere: Bool = false, quitsOn: Request = .exitURL, stuck: Bool = false) {
            self.here = here
            self.elsewhere = elsewhere
            self.quitsOn = quitsOn
            self.stuck = stuck
        }

        private func receive(_ request: Request) {
            lock.withLock {
                requests.append(request)
                if request >= quitsOn { here = false }
            }
        }

        var client: SteamBundle.Client {
            SteamBundle.Client(
                runningAnywhere: { self.lock.withLock { self.here || self.elsewhere } },
                runningHere: { self.lock.withLock { self.hereChecks += 1; return self.here } },
                askToQuit: { self.receive(.exitURL) },
                requestQuit: { self.receive(.quit) },
                stuckExiting: { _ in self.stuck },
                kill: { self.receive(.kill) },
                sweep: { pattern in self.lock.withLock { self.swept.append(pattern) } },
                pause: {},
                attempts: 3,
                escalationAttempts: 2)
        }
    }

    private func stop(_ steam: FakeSteam) throws -> Bool {
        try SteamBundle.stopClient(
            app: URL(filePath: "/tmp/Steam.app"), helpers: [], step: "Test", client: steam.client)
    }

    @Test("Each look for Steam starts a process, so it stops as soon as Steam has quit")
    func stopsLookingOnceQuit() throws {
        let steam = FakeSteam(here: true)
        #expect(try stop(steam))
        #expect(steam.hereChecks == 2)
    }

    @Test("A closed Steam is left alone")
    func closedSteamIsLeftAlone() throws {
        let steam = FakeSteam(here: false)
        #expect(try stop(steam) == false)
        #expect(steam.requests.isEmpty)
        #expect(steam.swept.isEmpty)
    }

    @Test("Steam that quits when asked is reported stopped, and its helpers are swept")
    func steamThatQuitsIsStopped() throws {
        let steam = FakeSteam(here: true)
        #expect(try stop(steam))
        #expect(steam.requests == [.exitURL])
        #expect(steam.swept == [#"/tmp/Steam\.app/"#])
    }

    // Issue #158: Steam on its login or update screen ignored steam://exit.
    @Test("Steam that ignores steam://exit gets a macOS quit")
    func steamThatIgnoresTheURLIsAskedByMacOS() throws {
        let steam = FakeSteam(here: true, quitsOn: .quit)
        #expect(try stop(steam))
        #expect(steam.requests == [.exitURL, .quit])
        #expect(steam.swept == [#"/tmp/Steam\.app/"#])
    }

    // It used to be killed with SIGKILL after 30 seconds, mid-write or mid-update. There is
    // no kill in Client to reach for.
    @Test("Steam that does not quit is reported with what to do, never swept")
    func steamThatStaysIsReported() {
        let steam = FakeSteam(here: true, quitsOn: .never)
        let failure = #expect(throws: StepFailure.self) { try stop(steam) }
        #expect(failure?.detail.contains("did not quit") == true)
        #expect(failure?.detail.contains("Activity Monitor") == true)
        #expect(steam.requests == [.exitURL, .quit])
        #expect(steam.swept.isEmpty)
    }

    @Test("Steam stuck after logging its shutdown is killed, then swept")
    func stuckSteamIsKilled() throws {
        let steam = FakeSteam(here: true, quitsOn: .kill, stuck: true)
        #expect(try stop(steam))
        #expect(steam.requests == [.exitURL, .quit, .kill])
        #expect(steam.swept == [#"/tmp/Steam\.app/"#])
    }

    @Test("Steam that has not logged its shutdown is never killed")
    func runningSteamIsNotKilled() {
        let steam = FakeSteam(here: true, quitsOn: .never, stuck: false)
        #expect(throws: StepFailure.self) { try stop(steam) }
        #expect(!steam.requests.contains(.kill))
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private static func at(_ text: String) -> Date {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = utc
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.date(from: text)!
    }

    @Test("A shutdown logged after the request counts; an earlier one or none does not")
    func shutdownInTheLog() {
        let log = """
            [2026-10-22 20:24:56] Nothing to do
            [2026-10-22 20:37:09] Shutdown
            """
        let asked = Self.at("2026-10-22 20:37:05")
        #expect(SteamBundle.loggedShutdown(in: log, since: asked, timeZone: Self.utc))
        #expect(SteamBundle.loggedShutdown(in: log + "\r\n", since: asked, timeZone: Self.utc))
        #expect(!SteamBundle.loggedShutdown(in: log, since: Self.at("2026-10-22 20:40:00"), timeZone: Self.utc))
        #expect(!SteamBundle.loggedShutdown(in: "[2026-10-22 20:37:09] Startup", since: asked, timeZone: Self.utc))
        // Only the latest shutdown counts: an old one above a newer start is not this quit.
        let restarted = """
            [2026-10-22 20:30:00] Shutdown
            [2026-10-22 20:31:00] Startup
            """
        #expect(!SteamBundle.loggedShutdown(in: restarted, since: asked, timeZone: Self.utc))
        #expect(!SteamBundle.loggedShutdown(since: asked, log: URL(filePath: "/nonexistent/bootstrap_log.txt")))
    }

    // steam://exit only reaches this account's Steam; another account's keeps the bundle open.
    @Test("Steam open in another account stops the change without asking this one")
    func otherAccountsSteamIsReported() {
        let steam = FakeSteam(here: false, elsewhere: true)
        let failure = #expect(throws: SteamBundle.OpenInAnotherAccount.self) { try stop(steam) }
        #expect(failure?.localizedDescription.contains("another account") == true)
        #expect(steam.requests.isEmpty)
    }

    @Test("Steam open in two accounts is reported once this one has quit")
    func bothAccountsSteamIsReported() {
        let steam = FakeSteam(here: true, elsewhere: true)
        #expect(throws: SteamBundle.OpenInAnotherAccount.self) { try stop(steam) }
        #expect(steam.requests == [.exitURL])
        #expect(steam.swept.isEmpty)
    }

    @Test("Steam open in another account is reported even after this one needed a macOS quit")
    func otherAccountAfterEscalation() {
        let steam = FakeSteam(here: true, elsewhere: true, quitsOn: .quit)
        #expect(throws: SteamBundle.OpenInAnotherAccount.self) { try stop(steam) }
        #expect(steam.requests == [.exitURL, .quit])
        #expect(steam.swept.isEmpty)
    }

    private enum Insert {
        case absent
        case own
        case ownWithoutControllerBlock
        case other(String)
    }

    private func deployment(
        insert: Insert, dylib: Bool, version: String?, steam: Bool = true
    ) throws -> SteamDeployment {
        let root = URL.temporaryDirectory.appending(path: "np-deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Steam.app")
        let versionFile = root.appending(path: "dylib.version")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let version { try Data("\(version)\n".utf8).write(to: versionFile) }
        if steam { try stubBundle(app, insert: insert, dylib: dylib) }
        return SteamBundle.deployment(bundledVersion: "0.2.0", app: app, versionFile: versionFile)
    }

    private func stubBundle(_ app: URL, insert: Insert, dylib: Bool) throws {
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        var plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam"]
        switch insert {
        case .absent:
            break
        case .own:
            let own = SupportPaths.Steam.deployedDylib(inBundle: app)
            plist[SteamBundle.environmentKey] = [
                SteamBundle.insertKey: own.path(percentEncoded: false),
                SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue,
            ]
        case .ownWithoutControllerBlock:
            let own = SupportPaths.Steam.deployedDylib(inBundle: app)
            plist[SteamBundle.environmentKey] = [
                SteamBundle.insertKey: own.path(percentEncoded: false)
            ]
        case .other(let value):
            plist[SteamBundle.environmentKey] = [SteamBundle.insertKey: value]
        }
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))

        if dylib {
            try Data("stand-in\n".utf8).write(to: macOS.appending(path: SupportPaths.dylibName))
        }
    }

    @Test("A bundle patched for this account with a matching version reads as installed")
    func installedForThisAccount() throws {
        #expect(try deployment(insert: .own, dylib: true, version: "0.2.0") == .installed(version: "0.2.0"))
    }

    @Test("A bundle patched by another account reports no version rather than a clean install")
    func patchedByAnotherAccount() throws {
        #expect(try deployment(insert: .own, dylib: true, version: nil) == .installed(version: nil))
    }

    @Test("A plist naming a dylib that is not there reads as not installed")
    func namedDylibMissing() throws {
        #expect(try deployment(insert: .own, dylib: false, version: "0.2.0") == .notInstalled)
    }

    @Test("An older recorded version reads as outdated")
    func outdatedVersion() throws {
        #expect(
            try deployment(insert: .own, dylib: true, version: "0.1.0")
                == .outdated(deployed: "0.1.0", bundled: "0.2.0")
        )
    }

    @Test("A bundle patched before the controller block reads as outdated")
    func missingControllerBlock() throws {
        #expect(
            try deployment(insert: .ownWithoutControllerBlock, dylib: true, version: "0.2.0")
                == .outdated(deployed: "0.2.0", bundled: "0.2.0")
        )
    }

    @Test("Somebody else's insert is left alone")
    func foreignInsert() throws {
        #expect(
            try deployment(insert: .other("/opt/other/thing.dylib"), dylib: true, version: nil)
                == .foreign(insert: "/opt/other/thing.dylib")
        )
    }

    @Test("An unpatched bundle reads as not installed")
    func unpatched() throws {
        #expect(try deployment(insert: .absent, dylib: false, version: nil) == .notInstalled)
    }

    @Test("A missing bundle reads as Steam missing")
    func steamMissing() throws {
        #expect(
            try deployment(insert: .absent, dylib: false, version: "0.2.0", steam: false) == .steamMissing
        )
    }
}
