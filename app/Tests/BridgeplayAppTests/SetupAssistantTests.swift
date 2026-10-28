import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Setup Assistant")
struct SetupAssistantTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Steam counts as signed in once loginusers.vdf names an account")
    func signIn() throws {
        let dir = try folder()
        let file = dir.appending(path: "loginusers.vdf")
        #expect(!SetupChecks.steamSignedIn(loginUsers: file))
        try "\"users\"\n{\n}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!SetupChecks.steamSignedIn(loginUsers: file))
        try "\"users\"\n{\n\t\"7656\"\n\t{\n\t\t\"AccountName\"\t\t\"player\"\n\t}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SetupChecks.steamSignedIn(loginUsers: file))
    }

    @Test("The newest Game Porting Toolkit image in Downloads comes first, other files are ignored")
    func candidates() throws {
        let dir = try folder()
        for name in ["Game_Porting_Toolkit_4.0_beta_1.dmg", "Game_Porting_Toolkit_4.0_beta_2.dmg",
                     "Game_Porting_Toolkit_3.0.dmg", "Game_Porting_Toolkit_notes.pdf", "steam.dmg"] {
            FileManager.default.createFile(atPath: dir.appending(path: name).path(percentEncoded: false), contents: Data())
        }
        #expect(GPTKImport.candidates(in: dir).map(\.lastPathComponent) == [
            "Game_Porting_Toolkit_4.0_beta_2.dmg", "Game_Porting_Toolkit_4.0_beta_1.dmg", "Game_Porting_Toolkit_3.0.dmg",
        ])
    }

    @Test("The evaluation environment image inside Apple's outer image is found")
    func innerImage() throws {
        let dir = try folder()
        let inner = "Evaluation environment for Windows games 4.0 beta 2.dmg"
        for name in [inner, "Metal Shader Converter 4.0 beta 2.pkg", "Read Me.webloc"] {
            FileManager.default.createFile(atPath: dir.appending(path: name).path(percentEncoded: false), contents: Data())
        }
        #expect(GPTKImport.innerImage(in: dir)?.lastPathComponent == inner)
    }

    // Mounts Apple's real image, like FreeEngineWinecxTests.unpacksRealArchive, when
    // NOTPROTON_GPTK_DMG points at Game_Porting_Toolkit_<version>.dmg.
    @Test("Apple's Game Porting Toolkit image imports into a folder D3DMetal linking accepts",
          .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_GPTK_DMG"] != nil))
    func importsRealImage() throws {
        let image = URL(filePath: try #require(ProcessInfo.processInfo.environment["NOTPROTON_GPTK_DMG"]))
        let destination = try folder().appending(path: "gptk", directoryHint: .isDirectory)
        let payload = try GPTKImport.importImage(image, into: destination)
        #expect(payload.libRoot.standardizedFileURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "external/D3DMetal.framework").path(percentEncoded: false)))
        #expect(payload.version != nil)
    }

    @Test("Rosetta counts as installed only when its runtime exists")
    func rosetta() throws {
        let dir = try folder()
        let runtime = dir.appending(path: "libRosettaRuntime")
        #expect(!SetupChecks.rosettaInstalled(runtime: runtime))
        FileManager.default.createFile(atPath: runtime.path(percentEncoded: false), contents: Data())
        #expect(SetupChecks.rosettaInstalled(runtime: runtime))
    }

    @Test("The assistant stays away once the user finished or dismissed it")
    @MainActor
    func finishedFlag() throws {
        let defaults = try #require(UserDefaults(suiteName: "setup-\(UUID().uuidString)"))
        defaults.set(true, forKey: SetupAssistant.finishedKey)
        #expect(!SetupAssistant.shouldShow(nil, defaults: defaults))
    }

    // MARK: Repair Steam

    @MainActor
    private func steamState(_ model: SetupAssistant) -> SetupAssistant.TaskState? {
        model.tasks.first { $0.id == "steam" }?.state
    }

    @Test("A repair that fails for another reason clears the App Management card and shows its error")
    @MainActor
    func repairFailureClearsCards() async {
        let model = SetupAssistant()
        model.needsAppManagement = true
        model.needsSteamRepair = "Cartouche"
        await model.repairSteamAndRetry(with: SystemStatus()) { $0.setFailure("Steam did not quit.") }
        #expect(!model.needsAppManagement)
        #expect(model.needsSteamRepair == nil)
        #expect(!model.repairPending)
        #expect(!model.isWorking)
        #expect(steamState(model) == .failed("Steam did not quit."))
    }

    @Test("A repair stopped by App Management waits to resume; other failures don't")
    @MainActor
    func repairPendingOnlyForAppManagement() {
        let waiting = SetupAssistant()
        #expect(waiting.repairFailed("Could not write files.", remedy: .appManagement))
        #expect(waiting.needsAppManagement)
        #expect(waiting.repairPending)
        #expect(steamState(waiting) == .failed("macOS needs your permission first."))

        let failed = SetupAssistant()
        #expect(!failed.repairFailed("Could not download Steam.", remedy: nil))
        #expect(!failed.needsAppManagement)
        #expect(!failed.repairPending)
        #expect(steamState(failed) == .failed("Could not download Steam."))
    }

    @Test("Repair Steam says so when another run is in flight, and runs nothing")
    @MainActor
    func repairRefusedWhileBusy() async {
        let model = SetupAssistant()
        model.needsSteamRepair = "Cartouche"
        let status = SystemStatus()
        status.activity = "Installing"
        var ran = false
        await model.repairSteamAndRetry(with: status) { _ in ran = true }
        #expect(!ran)
        #expect(model.needsSteamRepair == "Cartouche")
        #expect(steamState(model) == .failed("Bridgeplay is still busy with another task. Try again when it finishes."))
    }

    @Test("A repair waiting for App Management keeps waiting while Bridgeplay is busy, then resumes")
    @MainActor
    func repairResumesAfterBusy() async {
        let model = SetupAssistant()
        #expect(model.repairFailed("Could not write files.", remedy: .appManagement))
        let status = SystemStatus()
        status.activity = "Installing"
        var ran = false
        let repair: @MainActor (SystemStatus) async -> Void = { ran = true; $0.setFailure("Steam did not quit.") }

        #expect(!(await model.resumeAfterPermission(status, canWrite: true, repair: repair)))
        #expect(!ran)
        #expect(model.needsAppManagement)
        #expect(model.repairPending)
        #expect(steamState(model) == .failed("macOS needs your permission first."))

        status.activity = nil
        #expect(await model.resumeAfterPermission(status, canWrite: true, repair: repair))
        #expect(ran)
        #expect(!model.needsAppManagement)
        #expect(steamState(model) == .failed("Steam did not quit."))
    }

    // MARK: Making WineCX Steam's default

    // Steam in this account, another account, or both. quits: whether it obeys steam://exit.
    private final class FakeSteam: @unchecked Sendable {
        private let lock = NSLock()
        private var here: Bool
        private let elsewhere: Bool
        private let quits: Bool
        private var asked = false

        init(here: Bool, elsewhere: Bool = false, quits: Bool = true) {
            self.here = here
            self.elsewhere = elsewhere
            self.quits = quits
        }

        var runningHere: Bool { lock.withLock { here } }
        var askedToQuit: Bool { lock.withLock { asked } }

        var client: SteamBundle.Client {
            SteamBundle.Client(
                runningAnywhere: { self.lock.withLock { self.here || self.elsewhere } },
                runningHere: { self.runningHere },
                askToQuit: { self.lock.withLock { self.asked = true; if self.quits { self.here = false } } },
                requestQuit: {},
                stuckExiting: { _ in false },
                kill: {},
                sweep: { _ in },
                pause: {},
                attempts: 2,
                escalationAttempts: 1)
        }
    }

    private static let config = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t}
        \t\t}
        \t}
        }
        """

    private static let tool = "bridgeplay-proton-winecx-11.17"

    // Runs the setup step against a temporary config.vdf; returns its text afterwards.
    private func makeDefault(_ steam: FakeSteam, config: String? = config, runningBuild: String? = nil) throws -> String {
        let dir = try folder()
        let file = dir.appending(path: "config.vdf")
        try config?.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try SetupAssistant.makeDefault(
                Self.tool,
                needsChange: { try SteamDefaultTool.needsChange(to: $0, in: file) },
                steamOpen: { steam.runningHere },
                runningBuild: { runningBuild },
                stop: { try SteamBundle.stopClient(app: URL(filePath: "/tmp/Steam.app"), helpers: [], step: "Test", client: steam.client) },
                write: { try SteamDefaultTool.set($0, in: file, backup: dir.appending(path: "backup.json"),
                                                  steamRunning: { steam.runningHere }) })
        } catch {
            #expect((try? String(contentsOf: file, encoding: .utf8)) == config)
            throw error
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("Setup quits this account's Steam, then writes the default")
    func quitsSteamThenWritesDefault() throws {
        let steam = FakeSteam(here: true)
        let result = try makeDefault(steam)
        #expect(steam.askedToQuit)
        #expect(SteamDefaultTool.current(in: result)?.name == Self.tool)
    }

    @Test("With Steam closed, nothing is asked to quit and the default is written")
    func closedSteamIsLeftAlone() throws {
        let steam = FakeSteam(here: false)
        let result = try makeDefault(steam)
        #expect(!steam.askedToQuit)
        #expect(SteamDefaultTool.current(in: result)?.name == Self.tool)
    }

    @Test("Steam open only in another account is left open, and this account's default is written")
    func steamInAnotherAccount() throws {
        let steam = FakeSteam(here: false, elsewhere: true)
        let result = try makeDefault(steam)
        #expect(!steam.askedToQuit)
        #expect(SteamDefaultTool.current(in: result)?.name == Self.tool)
    }

    @Test("Steam open in both accounts: this account's is quit and its default is written")
    func steamInBothAccounts() throws {
        let steam = FakeSteam(here: true, elsewhere: true)
        let result = try makeDefault(steam)
        #expect(steam.askedToQuit)
        #expect(SteamDefaultTool.current(in: result)?.name == Self.tool)
    }

    @Test("Without a config.vdf yet, Steam is still quit, since it may write one as it quits")
    func noConfigYet() throws {
        let steam = FakeSteam(here: true)
        let error = #expect(throws: StepFailure.self) { try makeDefault(steam, config: nil) }
        #expect(error?.detail.contains("no config.vdf") == true)
        #expect(steam.askedToQuit)
    }

    @Test("A config.vdf without a Steam section fails without quitting Steam")
    func brokenConfig() throws {
        let steam = FakeSteam(here: true)
        let error = #expect(throws: StepFailure.self) { try makeDefault(steam, config: "\"InstallConfigStore\"\n{\n}\n") }
        #expect(error?.detail.contains("no InstallConfigStore") == true)
        #expect(!steam.askedToQuit)
    }

    @Test("With Steam closed, a running Wine tool does not stop the default being written")
    func wineToolWithSteamClosed() throws {
        let steam = FakeSteam(here: false)
        let result = try makeDefault(steam, runningBuild: "winecx-11.17")
        #expect(SteamDefaultTool.current(in: result)?.name == Self.tool)
    }

    @Test("Steam is left open when WineCX is already its default")
    func alreadyDefault() throws {
        let steam = FakeSteam(here: true)
        let config = try #require(SteamDefaultTool.updated(Self.config, tool: Self.tool))
        #expect(try makeDefault(steam, config: config) == config)
        #expect(!steam.askedToQuit)
    }

    @Test("A running game stops setup before Steam is quit, and nothing is written")
    func runningGame() throws {
        let steam = FakeSteam(here: true)
        let error = #expect(throws: StepFailure.self) { try makeDefault(steam, runningBuild: "winecx-11.17") }
        #expect(error?.detail.contains("winecx-11.17") == true)
        #expect(!steam.askedToQuit)
    }

    @Test("Steam that does not quit stops setup with that reason and writes nothing")
    func steamDoesNotQuit() throws {
        let steam = FakeSteam(here: true, quits: false)
        let error = #expect(throws: StepFailure.self) { try makeDefault(steam) }
        #expect(error?.detail.hasPrefix("Steam did not quit.") == true)
        #expect(steam.runningHere)
    }
}

@Suite("Setup checks")
struct SetupChecksTests {

    @Test("Downloads is not read when a Game Porting Toolkit is already installed")
    func downloadsScanGated() {
        var scans = 0
        let scan: () -> [URL] = { scans += 1; return [URL(filePath: "/Downloads/Game_Porting_Toolkit_3.0.dmg")] }
        #expect(GPTKImport.candidatesIfMissing(installed: true, scan: scan).isEmpty)
        #expect(scans == 0)
        #expect(GPTKImport.candidatesIfMissing(installed: false, scan: scan).count == 1)
        #expect(scans == 1)
    }

    @Test("Rosetta failures read as plain sentences")
    func rosettaMessages() {
        let cancelled = CommandFailure(command: "osascript", status: 1, stderr: "0:120: execution error: User canceled. (-128)")
        #expect(SetupChecks.rosettaFailure(cancelled).contains("password window was closed"))
        let denied = CommandFailure(command: "osascript", status: 1, stderr: "execution error: The administrator user name or password was incorrect. (-60005)")
        #expect(SetupChecks.rosettaFailure(denied).contains("administrator"))
        let other = CommandFailure(command: "osascript", status: 1, stderr: "softwareupdate: network down")
        let message = SetupChecks.rosettaFailure(other)
        #expect(!message.contains("osascript"))
        #expect(message.contains("internet"))
    }

    @Test("The App Management advice explains the switch that looks on after an update")
    func appManagementAdvice() {
        #expect(Remedy.appManagement.advice.contains("App Management"))
        #expect(Remedy.appManagement.advice.contains("off and on again"))
    }
}
