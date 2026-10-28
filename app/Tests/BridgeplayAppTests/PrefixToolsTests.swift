import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Prefix tools")
struct PrefixToolsTests {

    // The launch path is shell and this is Swift, so the rules it carries are read back
    // out of compat_run.sh rather than restated here.
    private static func compatSource() throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()  // BridgeplayAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
    }

    private func samplePrefix() -> WinePrefix {
        WinePrefix(
            appID: "1574480",
            name: "Agent 64: Spies Never Die",
            library: SteamLibrary(root: URL(filePath: "/Users/tester/Library/Application Support/Steam")),
            lastUsed: nil
        )
    }

    @Test("Log paths match where compat_run.sh writes them")
    func logPathsMatchRunScript() throws {
        let source = try Self.compatSource()
        // The app falls back to the pre-3.0 file names, so either spelling of a log is a match.
        func either(_ text: (String) -> String) -> Bool {
            source.contains(text("bridgeplay")) || source.contains(text("notproton"))
        }
        #expect(either { #"log="$STEAM_COMPAT_DATA_PATH/\#($0)-run.log""# })
        #expect(source.contains(#"loader_root="$np_support/launchers/$app_id""#))
        #expect(source.contains(#"np_support="$HOME/Library/Application Support/bridgeplay""#))
        #expect(either { #"wine_log="$loader_root/\#($0)-wine.log""# })

        let prefix = samplePrefix()
        let launchers = URL(filePath: "/tmp/launchers")
        #expect(PrefixLog.launch.url(for: prefix, launchers: launchers) == prefix.root.appending(path: "bridgeplay-run.log"))
        #expect(PrefixLog.wine.url(for: prefix, launchers: launchers).path(percentEncoded: false)
            == "/tmp/launchers/1574480/bridgeplay-wine.log")
        #expect(SupportPaths.launchers.path(percentEncoded: false).hasSuffix("Application Support/bridgeplay/launchers"))
    }

    @Test("A log written before 3.0 is shown until the renamed one exists")
    func logFallsBackToTheOldName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SteamLibrary(root: root)
        let prefix = WinePrefix(appID: "1574480", name: "Agent 64", library: library, lastUsed: nil)
        let launchers = root.appending(path: "launchers")
        try FileManager.default.createDirectory(at: prefix.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchers.appending(path: "1574480"), withIntermediateDirectories: true)

        try Data("old".utf8).write(to: prefix.root.appending(path: "notproton-run.log"))
        try Data("old".utf8).write(to: launchers.appending(path: "1574480/notproton-wine.log"))
        #expect(PrefixLog.launch.url(for: prefix, launchers: launchers).lastPathComponent == "notproton-run.log")
        #expect(PrefixLog.wine.url(for: prefix, launchers: launchers).lastPathComponent == "notproton-wine.log")

        try Data("new".utf8).write(to: prefix.root.appending(path: "bridgeplay-run.log"))
        try Data("new".utf8).write(to: launchers.appending(path: "1574480/bridgeplay-wine.log"))
        #expect(PrefixLog.launch.url(for: prefix, launchers: launchers).lastPathComponent == "bridgeplay-run.log")
        #expect(PrefixLog.wine.url(for: prefix, launchers: launchers).lastPathComponent == "bridgeplay-wine.log")
    }

    @Test("The runner variables are the ones RUN_SCRIPT exports")
    func matchesRunScript() throws {
        // A tool under a stale copy of the runner layout writes registry keys the game side then
        // reads under different rules, and nothing else would notice the drift.
        let source = try Self.compatSource()

        // Written in compat_run.sh as: export WINELOADER="$CX_ROOT/lib/wine/..."
        func exported(_ name: String) throws -> String {
            let pattern = #"export \#(name)="([^"]*)""#
            let regex = try Regex(pattern)
            let match = try #require(
                source.firstMatch(of: regex), "compat_run.sh no longer exports \(name)")
            return String(match[1].substring ?? "")
        }

        let home = try exported("CX_HOME").replacingOccurrences(
            of: "$HOME", with: SupportPaths.home.path(percentEncoded: false))

        // Both sides resolve the loader and wineserver from whichever unix directory the runner
        // has, so the check is that they pick the same pair for the same tree.
        let fm = FileManager.default
        for (arch, loaderTail, serverName) in [
            ("aarch64-unix", "wine.app/Contents/MacOS/wine", "wineserver-arm64"),
            ("x86_64-unix", "wine", "wineserver-x86"),
        ] {
            let runner = URL(filePath: NSTemporaryDirectory())
                .appending(path: "bridgeplay-layout-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: runner) }

            for path in ["lib/wine/\(arch)/\(loaderTail)", "bin/\(serverName)"] {
                let file = runner.appending(path: path)
                try fm.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
                try fm.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
            }

            let layout = PrefixTools.layout(runner: runner)
            #expect(layout.loader == runner.appending(path: "lib/wine/\(arch)/\(loaderTail)"))
            #expect(layout.server == runner.appending(path: "bin/\(serverName)"))

            // The shapes the script reaches for, which is what would drift independently.
            #expect(source.contains("$wine_unix/\(loaderTail)"))
            #expect(source.contains(serverName))

            let environment = PrefixTools.environment(prefix: samplePrefix(), runner: runner)
            let dllPath = try exported("WINEDLLPATH")
                .replacingOccurrences(of: "${WINEDLLPATH:+:$WINEDLLPATH}", with: "")
                .replacingOccurrences(of: "$CX_ROOT", with: runner.path(percentEncoded: false))
                .replacingOccurrences(of: "$wine_unix", with: layout.unixDir.path(percentEncoded: false))

            #expect(environment["WINEDLLPATH"] == dllPath, "WINEDLLPATH drifted from RUN_SCRIPT")
            #expect(environment["WINELOADER"] == layout.loader.path(percentEncoded: false))
            #expect(environment["WINESERVER"] == layout.server.path(percentEncoded: false))
            #expect(environment["CX_HOME"] == home)

            // WINELOADER is what launch and recreate actually invoke, so the two have to
            // agree with each other as well as with the script.
            #expect(environment["WINELOADER"]
                == PrefixTools.loader(runner: runner).path(percentEncoded: false))
        }
    }

    @Test("The prefix and the sync backend are set, and the game only variables are not")
    func setsPrefixAndBackend() {
        let prefix = samplePrefix()
        let runner = SupportPaths.clonedRoot(forBuild: "27.0.0.40921-fex")
        let environment = PrefixTools.environment(prefix: prefix, runner: runner)

        #expect(environment["WINEPREFIX"] == prefix.pfx.path(percentEncoded: false))
        #expect(environment["WINEPREFIX"]?.hasSuffix("/compatdata/1574480/pfx") == true)
        #expect(environment["WINEMSYNC"] == PrefixTools.syncBackend(prefix: prefix))
        // Derived rather than spelled out, because the support directory hangs off the
        // running account's home and a literal here would only ever pass on one machine.
        let runnerBin = runner.appending(path: "bin")
            .path(percentEncoded: false)
        #expect(environment["PATH"]?.hasPrefix(runnerBin + ":") == true)

        // Redirecting steamclient to lsteamclient means something for a game, not for a
        // configuration window, where it would apply game override rules to what it touches.
        #expect(environment["WINEDLLOVERRIDES"] == nil)
    }

    @Test("The sync backend is whatever the last launch recorded")
    func readsRecordedBackend() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "np-msync-\(UUID().uuidString)")
        let library = SteamLibrary(root: root)
        let prefix = WinePrefix(appID: "480", name: nil, library: library, lastUsed: nil)
        try FileManager.default.createDirectory(at: prefix.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PrefixTools.syncBackend(prefix: prefix) == "0")

        let marker = prefix.root.appending(path: "notproton-msync")
        for (recorded, expected) in [("1", "1"), ("0", "0"), ("1\n", "1"), ("", "0"), ("yes", "0")] {
            try recorded.write(to: marker, atomically: true, encoding: .utf8)
            #expect(
                PrefixTools.syncBackend(prefix: prefix) == expected,
                "recorded \(recorded.debugDescription)")
            #expect(PrefixTools.environment(prefix: prefix, runner: root)["WINEMSYNC"] == expected)
        }
    }

    @Test("Every tool is offered under the name the loader resolves")
    func toolNamesAreBare() {
        #expect(WineTool.allCases.map(\.rawValue) == ["winecfg", "regedit", "taskmgr"])
        for tool in WineTool.allCases {
            #expect(!tool.rawValue.contains("/"), "\(tool) would not resolve as a builtin")
            #expect(!tool.rawValue.hasSuffix(".exe"))
            #expect(!tool.label.isEmpty)
        }
    }

    @Test("Without a runner, opening a tool says so instead of failing at exec")
    func refusesWithoutARunner() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-norunner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(throws: StepFailure.self) {
            try PrefixTools.launch(.winecfg, in: samplePrefix(), runner: dir)
        }
        #expect(throws: StepFailure.self) {
            try PrefixTools.recreate(samplePrefix(), runner: dir)
        }
    }

    // An msi is data for msiexec rather than a program, so the loader would start nothing.
    // Refused here rather than inside wine, where the reason goes to a log nobody opens.
    @Test("A picked file is run the way its kind has to be run")
    func windowsProgramsAreInvokedByKind() {
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/Agent 64/game.exe")) == ["/games/Agent 64/game.exe"])
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/setup.EXE")) == ["/games/setup.EXE"])
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/patch.bat")) == ["/games/patch.bat"])
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/patch.cmd")) == ["/games/patch.cmd"])
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/vc.msi")) == ["msiexec", "/i", "/games/vc.msi"])

        #expect(PrefixTools.arguments(for: URL(filePath: "/games/readme.txt")) == nil)
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/game.app")) == nil)
        #expect(PrefixTools.arguments(for: URL(filePath: "/games/game")) == nil)
    }

    @Test("Running a picked program refuses before exec when it cannot work")
    func runRefusesEarly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appending(path: "setup.exe")
        try Data("MZ".utf8).write(to: exe)

        #expect(throws: StepFailure.self) {
            try PrefixTools.run(exe, in: samplePrefix(), runner: dir)
        }
        #expect(throws: StepFailure.self) {
            try PrefixTools.run(dir.appending(path: "gone.exe"), in: samplePrefix())
        }
        #expect(throws: StepFailure.self) {
            try PrefixTools.run(URL(filePath: "/bin/ls"), in: samplePrefix())
        }
    }

    @Test("Winetricks refuses before it runs when it cannot work or would leave the prefix")
    func winetricksRefusesEarly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-winetricks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "winetricks")

        #expect(PrefixTools.winetricksVerbs("  vcrun2022\tcorefonts \n") == ["vcrun2022", "corefonts"])

        func refusal(_ verbs: String) -> String? {
            do {
                _ = try PrefixTools.winetricks(
                    PrefixTools.winetricksVerbs(verbs), in: samplePrefix(), script: script, runner: dir)
                return nil
            } catch {
                return (error as? StepFailure)?.detail
            }
        }
        #expect(refusal(" ")?.contains("at least one verb") == true)
        #expect(refusal("vcrun2022 annihilate")?.contains("annihilate") == true)
        #expect(refusal("prefix=other corefonts")?.contains("prefix=other") == true)
        #expect(refusal("--self-update")?.contains("--self-update") == true)
        #expect(refusal("corefonts")?.contains("No compatibility tool") == true)
        #expect(!FileManager.default.fileExists(
            atPath: samplePrefix().root.appending(path: PrefixTools.winetricksLogName).path(percentEncoded: false)))
    }

    @Test("Winetricks accepts a Visual C++ installer that finds a newer runtime already installed")
    func winetricksAcceptsNewerVisualCpp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-winetricks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir.appending(path: "library"))
        let prefix = WinePrefix(appID: "2075800", name: "Game", library: library, lastUsed: nil)
        let runner = dir.appending(path: "runner")
        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        for folder in [prefix.pfx, unix, dir.appending(path: "cache")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func executable(_ url: URL, _ body: String) throws {
            try Data(body.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }
        // Wine passes on only the low byte of 1638 (ERROR_PRODUCT_VERSION).
        try executable(unix.appending(path: "wine"), "#!/bin/sh\ncase \"$1\" in *.exe) exit 102 ;; esac\nexit 102\n")
        let script = dir.appending(path: "cache/winetricks")
        try executable(script, """
            #!/bin/sh
            "$WINE" vc_redist.x86.exe /q; echo "x86 $?"
            "$WINE" 'C:\\redist\\VC_redist.x64.exe' /q; echo "x64 $?"
            "$WINE" regedit.exe /S x.reg; echo "regedit $?"
            echo "bin $WINE_BIN"
            """)

        let log = try PrefixTools.winetricks(["vcrun2022"], in: prefix, script: script, runner: runner)
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(output.contains("x86 236"))
        #expect(output.contains("x64 236"))
        #expect(output.contains("regedit 102"), "only installers have the code rewritten")
        #expect(output.contains("bin \(unix.appending(path: "wine").path(percentEncoded: false))"))
    }

    // The script is hashed when downloaded but runs later from a cache the user can write to.
    @Test("Winetricks runs only the bytes that match its pin")
    func winetricksRunsOnlyThePinnedScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-winetricks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir.appending(path: "library"))
        let prefix = WinePrefix(appID: "2075800", name: "Game", library: library, lastUsed: nil)
        let runner = dir.appending(path: "runner")
        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        for folder in [prefix.pfx, unix, dir.appending(path: "cache")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unix.appending(path: "wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unix.appending(path: "wine").path(percentEncoded: false))
        let script = dir.appending(path: "cache/winetricks")
        let pinned = Data("#!/bin/sh\necho pinned\n".utf8)
        try pinned.write(to: script)
        let pin = Digest.sha256(of: pinned)

        let log = try PrefixTools.winetricks(["vcrun2022"], in: prefix, script: script, runner: runner, sha256: pin)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("pinned"))
        try FileManager.default.removeItem(at: log)

        try Data("#!/bin/sh\necho swapped\n".utf8).write(to: script)
        let failure = try #require(throws: StepFailure.self) {
            try PrefixTools.winetricks(["vcrun2022"], in: prefix, script: script, runner: runner, sha256: pin)
        }
        #expect(failure.detail.contains("changed after it was checked"))
        #expect(!FileManager.default.fileExists(atPath: log.path(percentEncoded: false)), "the swapped script ran")
        #expect(!FileManager.default.fileExists(atPath: script.path(percentEncoded: false)), "the swapped script stays cached")
    }

    @Test("Every kind offered by the file picker is a kind that can be run")
    func pickerTypesMatchWhatRuns() {
        let extensions = PrefixTools.runnableTypes.compactMap(\.preferredFilenameExtension)
        #expect(!extensions.isEmpty)
        for extension_ in extensions {
            #expect(
                PrefixTools.arguments(for: URL(filePath: "/games/thing.\(extension_)")) != nil,
                "the picker offers \(extension_) but nothing runs it")
        }
    }

    // The same rule is read once in shell and once here, so a word that drifted on one side
    // leaves the pane calling a prefix fine that the launcher will not start, or the reverse.
    @Test("The launcher and the pane read the prefix arch the same way")
    func archRuleMatchesRunScript() throws {
        let source = try Self.compatSource()

        // Written in compat.c as: aarch64-unix) want=aa64 ;;
        func wanted(_ pattern: String) throws -> PrefixArch? {
            let match = try #require(
                source.firstMatch(of: try Regex(pattern)), "compat.c no longer sets \(pattern)")
            let word = try #require(UInt16(String(match[1].substring ?? ""), radix: 16))
            return PrefixArch(machine: word)
        }

        #expect(try wanted(#"aarch64-unix\) want=(\w+)"#) == .arm64)
        #expect(try wanted(#"\*\) want=(\w+)"#) == .x86_64)

        // And both read it out of the same file.
        #expect(source.contains(#"drive_c/windows/system32/ntdll.dll"#))
    }

    // Both names come off the same machine words the arch rule uses, so a wrong word or the
    // two swapped tells the player to keep the build they have and rebuild for the other.
    @Test("The dialog names the build that made the prefix and the one installed now")
    func dialogNamesBothBuilds() throws {
        let source = try Self.compatSource()

        // Written in compat_run.sh as: aa64) printf 'an arm64 (FEX) Wine engine' ;;
        func name(of word: String) throws -> String {
            let match = try #require(
                source.firstMatch(of: try Regex("\(word)\\) printf '([^']+)'")),
                "compat_run.sh no longer names \(word)")
            return String(match[1].substring ?? "")
        }

        // The machine word each loader wants, taken from the rule rather than restated.
        func wanted(_ pattern: String) throws -> String {
            let match = try #require(source.firstMatch(of: try Regex(pattern)))
            return String(match[1].substring ?? "")
        }

        #expect(try name(of: wanted(#"aarch64-unix\) want=(\w+)"#)).contains("FEX"))
        #expect(try name(of: wanted(#"\*\) want=(\w+)"#)).contains("Rosetta"))

        // A prefix that reads as 32 bit is neither build, so it gets no build name.
        let fallback = try #require(source.firstMatch(of: /\*\) printf '([^']+)'/))
        let vague = String(fallback.1)
        #expect(!vague.contains("FEX") && !vague.contains("Rosetta"))

        // What made the prefix is named first and blamed, what is installed second.
        let built = try #require(source.range(of: #"$(tool_name "$have")"#))
        let installed = try #require(source.range(of: #"$(tool_name "$want")"#))
        #expect(built.lowerBound < installed.lowerBound)
    }

    // A newline inside an AppleScript string literal is a syntax error, so osascript writes
    // nothing and the launch still stops, with no dialog ever reaching the screen to say why.
    @Test("The alert reaches osascript as one line")
    func alertIsOneLine() throws {
        let source = try Self.compatSource()
        let opening = try #require(source.range(of: "display alert"))
        let closing = try #require(source.range(of: #"" as critical"#))
        #expect(!source[opening.lowerBound..<closing.lowerBound].contains("\n"))
    }

    // Steam runs the tool twice for one launch and both passes reach the refusal, so an
    // ungated alert shows twice. Only the alert is gated; the evaluator pass still has to stop.
    @Test("Only the pass that launches the game shows the alert")
    func alertSkipsTheEvaluatorPass() throws {
        let source = try Self.compatSource()
        let helper = try #require(source.range(of: "show_alert() {\n"))
        let gate = try #require(source.range(of: #"  [ "$verb" != run ] || return 0"#))
        let alert = try #require(source.range(of: "display alert"))

        #expect(helper.upperBound == gate.lowerBound)
        #expect(gate.upperBound < alert.lowerBound)
        // The first-launch notice uses osascript too, but as a notification, not an alert. The
        // rebuild failure alert, the rebuild prompt and the anti-cheat prompt carry their own gates.
        #expect(source.ranges(of: "display alert").count == 3, "an alert bypasses show_alert")
        #expect(source.ranges(of: "osascript").count == 6)
        let anticheat = try #require(source.range(of: "kernel_anticheat_notice() {\n"))
        #expect(source[anticheat.upperBound...].hasPrefix(#"  [ "$verb" = waitforexitandrun ] || return 0"#))
        let rebuild = try #require(source.range(of: "rebuild_prefix() {"))
        let prompt = try #require(source.range(of: "choice=$(osascript"))
        #expect(source[rebuild.upperBound..<prompt.lowerBound].contains(#"[ "$verb" != run ] || { [ -n "$3" ] && return 0; exit 1; }"#))
        let failure = try #require(source.range(of: "show_rebuild_failure() {\n"))
        #expect(source[failure.upperBound...].hasPrefix(#"  [ "$verb" != run ] || return 0"#))

        let calls = source.ranges(of: "  show_alert \"")
        #expect(!calls.isEmpty)
        for call in calls {
            let rest = source[call.upperBound...]
            let line = try #require(rest.firstIndex(of: "\n"))
            let next = rest[rest.index(after: line)...].prefix { $0 != "\n" }
            #expect(next.trimmingCharacters(in: .whitespaces) == "exit 1")
        }
    }

    @Test("Steam rebuild requests use the exact selected tool and library", arguments: [true, false])
    func steamRebuildRequest(keepBackup: Bool) throws {
        let (dir, _, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = InstalledTool(tool: CompatTool(name: "chosen", flavor: .rosetta, display: "Chosen"), build: "chosen-build")
        let other = InstalledTool(tool: CompatTool(name: "old", flavor: .fex, display: "Old"), build: "old-build")
        let args = [prefix.root.path(percentEncoded: false), selected.name, selected.build,
                    selected.tool.flavor.rawValue, keepBackup ? "keep-backup" : "discard-backup"]
        let request = try RebuildPrefixCommand.request(args, tools: [other, selected])
        #expect(request.prefix.root == prefix.root)
        #expect(request.tool == selected)
        #expect(request.keepBackup == keepBackup)
        for index in 0..<args.count {
            var invalid = args
            invalid[index] = "invalid"
            #expect(throws: StepFailure.self) { try RebuildPrefixCommand.request(invalid, tools: [selected]) }
        }
        #expect(throws: StepFailure.self) { try RebuildPrefixCommand.request([], tools: [selected]) }
        #expect(throws: StepFailure.self) { try RebuildPrefixCommand.request(args + ["extra"], tools: [selected]) }
        #expect(throws: StepFailure.self) { try RebuildPrefixCommand.request(args, tools: []) }
    }

    @Test("A selected-tool rebuild preserves saves and records the selected build", arguments: [true, false])
    func steamRebuildSelectedTool(keepBackup: Bool) throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = InstalledTool(tool: CompatTool(name: "chosen", flavor: .rosetta, display: "Chosen"), build: "chosen-build")
        let runners = dir.appending(path: "runners")
        let target = SupportPaths.clonedRoot(forBuild: tool.build, runners: runners)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: runner, to: target)
        let claim = try #require(PrefixStore.claim(prefix))
        #expect(throws: StepFailure.self) {
            try PrefixTools.recreate(prefix, as: tool, runners: runners, keepBackup: keepBackup)
        }
        #expect(PrefixTools.buildRecord(of: prefix) == nil)
        #expect(PrefixStore.backups(of: prefix).isEmpty)
        claim.release()
        var phases: [RebuildPhase] = []
        let backup = try PrefixTools.recreate(
            prefix, as: tool, runners: runners, keepBackup: keepBackup, progress: { phases.append($0) })
        #expect(phases == [.settingUp, .copying, .finishing])
        #expect((backup != nil) == keepBackup)
        #expect(PrefixStore.backups(of: prefix).count == (keepBackup ? 1 : 0))
        #expect(PrefixTools.buildRecord(of: prefix)?.build == tool.build)
        let save = prefix.pfx.appending(path: "drive_c/users/steamuser/AppData/Roaming/game/save.dat")
        #expect(try String(contentsOf: save, encoding: .utf8) == "save")
    }

    @Test("Rebuild progress lands beside the prefix and nowhere else")
    func rebuildStatusFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "steamapps/compatdata/480")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(RebuildPrefixCommand.statusFile(root.path(percentEncoded: false))
            == root.standardizedFileURL.appending(path: "notproton-rebuild"))
        #expect(RebuildPrefixCommand.statusFile("relative/compatdata/480") == nil)
        #expect(RebuildPrefixCommand.statusFile(dir.path(percentEncoded: false)) == nil)
        #expect(RebuildPrefixCommand.statusFile(root.appending(path: "missing").path(percentEncoded: false)) == nil)
    }

    @Test("A second rebuild of a prefix is refused and leaves the first one's progress alone")
    func secondRebuildIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-second-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "steamapps/compatdata/480")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let status = try #require(RebuildPrefixCommand.statusFile(root.path(percentEncoded: false)))
        try Data("copy\n4242\n".utf8).write(to: status)

        let first = try RebuildPrefixCommand.claimRebuild(beside: status)
        defer { FileLock.release(first) }
        try FileManager.default.createDirectory(at: root.appending(path: "pfx"), withIntermediateDirectories: true)
        let tool = InstalledTool(tool: CompatTool(name: "t", flavor: .rosetta, display: "T"), build: "b")
        #expect(throws: StepFailure.self) {
            try RebuildPrefixCommand.run([root.path(percentEncoded: false), "t", "b", "rosetta", "keep-backup"], tools: { [tool] })
        }
        #expect(try String(contentsOf: status, encoding: .utf8) == "copy\n4242\n")
    }

    @Test("Invalid rebuild requests create no progress or lock files")
    func invalidRebuildWritesNothing() throws {
        let (dir, _, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: StepFailure.self) {
            try RebuildPrefixCommand.run([prefix.root.path, "missing", "b", "fex", "keep-backup"], tools: { [] })
        }
        for name in [RebuildPrefixCommand.statusName, RebuildPrefixCommand.rebuildLockName] {
            #expect(!FileManager.default.fileExists(atPath: prefix.root.appending(path: name).path))
        }
    }

    @Test("A translocated rebuild app is not recorded as a persistent path")
    func translocatedRebuildAppIsNotRecorded() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "AppTranslocation/id/d/Bridgeplay.app/Contents/MacOS/BridgeplayApp")
        let support = dir.appending(path: "support")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: support.appending(path: RebuildPrefixCommand.executableRecord))
        try RebuildPrefixCommand.recordExecutable(source, in: support)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: RebuildPrefixCommand.executableRecord).path))
    }

    @Test("A queued installation lock times out without disturbing its holder")
    func rebuildLockWaitIsBounded() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = try DeploymentContent.acquireInstallationLock(in: dir, steamFolder: nil)
        defer { held.release() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: StepFailure.self) {
            try DeploymentContent.acquireInstallationLock(in: dir, steamFolder: nil, waiting: true, waitTimeout: 0.1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(throws: StepFailure.self) {
            try DeploymentContent.acquireInstallationLock(in: dir, steamFolder: nil)
        }
    }

    @Test("The Rosetta flavor takes the x86_64 tree on a runner that has both")
    func rosettaFlavorTakesX86() throws {
        let fm = FileManager.default
        let runner = fm.temporaryDirectory.appending(path: "np-arch-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: runner) }
        for path in [
            "lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine", "lib/wine/x86_64-unix/wine",
            "bin/wineserver-arm64", "bin/wineserver",
        ] {
            let file = runner.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }

        #expect(PrefixTools.layout(runner: runner, flavor: .fex).unixDir.lastPathComponent == "aarch64-unix")
        #expect(PrefixTools.layout(runner: runner, flavor: .rosetta).unixDir.lastPathComponent == "x86_64-unix")
        #expect(PrefixTools.layout(runner: runner, flavor: .rosetta).server.lastPathComponent == "wineserver")
    }

    // Stands in for wineboot --init, the one part of a rebuild a test cannot run: the windows
    // tree, empty profile stubs, the link out to the real home. lock makes the rename fail.
    private func fakeRunner(
        in dir: URL, home: URL, exit status: Int = 0, lock: Bool = false, extra: String = ":"
    ) throws -> URL {
        let runner = dir.appending(path: "runner")
        let loader = runner.appending(path: "lib/wine/x86_64-unix/wine")
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            #!/bin/sh
            [ "$1" = wineboot ] || exit 64
            mkdir -p "$WINEPREFIX/drive_c/windows/system32" \\
              "$WINEPREFIX/drive_c/Program Files" \\
              "$WINEPREFIX/drive_c/Program Files (x86)" \\
              "$WINEPREFIX/drive_c/ProgramData" \\
              "$WINEPREFIX/drive_c/users/crossover/AppData" \\
              "$WINEPREFIX/drive_c/users/crossover/Desktop"
            printf fresh > "$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
            printf template > "$WINEPREFIX/drive_c/users/crossover/AppData/wine.ini"
            printf template > "$WINEPREFIX/drive_c/users/crossover/AppData/fresh.ini"
            printf 'fresh user' > "$WINEPREFIX/user.reg"
            printf 'fresh system' > "$WINEPREFIX/system.reg"
            ln -s "\(home.path(percentEncoded: false))" "$WINEPREFIX/drive_c/users/crossover/Documents"
            \(extra)
            \(lock ? "chflags uchg \"$WINEPREFIX\"" : ":")
            exit \(status)
            """.utf8).write(to: loader)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: loader.path(percentEncoded: false))
        return runner
    }

    // A prefix as a game leaves it: saves under the profile, a link out to the home folder,
    // and files the game's own installer put in windows and Program Files.
    private func usedPrefixAndRunner() throws -> (dir: URL, runner: URL, prefix: WinePrefix) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-profile-\(UUID().uuidString)")
        let home = dir.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (dir, try fakeRunner(in: dir, home: home), try usedPrefix(in: dir, home: home))
    }

    private func usedPrefix(in dir: URL, home: URL) throws -> WinePrefix {
        let library = SteamLibrary(root: dir)
        let pfx = library.compatdata.appending(path: "1574480/pfx")
        let fm = FileManager.default
        for path in ["drive_c/windows/system32", "drive_c/users/crossover/AppData/Roaming/game",
                     "drive_c/Program Files/redist"] {
            try fm.createDirectory(at: pfx.appending(path: path), withIntermediateDirectories: true)
        }
        try Data("stale".utf8).write(to: pfx.appending(path: "drive_c/windows/system32/ntdll.dll"))
        try Data("redist".utf8).write(to: pfx.appending(path: "drive_c/windows/vcruntime.dll"))
        try Data("save".utf8)
            .write(to: pfx.appending(path: "drive_c/users/crossover/AppData/Roaming/game/save.dat"))
        try Data("installed".utf8).write(to: pfx.appending(path: "drive_c/Program Files/redist/thing.dll"))
        try Data("mine".utf8).write(to: pfx.appending(path: "user.reg"))
        try Data("stale system".utf8).write(to: pfx.appending(path: "system.reg"))
        try fm.createSymbolicLink(
            at: pfx.appending(path: "drive_c/users/crossover/Documents"), withDestinationURL: home)
        try Data("0".utf8).write(to: library.compatdata.appending(path: "1574480/notproton-msync"))
        return try #require(PrefixStore.all(libraries: [library]).first)
    }

    @Test("A launch cannot start while a rebuild is running")
    func rebuildHoldsThePrefixLock() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-rebuild-lock-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let prefix = try usedPrefix(in: dir, home: home)
        let lock = prefix.root.appending(path: ".notproton-prefix.lock").path(percentEncoded: false)
        let launched = dir.appending(path: "launched")
        let runner = try fakeRunner(
            in: dir, home: home,
            extra: "/usr/bin/lockf -s -t 0 '\(lock)' touch '\(launched.path(percentEncoded: false))' || :")

        try PrefixTools.recreate(prefix, runner: runner)

        #expect(!fm.fileExists(atPath: launched.path(percentEncoded: false)))
        #expect(!PrefixStore.isInUse(prefix, root: dir.appending(path: "sockets")))
    }

    // Why a rebuild is offered instead of a delete: the arch specific half only arrives with
    // the template, while the profile has nothing arch specific and is what a player misses.
    @Test("A rebuild keeps the Windows user profile and replaces everything else")
    func rebuildKeepsTheProfile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-rebuild-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: home.appending(path: "letter.txt"))

        let prefix = try usedPrefix(in: dir, home: home)
        try PrefixTools.recreate(prefix, runner: try fakeRunner(in: dir, home: home))

        func text(_ path: String) -> String? {
            try? String(contentsOf: prefix.pfx.appending(path: path), encoding: .utf8)
        }

        // Kept. HKCU comes over with the profile it belongs to, because a game keeps its
        // settings and sometimes its progress there.
        #expect(text("drive_c/users/crossover/AppData/Roaming/game/save.dat") == "save")
        #expect(text("user.reg") == "mine")

        // HKLM does not, so the record of what is installed matches the files that are
        // actually there and the next launch reinstalls what went with the old tree.
        #expect(text("system.reg") == "fresh system")

        // Replaced, both the file the arch is read from and what an installer left beside it.
        #expect(text("drive_c/windows/system32/ntdll.dll") == "fresh")
        #expect(text("drive_c/windows/vcruntime.dll") == nil)
        // Program Files can hold saves, so what the template lacks comes over.
        #expect(text("drive_c/Program Files/redist/thing.dll") == "installed")

        // Inside the prefix, so the folder Steam syncs is the folder the game reads. The home
        // folder the template used to point at keeps what is in it and is no longer reached.
        let inside = prefix.pfx.resolvingSymlinksInPath().path(percentEncoded: false)
        let documents = prefix.pfx.appending(path: "drive_c/users/steamuser/Documents")
        #expect(documents.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(inside))
        #expect(text("drive_c/users/crossover/Documents/letter.txt") == nil)
        #expect(fm.fileExists(atPath: home.appending(path: "letter.txt").path(percentEncoded: false)))

        #expect(!fm.fileExists(
            atPath: prefix.root.appending(path: "pfx.rebuild").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: prefix.root.appending(path: "notproton-msync").path(percentEncoded: false)))

        let kept = try #require(PrefixStore.backups(of: prefix).first)
        #expect(PrefixStore.backups(of: prefix).count == 1)
        #expect(try String(
            contentsOf: kept.appending(path: "drive_c/users/crossover/AppData/Roaming/game/save.dat"),
            encoding: .utf8) == "save")
    }

    // A prefix whose Documents is a real folder has the game's saves sitting in it. They come
    // across into the profile rather than being left behind or pushed out to the home folder.
    @Test("A real folder on the old side is carried into the prefix")
    func linksSurviveARealFolder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-rebuild-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let documents = prefix.pfx.appending(path: "drive_c/users/crossover/Documents")
        try fm.removeItem(at: documents)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: documents.appending(path: "letter.txt"))

        try PrefixTools.recreate(prefix, runner: try fakeRunner(in: dir, home: home))

        let carried = prefix.pfx.appending(path: "drive_c/users/steamuser/Documents/letter.txt")
        #expect(try String(contentsOf: carried, encoding: .utf8) == "stale")
        #expect(!fm.fileExists(atPath: home.appending(path: "letter.txt").path(percentEncoded: false)))
    }

    // Two real profile directories with a save in each. Carrying them a name at a time emptied
    // whichever the walk reached second, and which that was went by directory order.
    @Test("A rebuild keeps both profiles of a prefix that has them side by side")
    func rebuildKeepsBothProfiles() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)

        let beside = prefix.pfx.appending(path: "drive_c/users/steamuser/AppData/LocalLow/other")
        try fm.createDirectory(at: beside, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: beside.appending(path: "save.txt"))

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = prefix.pfx.appending(path: "drive_c/users/steamuser")
        func text(_ path: String) -> String? {
            try? String(contentsOf: profile.appending(path: path), encoding: .utf8)
        }
        #expect(text("AppData/Roaming/game/save.dat") == "save")
        #expect(text("AppData/LocalLow/other/save.txt") == "theirs")
    }

    // The merge keeps whichever copy the walk reaches first, never the newer date: a cloud
    // download is stamped when it arrives. crossover is the profile the game wrote under.
    @Test("Which of two profiles' copies survives does not turn on its date")
    func rebuildResolvesAProfileCollisionTheSameWayRoundEitherWay() throws {
        let shared = "AppData/Roaming/game/save.dat"
        for newest in ["crossover", "steamuser"] {
            let fm = FileManager.default
            let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
            defer { try? fm.removeItem(at: dir) }
            let home = dir.appending(path: "home")
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let runner = try fakeRunner(in: dir, home: home)
            let prefix = try usedPrefix(in: dir, home: home)
            let users = prefix.pfx.appending(path: "drive_c/users")

            let beside = users.appending(path: "steamuser/\(shared)")
            try fm.createDirectory(
                at: beside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("steamuser".utf8).write(to: beside)
            try Data("crossover".utf8).write(to: users.appending(path: "crossover/\(shared)"))
            // Stamped rather than written in order, because the copy carries the date with it
            // and the walk decides nothing.
            for name in ["crossover", "steamuser"] {
                let when = Date(timeIntervalSince1970: name == newest ? 2_000_000 : 1_000_000)
                try fm.setAttributes(
                    [.modificationDate: when],
                    ofItemAtPath: users.appending(path: "\(name)/\(shared)")
                        .path(percentEncoded: false))
            }

            try PrefixTools.recreate(prefix, runner: runner)

            let carried = users.appending(path: "steamuser/\(shared)")
            #expect(try String(contentsOf: carried, encoding: .utf8) == "crossover",
                    "the answer moved when \(newest) was made the newer copy")
        }
    }

    // merge_user_dir in dylib/feats/compat_run.sh only copies into directories not already
    // there, since one save directory holding two sessions may make no sense. Losers are parked.
    @Test("A save directory reached more than once is carried from one place and parked from the rest")
    func rebuildTakesOneInstanceOfASaveDirectory() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)
        let users = prefix.pfx.appending(path: "drive_c/users")

        for (path, mark) in [
            ("crossover/AppData/Roaming/Slot", "crossover"),
            ("steamuser/AppData/Roaming/Slot", "steamuser"),
            ("crossover/Application Data/Slot", "legacy"),
        ] {
            let folder = users.appending(path: path)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(mark.utf8).write(to: folder.appending(path: "\(mark).sav"))
            // Loose in the container the template makes, which is merged through rather than
            // taken whole, so the copies meet as files instead of as a directory.
            try Data(mark.utf8).write(
                to: folder.deletingLastPathComponent().appending(path: "note.txt"))
        }

        try PrefixTools.recreate(prefix, runner: runner)

        let roaming = users.appending(path: "steamuser/AppData/Roaming")
        func contents(_ name: String) -> [String] {
            ((try? fm.contentsOfDirectory(
                atPath: roaming.appending(path: name).path(percentEncoded: false))) ?? []).sorted()
        }
        // crossover sorts ahead of steamuser and AppData ahead of Application Data, so the
        // instance that is kept is fixed rather than left to the order the filesystem lists in.
        #expect(contents("Slot") == ["crossover.sav"], "the kept instance holds another session")
        let parked = Set(contents("Slot BACKUP") + contents("Slot BACKUP 2"))
        #expect(parked == ["legacy.sav", "steamuser.sav"], "an instance that lost was dropped")

        func read(_ name: String) -> String? {
            try? String(contentsOf: roaming.appending(path: name), encoding: .utf8)
        }
        #expect(read("note.txt") == "crossover")
        #expect(Set([read("note.txt BACKUP"), read("note.txt BACKUP 2")].compactMap { $0 })
                == ["legacy", "steamuser"], "a file that lost to another spelling was dropped")
    }

    // The template writes at wineboot, so its copy is always the newer one and the date says
    // nothing. What the player has none of stays: a newer wine adds to the profile too.
    @Test("A file the template just wrote gives way to the player's copy")
    func rebuildPrefersThePlayersCopy() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)

        let settings = prefix.pfx.appending(path: "drive_c/users/crossover/AppData/wine.ini")
        try fm.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: settings)

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = prefix.pfx.appending(path: "drive_c/users/steamuser")
        func text(_ path: String) -> String? {
            try? String(contentsOf: profile.appending(path: path), encoding: .utf8)
        }
        #expect(text("AppData/wine.ini") == "mine")
        #expect(text("AppData/fresh.ini") == "template")
    }

    // Both documents names can be real folders, the pre-Vista one from a cloud rule and the
    // modern one from wine. Only one survives as the directory, so the other has to arrive.
    @Test("Both documents names carry their files into the one directory")
    func rebuildKeepsBothDocumentsNames() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)

        let users = prefix.pfx.appending(path: "drive_c/users")
        let modern = users.appending(path: "crossover/Documents")
        try fm.removeItem(at: modern)
        try fm.createDirectory(at: modern, withIntermediateDirectories: true)
        try Data("modern".utf8).write(to: modern.appending(path: "modern.txt"))
        let preVista = users.appending(path: "crossover/My Documents")
        try fm.createDirectory(at: preVista, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: preVista.appending(path: "legacy.txt"))

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = users.appending(path: "steamuser")
        for name in ["Documents", "My Documents"] {
            for file in ["modern.txt", "legacy.txt"] {
                let carried = profile.appending(path: "\(name)/\(file)")
                #expect((try? String(contentsOf: carried, encoding: .utf8)) != nil,
                        "\(name)/\(file) did not come over")
            }
        }
    }

    // A prefix from before this layout has the profile the other way round, with steamuser
    // the link. A rebuild turns it around so Steam and the game stop reading two folders.
    @Test("A rebuild brings an older profile onto the steamuser layout")
    func rebuildPutsBackLinksTheTemplateOmits() throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let users = prefix.pfx.appending(path: "drive_c/users")

        try fm.createSymbolicLink(
            atPath: users.appending(path: "crossover/My Documents").path(percentEncoded: false),
            withDestinationPath: "Documents")
        try fm.createSymbolicLink(
            atPath: users.appending(path: "steamuser").path(percentEncoded: false),
            withDestinationPath: "crossover")

        // The old side points Documents somewhere that is no longer where the home folder
        // is, which is what a moved or renamed home leaves behind.
        try fm.removeItem(at: users.appending(path: "crossover/Documents"))
        try fm.createSymbolicLink(
            atPath: users.appending(path: "crossover/Documents").path(percentEncoded: false),
            withDestinationPath: "/somewhere/that/moved")

        try PrefixTools.recreate(prefix, runner: runner)

        func target(_ path: String) throws -> String {
            try fm.destinationOfSymbolicLink(
                atPath: users.appending(path: path).path(percentEncoded: false))
        }
        #expect(try target("crossover") == "steamuser")

        // The save came over, and the folder holding it is in the prefix rather than the
        // dangling place the old profile pointed Documents at.
        let profile = users.appending(path: "steamuser")
        let save = profile.appending(path: "AppData/Roaming/game/save.dat")
        #expect(try String(contentsOf: save, encoding: .utf8) == "save")
        let inside = prefix.pfx.resolvingSymlinksInPath().path(percentEncoded: false)
        for name in ["Documents", "My Documents"] {
            let resolved = profile.appending(path: name)
                .resolvingSymlinksInPath().path(percentEncoded: false)
            #expect(resolved.hasPrefix(inside), "\(name) resolves to \(resolved)")
        }
    }

    // Only folders were carried, so a game that keeps its settings in a file beside them
    // lost the file while its save folder came through.
    @Test("A rebuild keeps a file sitting loose in a profile")
    func rebuildKeepsALooseProfileFile() throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loose = prefix.pfx.appending(path: "drive_c/users/crossover/settings.ini")
        try Data("windowed=1".utf8).write(to: loose)

        try PrefixTools.recreate(prefix, runner: runner)

        #expect(try Data(contentsOf: loose) == Data("windowed=1".utf8))
    }

    // Every directory the merge lands is revisited for its links once all the real
    // directories are in place, and a link inside a save directory is only reached that way.
    @Test("A rebuild keeps a link sitting inside a save directory")
    func rebuildKeepsALinkInsideAProfile() throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let game = prefix.pfx.appending(path: "drive_c/users/crossover/AppData/Roaming/game")
        try FileManager.default.createSymbolicLink(
            atPath: game.appending(path: "latest").path(percentEncoded: false),
            withDestinationPath: "save.dat")

        try PrefixTools.recreate(prefix, runner: runner)

        let carried = prefix.pfx.appending(
            path: "drive_c/users/steamuser/AppData/Roaming/game/latest")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: carried.path(percentEncoded: false)) == "save.dat")
    }

    // A link carried across early holds the name a later profile has a real save directory on,
    // and a landing link is what makes the merge give up on a name.
    @Test("A link from one profile does not take the name another profile's saves land on")
    func linksWaitForEveryRealDirectory() throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let roaming = prefix.pfx.appending(path: "drive_c/users/crossover/AppData/Roaming")
        try fm.createSymbolicLink(
            atPath: roaming.appending(path: "other").path(percentEncoded: false),
            withDestinationPath: "game")
        let theirs = prefix.pfx.appending(path: "drive_c/users/steamuser/AppData/Roaming/other")
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: theirs.appending(path: "theirs.dat"))

        try PrefixTools.recreate(prefix, runner: runner)

        let landed = prefix.pfx.appending(path: "drive_c/users/steamuser/AppData/Roaming/other")
        // Read through the link the other profile left, the save comes back either way, out of
        // a directory holding a second game's files rather than its own.
        #expect(
            (try? landed.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false)
        #expect(try Data(contentsOf: landed.appending(path: "theirs.dat")) == Data("theirs".utf8))
    }

    // A game installed by hand lives where the player put it, which the template knows
    // nothing about, so the rebuild took it away along with the tree it sat beside.
    @Test("A rebuild keeps what the template does not make")
    func rebuildKeepsStrayTopLevelNames() throws {
        let (dir, runner, prefix) = try usedPrefixAndRunner()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let driveC = prefix.pfx.appending(path: "drive_c")
        try fm.createDirectory(at: driveC.appending(path: "Games/Quake"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: driveC.appending(path: "Games/Quake/quake.exe"))
        try Data("notes".utf8).write(to: driveC.appending(path: "notes.txt"))

        try PrefixTools.recreate(prefix, runner: runner)

        #expect(try Data(contentsOf: driveC.appending(path: "Games/Quake/quake.exe")) == Data("exe".utf8))
        #expect(try Data(contentsOf: driveC.appending(path: "notes.txt")) == Data("notes".utf8))

        // windows is the template's, arch and all.
        #expect(!fm.fileExists(
            atPath: driveC.appending(path: "windows/vcruntime.dll").path(percentEncoded: false)))
    }

    // Emptying the prefix first meant a wineboot that failed left the game with nothing at
    // all, and the next launch inherited the wreckage.
    @Test("A rebuild that fails leaves the prefix as it was")
    func failedRebuildKeepsTheOldPrefix() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-rebuild-fail-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let runner = try fakeRunner(in: dir, home: home, exit: 1)
        #expect(throws: (any Error).self) { try PrefixTools.recreate(prefix, runner: runner) }

        func text(_ path: String) -> String? {
            try? String(contentsOf: prefix.pfx.appending(path: path), encoding: .utf8)
        }
        #expect(text("drive_c/windows/system32/ntdll.dll") == "stale")
        #expect(text("drive_c/users/crossover/AppData/Roaming/game/save.dat") == "save")
        #expect(!fm.fileExists(atPath: prefix.root.appending(path: "pfx.rebuild").path(percentEncoded: false)))
    }

    // Every copy out of the old prefix was a try?, so a save that would not read left the fresh
    // prefix short, the old one deleted anyway, and the client synced the gap over the cloud.
    @Test("A save that cannot be copied stops the rebuild")
    func rebuildRefusesWhenASaveCannotBeCarried() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-carry-fail-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let runner = try fakeRunner(in: dir, home: home)
        let save = prefix.pfx
            .appending(path: "drive_c/users/crossover/AppData/Roaming/game/save.dat")
        try fm.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: save.path(percentEncoded: false))

        #expect(throws: (any Error).self) { try PrefixTools.recreate(prefix, runner: runner) }

        try fm.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: save.path(percentEncoded: false))

        func text(_ path: String) -> String? {
            try? String(contentsOf: prefix.pfx.appending(path: path), encoding: .utf8)
        }
        // The prefix stays the one the game was using, so the client has nothing new to sync.
        #expect(try String(contentsOf: save, encoding: .utf8) == "save")
        #expect(text("drive_c/windows/system32/ntdll.dll") == "stale")
        #expect(text("user.reg") == "mine")
        #expect(!fm.fileExists(
            atPath: prefix.root.appending(path: "pfx.rebuild").path(percentEncoded: false)))
        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    // Ubisoft Connect keeps saves under Program Files (x86), and the discard path deleted them.
    @Test("A discard rebuild carries Program Files and ProgramData, fresh files win")
    func discardRebuildCarriesProgramFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-progfiles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let drive = prefix.pfx.appending(path: "drive_c")
        for (path, body) in [
            ("Program Files (x86)/Ubisoft/savegames/1.save", "ubi"),
            ("ProgramData/Foo/x.dat", "foo"),
            ("ProgramData/Shared/both.ini", "old"),
        ] {
            let file = drive.appending(path: path)
            try fm.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file)
        }
        let runner = try fakeRunner(in: dir, home: home, extra: """
            mkdir -p "$WINEPREFIX/drive_c/ProgramData/Shared"; \
            printf fresh > "$WINEPREFIX/drive_c/ProgramData/Shared/both.ini"
            """)

        #expect(try PrefixTools.recreate(prefix, runner: runner, keepBackup: false) == nil)

        func text(_ path: String) -> String? {
            try? String(contentsOf: prefix.pfx.appending(path: "drive_c/\(path)"), encoding: .utf8)
        }
        #expect(text("Program Files (x86)/Ubisoft/savegames/1.save") == "ubi")
        #expect(text("ProgramData/Foo/x.dat") == "foo")
        #expect(text("ProgramData/Shared/both.ini") == "fresh")
        #expect(text("windows/system32/ntdll.dll") == "fresh")
        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    @Test("A discard rebuild keeps the old prefix when Program Files cannot be carried")
    func discardRebuildKeepsBackupOnMiss() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-progfiles-miss-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let save = prefix.pfx.appending(path: "drive_c/Program Files/redist/thing.dll")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: save.path(percentEncoded: false))
        defer {
            try? fm.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: save.path(percentEncoded: false))
        }

        let kept = try #require(try PrefixTools.recreate(
            prefix, runner: try fakeRunner(in: dir, home: home), keepBackup: false))
        #expect(PrefixStore.backups(of: prefix).count == 1)
        #expect(fm.fileExists(atPath: kept.appending(path: "drive_c/Program Files/redist/thing.dll")
            .path(percentEncoded: false)))
    }

    // Steam lays a prefix down in stages, so one caught early holds no profile. That is nothing
    // to carry, not something lost, and refusing it blocks the prefix most likely to need it.
    @Test("A prefix with no profile yet still rebuilds")
    func rebuildAcceptsAPrefixWithNothingToCarry() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-carry-none-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let library = SteamLibrary(root: dir)
        let pfx = library.compatdata.appending(path: "1574480/pfx")
        try fm.createDirectory(
            at: pfx.appending(path: "drive_c/windows"), withIntermediateDirectories: true)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)

        try PrefixTools.recreate(prefix, runner: try fakeRunner(in: dir, home: home))

        #expect(fm.fileExists(
            atPath: pfx.appending(path: "drive_c/users/steamuser").path(percentEncoded: false)))
        #expect(PrefixStore.backups(of: prefix).count == 1)
    }

    // The rebuild used to delete pfx.previous on sight. A half finished swap leaves the saves
    // there, the client lays a bare prefix down, and the entry looks ordinary: last copy gone.
    @Test("A prefix left from an unfinished rebuild is not deleted")
    func rebuildRefusesToDeleteAStrandedPrefix() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-stranded-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // What the client lays down before it boots the prefix: no registry yet.
        let library = SteamLibrary(root: dir)
        let entry = library.compatdata.appending(path: "1574480")
        try fm.createDirectory(
            at: entry.appending(path: "pfx/drive_c/windows"), withIntermediateDirectories: true)
        let stranded = entry
            .appending(path: "pfx.previous/drive_c/users/crossover/AppData/Roaming/game/save.dat")
        try fm.createDirectory(
            at: stranded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: stranded)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        let runner = try fakeRunner(in: dir, home: home)

        #expect(throws: StepFailure.self) { try PrefixTools.recreate(prefix, runner: runner) }

        #expect(try String(contentsOf: stranded, encoding: .utf8) == "save")
    }

    @Test("A prefix kept by an earlier rebuild is left alone by the next one")
    func rebuildKeepsAnOlderBackup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-spent-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let previous = prefix.root.appending(path: "pfx.previous")
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("spent".utf8).write(to: previous.appending(path: "user.reg"))

        try PrefixTools.recreate(prefix, runner: try fakeRunner(in: dir, home: home))

        #expect(try String(contentsOf: previous.appending(path: "user.reg"), encoding: .utf8)
            == "spent")
        #expect(PrefixStore.backups(of: prefix).count == 2)
        #expect(try String(
            contentsOf: prefix.pfx
                .appending(path: "drive_c/users/steamuser/AppData/Roaming/game/save.dat"),
            encoding: .utf8) == "save")
    }

    // The rename is the one call where the prefix is neither the old nor the new one. Failing
    // there left nothing under pfx and the saves in pfx.previous, a name the list ignores.
    @Test("A rebuild that cannot be swapped in puts the old prefix back")
    func failedSwapRestoresTheOldPrefix() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-swap-fail-\(UUID().uuidString)")
        defer {
            let clear = Process()
            clear.executableURL = URL(filePath: "/usr/bin/chflags")
            clear.arguments = ["-R", "nouchg", dir.path(percentEncoded: false)]
            try? clear.run()
            clear.waitUntilExit()
            try? fm.removeItem(at: dir)
        }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // windows is in the template, so it is skipped whole and the rebuild reaches the swap
        // with nothing recorded as lost.
        let library = SteamLibrary(root: dir)
        let pfx = library.compatdata.appending(path: "1574480/pfx")
        try fm.createDirectory(
            at: pfx.appending(path: "drive_c/windows"), withIntermediateDirectories: true)
        let marker = pfx.appending(path: "drive_c/windows/marker")
        try Data("old".utf8).write(to: marker)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        let runner = try fakeRunner(in: dir, home: home, lock: true)

        var thrown: (any Error)?
        do { try PrefixTools.recreate(prefix, runner: runner) } catch { thrown = error }

        // Every refusal in the rebuild is a StepFailure, so a Cocoa error is the rename itself
        // and not the run stopping somewhere earlier and looking the same afterwards.
        #expect((thrown as? NSError)?.domain == NSCocoaErrorDomain)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    @Test("A second rebuild keeps the prefix the first one parked")
    func rebuildKeepsEveryParkedPrefix() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-keep-all-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let runner = try fakeRunner(in: dir, home: home)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyyMMdd-HHmmss"

        let first = try #require(try PrefixTools.recreate(
            prefix, runner: runner, now: clock.date(from: "20260101-120000")!))
        let second = try #require(try PrefixTools.recreate(
            prefix, runner: runner, now: clock.date(from: "20260102-133000")!))

        #expect(first.lastPathComponent == "pfx.previous-20260101-120000")
        #expect(second.lastPathComponent == "pfx.previous-20260102-133000")
        #expect(PrefixStore.backups(of: prefix).count == 2)
        #expect(fm.fileExists(atPath: first.path(percentEncoded: false)))
    }

    @Test("Two rebuilds in the same second are kept under separate names")
    func rebuildInTheSameSecondDoesNotCollide() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-same-second-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let runner = try fakeRunner(in: dir, home: home)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyyMMdd-HHmmss"
        let instant = clock.date(from: "20260101-120000")!

        let first = try #require(try PrefixTools.recreate(prefix, runner: runner, now: instant))
        let second = try #require(try PrefixTools.recreate(prefix, runner: runner, now: instant))

        #expect(first.lastPathComponent == "pfx.previous-20260101-120000")
        #expect(second.lastPathComponent == "pfx.previous-20260101-120000-2")
        #expect(PrefixStore.backups(of: prefix).count == 2)
    }

    @Test("A rebuild with no prefix to park reports no backup")
    func rebuildWithNothingToParkReportsNoBackup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-nopark-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let library = SteamLibrary(root: dir)
        let pfx = library.compatdata.appending(path: "1574480/pfx")
        try fm.createDirectory(at: pfx, withIntermediateDirectories: true)
        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        try fm.removeItem(at: pfx)

        let parked = try PrefixTools.recreate(prefix, runner: try fakeRunner(in: dir, home: home))

        #expect(parked == nil)
        #expect(PrefixStore.backups(of: prefix).isEmpty)
    }

    @Test("Deleting a backup takes that one and leaves the live prefix")
    func deleteBackupsClearsThemAll() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-clear-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        for stamp in ["20260101-120000", "20260102-133000"] {
            try fm.createDirectory(
                at: prefix.root.appending(path: "pfx.previous-\(stamp)"),
                withIntermediateDirectories: true)
        }

        let kept = PrefixStore.backups(of: prefix)
        #expect(kept.count == 2)

        try PrefixTools.deleteBackup(kept[0])

        #expect(PrefixStore.backups(of: prefix).map(\.lastPathComponent)
            == ["pfx.previous-20260102-133000"])
        #expect(fm.fileExists(atPath: prefix.pfx.path(percentEncoded: false)))

        try PrefixTools.deleteBackup(kept[1])
        #expect(PrefixStore.backups(of: prefix).isEmpty)
        #expect(fm.fileExists(atPath: prefix.pfx.path(percentEncoded: false)))
    }

    @Test("Deleting takes the whole compatdata entry, not just the prefix inside it")
    func deleteRemovesTheEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SteamLibrary(root: dir)
        let entry = library.compatdata.appending(path: "1574480")
        try FileManager.default.createDirectory(
            at: entry.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: entry.appending(path: "bridgeplay-run.log"))

        let prefix = try #require(PrefixStore.all(libraries: [library]).first)
        try PrefixTools.delete(prefix)

        #expect(!FileManager.default.fileExists(atPath: entry.path(percentEncoded: false)))
        // The compatdata directory itself belongs to Steam and stays.
        #expect(FileManager.default.fileExists(atPath: library.compatdata.path(percentEncoded: false)))
    }

    @Test("The proton profile is laid out before wineboot can redirect it")
    func profileLayoutPrecedesWineboot() throws {
        let source = try Self.compatSource()

        let definition = try #require(source.range(of: "lay_out_proton_profile() {"))
        let call = try #require(source.range(of: "  if ! lay_out_proton_profile; then\n"))
        let settings = try #require(source.range(of: "  import_prefix_settings\n"))

        // sh reads a script top to bottom, so a call above the definition is only an
        // unknown command.
        #expect(definition.lowerBound < call.lowerBound)
        // wineboot is what swaps the profile folders for links into the mac home, so
        // they have to already exist when it runs. The settings import is the first
        // Wine process of a launch, and Wine runs wineboot --init ahead of it.
        #expect(call.lowerBound < settings.lowerBound)
    }

    @Test("The profile link points at steamuser, not out of the prefix")
    func profileLinkPointsInward() throws {
        let source = try Self.compatSource()

        // CrossOver fixes the profile name, so crossover is the link and steamuser is
        // the real directory holding the files Steam syncs.
        #expect(source.contains(#"ln -s steamuser "$users/crossover""#))
        // The reverse direction is what routed cloud saves out to the mac home.
        #expect(!source.contains(#"ln -s "$profile" "$users/steamuser""#))
    }

    // Steam resolves WinAppDataLocal, WinAppDataRoaming and WinMyDocuments through the XP
    // names, which reach the modern folders by junction. Without them an upload globs nothing.
    @Test("A rebuilt prefix reaches every cloud root by its pre-Vista name")
    func rebuildAliasesThePreVistaNames() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = prefix.pfx.appending(path: "drive_c/users/steamuser")
        // The targets are relative and spelled the way Proton spells them, so the link
        // survives the prefix moving to another volume.
        for (legacy, target) in [
            ("Local Settings/Application Data", "../AppData/Local"),
            ("Application Data", "./AppData/Roaming"),
            ("My Documents", "./Documents"),
        ] {
            let link = profile.appending(path: legacy)
            let points = try? fm.destinationOfSymbolicLink(
                atPath: link.path(percentEncoded: false))
            #expect(points == target, "\(legacy) points at \(points ?? "nothing")")

            var isDirectory: ObjCBool = false
            let found = fm.fileExists(
                atPath: link.path(percentEncoded: false), isDirectory: &isDirectory)
            #expect(found && isDirectory.boolValue, "\(legacy) does not reach a directory")
        }
    }

    // Once the client syncs a cloud rule without the alias, its download sits under the
    // pre-Vista name while the game reads the modern one. A rebuild has to bring them together.
    @Test("A cloud save left under the old name lands where the game reads")
    func rebuildCarriesACloudSaveOntoTheModernName() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)

        let stranded = prefix.pfx.appending(
            path: "drive_c/users/crossover/Local Settings/Application Data/Ghost/Saves")
        try fm.createDirectory(at: stranded, withIntermediateDirectories: true)
        try Data("cloud".utf8).write(to: stranded.appending(path: "progress.sav"))

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = prefix.pfx.appending(path: "drive_c/users/steamuser")
        let landed = profile.appending(path: "AppData/Local/Ghost/Saves/progress.sav")
        #expect((try? String(contentsOf: landed, encoding: .utf8)) == "cloud")
    }

    @Test("The launch path aliases every root the client resolves through an old name")
    func launchPathAliasesEveryCloudRoot() throws {
        let source = try Self.compatSource()

        for pair in [
            #""Local Settings/Application Data|AppData/Local|../AppData/Local""#,
            #""Application Data|AppData/Roaming|./AppData/Roaming""#,
            #""My Documents|Documents|./Documents""#,
        ] {
            #expect(source.contains(pair), "the launch path does not carry \(pair)")
        }
    }

    // The client can drop cloud files under an old name between launches, so the aliases cannot
    // be left to prefix creation. lay_out_proton_profile is what runs them every launch.
    @Test("The aliases are made from inside the profile layout, not off on their own")
    func migrationRunsEveryLaunch() throws {
        let source = try Self.compatSource()

        let definition = try #require(source.range(of: "migrate_user_paths() {"))
        let call = try #require(source.range(of: "  migrate_user_paths \"$profile\" || return 1\n"))
        let layout = try #require(source.range(of: "lay_out_proton_profile() {"))

        // sh reads a script top to bottom, so a call above the definition is only an
        // unknown command.
        #expect(definition.lowerBound < call.lowerBound)
        // A call outside the one function that is known to run before wineboot would say
        // nothing about when the aliases are made, so the call has to be within its body.
        let body = try #require(source.range(of: "\n}\n", range: layout.upperBound..<source.endIndex))
        #expect(layout.upperBound < call.lowerBound && call.upperBound < body.lowerBound)
    }

    // Steam stamps a download when it lands, so the legacy copy routinely looks newer. A
    // rebuild has to settle that the way a launch does, or survival turns on what was run.
    @Test("The modern name's copy outlives the legacy one on both paths")
    func rebuildKeepsTheModernCopyOnACollision() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)
        let old = prefix.pfx.appending(path: "drive_c/users/crossover")
        // The template points this out to the mac home, which is the escape a rebuild undoes.
        // It has to be a real folder here to hold the game's copy of the save.
        try fm.removeItem(at: old.appending(path: "Documents"))

        for (legacy, modern) in [
            ("Local Settings/Application Data", "AppData/Local"),
            ("Application Data", "AppData/Roaming"),
            ("My Documents", "Documents"),
        ] {
            for spelling in [legacy, modern] {
                try? fm.createDirectory(
                    at: old.appending(path: "\(spelling)/Ghost"), withIntermediateDirectories: true)
            }
            let game = old.appending(path: "\(modern)/Ghost/save.dat")
            let client = old.appending(path: "\(legacy)/Ghost/save.dat")
            try Data("game".utf8).write(to: game)
            try Data("client".utf8).write(to: client)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000)],
                ofItemAtPath: game.path(percentEncoded: false))
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 9_000)],
                ofItemAtPath: client.path(percentEncoded: false))
        }

        try PrefixTools.recreate(prefix, runner: runner)

        let profile = prefix.pfx.appending(path: "drive_c/users/steamuser")
        for (legacy, modern) in [
            ("Local Settings/Application Data", "AppData/Local"),
            ("Application Data", "AppData/Roaming"),
            ("My Documents", "Documents"),
        ] {
            let landed = profile.appending(path: "\(modern)/Ghost/save.dat")
            #expect((try? String(contentsOf: landed, encoding: .utf8)) == "game",
                    "\(modern) did not keep the game's copy")
            // One directory under two names, so the alias has to read back the same file.
            let alias = profile.appending(path: "\(legacy)/Ghost/save.dat")
            #expect((try? String(contentsOf: alias, encoding: .utf8)) == "game",
                    "\(legacy) disagrees with \(modern)")
        }
    }

    // A dangling link from the first profile holds the name the next profile's real folder lands
    // on. The name tests free through it while mkdir and copy refuse, so saves went quietly.
    @Test("A save survives a landing held by a link to nothing")
    func rebuildReplacesABrokenLandingLink() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)
        let users = prefix.pfx.appending(path: "drive_c/users")

        // crossover is walked first, so its link is already on the name by the time steamuser's
        // folder of the same name is merged onto it.
        try fm.createSymbolicLink(
            at: users.appending(path: "crossover/AppData/Roaming/Ghost"),
            withDestinationURL: dir.appending(path: "gone"))
        let save = users.appending(path: "steamuser/AppData/Roaming/Ghost/slot1.sav")
        try fm.createDirectory(
            at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: save)

        try PrefixTools.recreate(prefix, runner: runner)

        let landed = prefix.pfx
            .appending(path: "drive_c/users/steamuser/AppData/Roaming/Ghost/slot1.sav")
        #expect((try? String(contentsOf: landed, encoding: .utf8)) == "precious")
    }

    @Test("A save survives a link out of the prefix landing on its name")
    func rebuildKeepsARealFolderOverACarriedLink() throws {
        let fm = FileManager.default
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let outside = dir.appending(path: "outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let runner = try fakeRunner(in: dir, home: home)
        let prefix = try usedPrefix(in: dir, home: home)
        let users = prefix.pfx.appending(path: "drive_c/users")

        // A mac home redirect below the profile root, the shape a real bottle has under Desktop.
        // crossover walks first, so it took the name before steamuser's saves reached the merge.
        try fm.createSymbolicLink(
            at: users.appending(path: "crossover/AppData/Roaming/Ghost"),
            withDestinationURL: outside)
        let save = users.appending(path: "steamuser/AppData/Roaming/Ghost/slot1.sav")
        try fm.createDirectory(
            at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: save)

        try PrefixTools.recreate(prefix, runner: runner)

        let landed = prefix.pfx
            .appending(path: "drive_c/users/steamuser/AppData/Roaming/Ghost/slot1.sav")
        #expect((try? String(contentsOf: landed, encoding: .utf8)) == "precious")
        #expect(!fm.fileExists(atPath: outside.appending(path: "slot1.sav").path(percentEncoded: false)))
    }

    // The old name becomes a link, so the merge is never attempted again and anything that
    // failed to copy is unreachable. Proton raises here, which would kill the launch instead.
    @Test("The old name is only moved aside once the merge has succeeded")
    func renameWaitsForTheMerge() throws {
        let source = try Self.compatSource()

        let gate = try #require(source.range(of: #"if ! merge_user_dir "$old" "$new"; then"#))
        let rename = try #require(source.range(of: #"mv "$old" "$backup""#))
        #expect(gate.lowerBound < rename.lowerBound)
        // A bare call could not report anything: the walk reads from a pipe, so it runs in a
        // subshell and only the group's status comes back.
        #expect(!source.contains("      merge_user_dir \"$old\" \"$new\"\n"))
        // And the gate is worth nothing unless the walk can come back unhappy.
        #expect(source.contains(#"[ -z "$failed" ]"#))
        // Nothing about either failure is visible in the prefix, so the log has to carry it.
        #expect(source.contains("did not merge into $new_rel, left in place"))
        #expect(source.contains("could not be moved aside, cloud saves stay split"))
    }

    // A modern name that is a link is a shape Proton never produces, and the rename the merge
    // ends with would leave the link dangling and the files behind it unreachable.
    @Test("A cloud root whose modern name is a link is left alone")
    func migrationRefusesALinkedModernName() throws {
        let source = try Self.compatSource()

        let refusal = try #require(source.range(of: #"if [ -L "$new" ]; then"#))
        let rename = try #require(source.range(of: #"mv "$old" "$backup""#))
        #expect(refusal.lowerBound < rename.lowerBound)
    }

    // The three shapes a landing can take that no tree merges into. Each used to return,
    // dropping everything under it, and nothing recorded as lost let the swap delete the prefix.
    private func rebuild(
        _ label: String, freshProfile: String, oldPath: String, contents: String
    ) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let prefix = try usedPrefix(in: dir, home: home)
        let old = prefix.pfx.appending(path: "drive_c/users/crossover/\(oldPath)")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: old)

        let runner = try fakeRunner(
            in: dir, home: home,
            extra: "cd \"$WINEPREFIX/drive_c/users/steamuser\" && \(freshProfile)")
        try PrefixTools.recreate(prefix, runner: runner)
        return dir
    }

    @Test("A save under a landing link that leaves the prefix is kept inside it")
    func escapingLandingKeepsTheSave() throws {
        let dir = try rebuild(
            "escape", freshProfile: "ln -s \"$HOME\" Saves",
            oldPath: "Saves/game.sav", contents: "progress")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pfx = SteamLibrary(root: dir).compatdata.appending(path: "1574480/pfx")
        let parked = pfx.appending(path: "drive_c/users/steamuser/Saves BACKUP/game.sav")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "progress")
    }

    @Test("A similarly named sibling directory is outside the rebuilt prefix")
    func siblingLandingDoesNotOverwriteOutsideFiles() throws {
        let fm = FileManager.default
        let dir = URL(filePath: fm.temporaryDirectory.path(percentEncoded: false))
            .appending(path: "np-sibling-escape-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let home = dir.appending(path: "home/Documents")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let prefix = try usedPrefix(in: dir, home: home)
        let old = prefix.pfx.appending(path: "drive_c/users/crossover/Saves/game.sav")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: old)
        let runner = try fakeRunner(in: dir, home: home, extra: """
                mkdir -p "$WINEPREFIX-outside"
                printf untouched > "$WINEPREFIX-outside/game.sav"
                ln -s "$WINEPREFIX-outside" "$WINEPREFIX/drive_c/users/steamuser/Saves"
                """)
        try PrefixTools.recreate(prefix, runner: runner)

        let root = SteamLibrary(root: dir).compatdata.appending(path: "1574480")
        let outside = root.appending(path: "pfx.rebuild-outside/game.sav")
        let parked = root.appending(path: "pfx/drive_c/users/steamuser/Saves BACKUP/game.sav")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "progress")
    }

    @Test("A save file is kept when a directory holds its name")
    func fileUnderADirectoryLandingIsKept() throws {
        let dir = try rebuild(
            "filedir", freshProfile: "mkdir -p Notes",
            oldPath: "Notes", contents: "progress")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pfx = SteamLibrary(root: dir).compatdata.appending(path: "1574480/pfx")
        let parked = pfx.appending(path: "drive_c/users/steamuser/Notes BACKUP")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "progress")
    }

    @Test("A save directory is kept when a file holds its name")
    func directoryUnderAFileLandingIsKept() throws {
        let dir = try rebuild(
            "dirfile", freshProfile: "printf x > Logs",
            oldPath: "Logs/game.sav", contents: "progress")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pfx = SteamLibrary(root: dir).compatdata.appending(path: "1574480/pfx")
        let parked = pfx.appending(path: "drive_c/users/steamuser/Logs BACKUP/game.sav")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "progress")
    }
}

@Suite("Which build last ran a prefix")
struct PrefixLastBuildTests {

    private static let release = "26.3.0.39832"
    private static let preview = "27.0.0.40921-fex"

    private func makeWorld() throws -> (dir: URL, runners: URL, prefix: WinePrefix) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "np-lastbuild-\(UUID().uuidString)")
        let runners = dir.appending(path: "runners")
        for (build, time) in [(Self.release, 1_784_112_240), (Self.preview, 1_787_334_674)] {
            let inf = SupportPaths.clonedRoot(forBuild: build, runners: runners)
                .appending(path: "share/wine/wine.inf")
            try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: inf)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(time))],
                ofItemAtPath: inf.path(percentEncoded: false))
        }
        let prefix = WinePrefix(
            appID: "480", name: nil, library: SteamLibrary(root: dir.appending(path: "Steam")), lastUsed: nil)
        try fm.createDirectory(at: prefix.pfx, withIntermediateDirectories: true)
        return (dir, runners, prefix)
    }

    private func updated(_ prefix: WinePrefix, _ text: String) throws {
        try text.write(to: prefix.pfx.appending(path: ".update-timestamp"), atomically: true, encoding: .utf8)
    }

    @Test("A prefix with nothing to read from belongs to no build yet")
    func freshPrefix() throws {
        let (dir, runners, prefix) = try makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PrefixTools.lastBuild(of: prefix, runners: runners) == nil)

        try updated(prefix, "disable\n")
        #expect(PrefixTools.lastBuild(of: prefix, runners: runners) == nil)
    }

    @Test("Without a record, the clone whose wine.inf matches is the build")
    func readsTheWineThatUpdatedIt() throws {
        let (dir, runners, prefix) = try makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }

        try updated(prefix, "1787334674\n")
        #expect(PrefixTools.lastBuild(of: prefix, runners: runners)
            == PrefixBuildRecord(build: Self.preview, display: nil))

        try updated(prefix, "12345\n")
        let unknown = try #require(PrefixTools.lastBuild(of: prefix, runners: runners))
        #expect(unknown.build.isEmpty)
    }

    @Test("A record outranks the Wine that last updated the prefix")
    func recordWins() throws {
        let (dir, runners, prefix) = try makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }

        try updated(prefix, "1787334674\n")
        try "\(Self.release)\nCrossOver 26.3\n".write(
            to: prefix.root.appending(path: PrefixTools.buildRecordName), atomically: true, encoding: .utf8)
        #expect(PrefixTools.lastBuild(of: prefix, runners: runners)
            == PrefixBuildRecord(build: Self.release, display: "CrossOver 26.3"))
    }

    @Test("A tool of the other arch is never picked for a prefix")
    func noToolOfTheOtherArch() throws {
        let (dir, runners, prefix) = try makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let system32 = prefix.pfx.appending(path: "drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        var header = [UInt8](repeating: 0, count: 0x40)
        header[0x3c] = 0x40
        try Data(header + [0x50, 0x45, 0, 0, 0x64, 0x86])
            .write(to: system32.appending(path: "ntdll.dll"))
        try "\(Self.preview)\nCrossOver Preview (Rosetta)\n".write(
            to: prefix.root.appending(path: PrefixTools.buildRecordName), atomically: true, encoding: .utf8)

        let fexOnly = [InstalledTool(
            tool: CompatTool(name: "bridgeplay-proton", flavor: .fex, display: "CrossOver Preview (FEX)"),
            build: Self.preview)]
        #expect(PrefixTools.tool(for: prefix, among: fexOnly, runners: runners) == nil)

        let fex = try #require(SupportedRunners.all.first { $0.id == Self.preview })
        let both = SupportedRunners.tools(for: [fex])
        #expect(PrefixTools.tool(for: prefix, among: both, runners: runners)?.name == "bridgeplay-proton-fex-rosetta")
    }

    @Test("A prefix another CrossOver updated runs on an installed tool of its arch")
    func anotherWineFallsBackToItsArch() throws {
        let (dir, runners, prefix) = try makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = try #require(SupportedRunners.all.first { $0.id == Self.release })
        let tools = SupportedRunners.tools(for: [release])

        try updated(prefix, "1787334674\n")
        #expect(PrefixTools.tool(for: prefix, among: tools, runners: runners)?.build == Self.release)

        try updated(prefix, "1784112240\n")
        #expect(PrefixTools.tool(for: prefix, among: tools, runners: runners)?.build == Self.release)

        try "\(Self.preview)\nCrossOver Preview (Rosetta)\n".write(
            to: prefix.root.appending(path: PrefixTools.buildRecordName), atomically: true, encoding: .utf8)
        #expect(PrefixTools.tool(for: prefix, among: tools, runners: runners)?.build == Self.release)
    }
}
