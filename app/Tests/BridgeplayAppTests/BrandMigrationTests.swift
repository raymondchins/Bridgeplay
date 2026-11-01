import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Moving a NotProton install to Bridgeplay 3.0.0")
struct BrandMigrationTests {

    // A fake home holding the 2.x layout, laid out like the real one.
    private struct Fixture {
        let root: URL
        let migration: BrandMigration

        var legacySupport: URL { migration.legacySupport }
        var support: URL { migration.support }
        var steam: URL { migration.steamUserData }
        var tools: URL { steam.appending(path: "compatibilitytools.d") }
        var config: URL { steam.appending(path: "config/config.vdf") }
        var localConfig: URL { steam.appending(path: "userdata/123/config/localconfig.vdf") }
        var external: URL { root.appending(path: "External/SteamLibrary") }
        var runLogGames: [URL] {
            [steam.appending(path: "steamapps/compatdata/3764200"), external.appending(path: "steamapps/compatdata/570")]
        }

        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func exists(_ url: URL) -> Bool { BrandMigration.exists(url) }
        func link(_ url: URL) throws -> String {
            try FileManager.default.destinationOfSymbolicLink(atPath: path(url))
        }
    }

    private static func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    private static func symlink(_ url: URL, to target: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: target)
    }

    static let configText = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"CompatToolMapping"
        \t\t\t\t{
        \t\t\t\t\t"3764200"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"notproton-winecx-11.17"
        \t\t\t\t\t\t"config"\t\t""
        \t\t\t\t\t\t"priority"\t\t"250"
        \t\t\t\t\t}
        \t\t\t\t\t"2651280"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"notproton"
        \t\t\t\t\t\t"config"\t\t""
        \t\t\t\t\t\t"priority"\t\t"250"
        \t\t\t\t\t}
        \t\t\t\t\t"570"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"proton_experimental"
        \t\t\t\t\t\t"config"\t\t""
        \t\t\t\t\t\t"priority"\t\t"250"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t\t"name"\t\t"notproton-outside-mapping"
        \t\t\t}
        \t\t}
        \t}
        }

        """

    static func localConfigText(home: String) -> String {
        """
        "UserLocalConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"apps"
        \t\t\t\t{
        \t\t\t\t\t"3764200"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"\(home)/.notproton/np-native NP_PAD_MODE=hid NOTPROTON_FRAMEGEN=2 %command% -novid"
        \t\t\t\t\t}
        \t\t\t\t\t"570"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"MTL_HUD_ENABLED=1 %command% -title \\"NOTPROTON_ text\\""
        \t\t\t\t\t}
        \t\t\t\t\t"10"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"FOO_NOTPROTON_BAR=1 %command%"
        \t\t\t\t\t\t"Note"\t\t"NOTPROTON_KEEP /.notproton/np-native"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }

        """
    }

    static let runScript = """
        #!/bin/sh
        # notproton CrossOver compatibility tool shim
        np_support="$HOME/Library/Application Support/notproton"
        loader_root="$HOME/Library/Application Support/notproton/launchers/$app_id"
        log="$STEAM_COMPAT_DATA_PATH/notproton-run.log"
        marker="$STEAM_COMPAT_DATA_PATH/notproton-msync"
        backends="$CX_ROOT/lib/notproton-backends"
        lock="$CX_ROOT/.notproton-msync"
        pad="$HOME/.notproton/libnp_gamepad.dylib"
        id="com.notproton.launcher.$app_id"
        frames="${NOTPROTON_FRAMEGEN:-0}"

        """

    private static func toolFiles(_ name: String) -> [(String, String)] {
        [
            ("toolmanifest.vdf", "\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/run %verb%\"\n}\n"),
            ("compatibilitytool.vdf", """
                "compatibilitytools"
                {
                  "compat_tools"
                  {
                    "\(name)"
                    {
                      "install_path" "."
                      "display_name" "WineCX 11.17 (msync, D3DMetal)"
                    }
                  }
                }

                """),
        ]
    }

    private func fixture() throws -> Fixture {
        let root = try scratchDirectory("brand-migration")
        let home = root.appending(path: "home")
        let appSupport = home.appending(path: "Library/Application Support")
        let migration = BrandMigration(
            legacySupport: appSupport.appending(path: "notproton"),
            support: appSupport.appending(path: "bridgeplay"),
            legacyCaches: home.appending(path: "Library/Caches/notproton"),
            caches: home.appending(path: "Library/Caches/bridgeplay"),
            legacyHome: home.appending(path: ".notproton"),
            home: home.appending(path: ".bridgeplay"),
            steamUserData: appSupport.appending(path: "Steam"),
            steamRunning: { false }, gameRunning: { false })
        let fixture = Fixture(root: root, migration: migration)
        let old = fixture.legacySupport
        let oldPath = fixture.path(old)

        // Support directory: a runner, an engine and a launcher linking into it absolutely,
        // a relative link, and a link to somewhere else entirely.
        try Self.write("so", to: old.appending(path: "runners/crossover-x/CrossOver/lib/wine/ntdll.so"))
        try Self.symlink(old.appending(path: "engines/WineCX.app/Contents/SharedSupport/CrossOver"),
                         to: oldPath + "/runners/crossover-x/CrossOver")
        try Self.symlink(old.appending(path: "launchers/42/Game.app/Contents/MacOS/ntdll.so"),
                         to: oldPath + "/runners/crossover-x/CrossOver/lib/wine/ntdll.so")
        try Self.symlink(old.appending(path: "launchers/42/Game.app/Contents/MacOS/relative.so"), to: "../../../x.so")
        try Self.symlink(old.appending(path: "launchers/42/elsewhere"), to: "/usr/lib/libSystem.B.dylib")
        try Self.write("#!/bin/sh\nexec \"\(oldPath)/launchers/42/Game.app/Contents/MacOS/wine\" \"$@\"\n",
                       to: old.appending(path: "launchers/42/Game.app/Contents/MacOS/launcher"), executable: true)
        try Self.write("<string>com.notproton.launcher.42</string>\n", to: old.appending(path: "launchers/42/Game.app/Contents/Info.plist"))
        try Self.write("wine log\n", to: old.appending(path: "launchers/42/notproton-wine.log"))
        try Self.write("""
            notproton-winecx-11.17\twinecx-11.17\trosetta\tWineCX 11.17 (msync, D3DMetal)
            notproton\twinecx-11.17\trosetta\tLegacy
            other-tool\twinehq-11.15\trosetta\tNot ours

            """, to: old.appending(path: "tools"))
        try Self.write("old tools\n", to: old.appending(path: "tools.bak-1115default"))
        try Self.write("dylib log\n", to: old.appending(path: "notproton.log"))
        try Self.write("app log\n", to: old.appending(path: "app.log"))

        try Self.write("tarball", to: migration.legacyCaches.appending(path: "engines/wine.tar.xz"))
        try Self.write("binary", to: migration.legacyHome.appending(path: "np-native"), executable: true)

        // Steam.
        for name in ["notproton-winecx-11.17", "notproton"] {
            let folder = fixture.tools.appending(path: name)
            for (file, text) in Self.toolFiles(name) { try Self.write(text, to: folder.appending(path: file)) }
            try Self.write(Self.runScript, to: folder.appending(path: "run"), executable: true)
            try Self.write(Self.runScript, to: folder.appending(path: "run.bak-tcc"), executable: true)
        }
        for (file, text) in Self.toolFiles("GE-Proton9") {
            try Self.write(text, to: fixture.tools.appending(path: "GE-Proton9/\(file)"))
        }
        try Self.write(Self.configText, to: fixture.config)
        try Self.write(Self.localConfigText(home: fixture.path(home)), to: fixture.localConfig)
        try Self.write("\"platform_overrides\"\n{\n}\n", to: fixture.steam.appending(path: "userdata/123/config/compat.vdf"))

        // Two mounted libraries with per-game run logs, and one on a volume that is gone.
        try Self.write("""
            "libraryfolders"
            {
            \t"0"
            \t{
            \t\t"path"\t\t"\(fixture.path(fixture.steam))"
            \t}
            \t"1"
            \t{
            \t\t"path"\t\t"\(fixture.path(fixture.external))"
            \t}
            \t"2"
            \t{
            \t\t"path"\t\t"\(fixture.path(root.appending(path: "unmounted")))"
            \t}
            }

            """, to: fixture.steam.appending(path: "steamapps/libraryfolders.vdf"))
        for game in fixture.runLogGames {
            try Self.write("run log\n", to: game.appending(path: "notproton-run.log"))
            try Self.write("", to: game.appending(path: "notproton-msync"))
        }
        try FileManager.default.createDirectory(
            at: fixture.steam.appending(path: "steamapps/compatdata/0"), withIntermediateDirectories: true)
        return fixture
    }

    private func expectMigrated(_ f: Fixture) throws {
        let new = f.support
        let newPath = f.path(new)
        let home = f.path(f.root.appending(path: "home"))

        #expect(!f.exists(f.legacySupport))
        #expect(!f.exists(f.migration.legacyCaches))
        #expect(!f.exists(f.migration.legacyHome))
        #expect(f.exists(f.migration.caches.appending(path: "engines/wine.tar.xz")))
        #expect(f.exists(f.migration.home.appending(path: "np-native")))

        // Symlinks.
        #expect(try f.link(new.appending(path: "engines/WineCX.app/Contents/SharedSupport/CrossOver"))
            == newPath + "/runners/crossover-x/CrossOver")
        #expect(try f.link(new.appending(path: "launchers/42/Game.app/Contents/MacOS/ntdll.so"))
            == newPath + "/runners/crossover-x/CrossOver/lib/wine/ntdll.so")
        #expect(try f.link(new.appending(path: "launchers/42/Game.app/Contents/MacOS/relative.so")) == "../../../x.so")
        #expect(try f.link(new.appending(path: "launchers/42/elsewhere")) == "/usr/lib/libSystem.B.dylib")
        #expect(f.exists(new.appending(path: "engines/WineCX.app/Contents/SharedSupport/CrossOver/lib/wine/ntdll.so")))

        // Support files.
        #expect(try f.read(new.appending(path: "tools")) == """
            bridgeplay-proton-winecx-11.17\twinecx-11.17\trosetta\tWineCX 11.17 (msync, D3DMetal)
            bridgeplay-proton\twinecx-11.17\trosetta\tLegacy
            other-tool\twinehq-11.15\trosetta\tNot ours

            """)
        #expect(try f.read(new.appending(path: "tools.bak-1115default")) == "old tools\n")
        #expect(f.exists(new.appending(path: "bridgeplay.log")))
        #expect(!f.exists(new.appending(path: "notproton.log")))
        #expect(f.exists(new.appending(path: "app.log")))
        #expect(f.exists(new.appending(path: "launchers/42/bridgeplay-wine.log")))
        #expect(try f.read(new.appending(path: "launchers/42/Game.app/Contents/MacOS/launcher"))
            == "#!/bin/sh\nexec \"\(newPath)/launchers/42/Game.app/Contents/MacOS/wine\" \"$@\"\n")
        #expect(try f.read(new.appending(path: "launchers/42/Game.app/Contents/Info.plist"))
            == "<string>com.notproton.launcher.42</string>\n")

        // Compatibility tools.
        #expect(!f.exists(f.tools.appending(path: "notproton-winecx-11.17")))
        #expect(!f.exists(f.tools.appending(path: "notproton")))
        for name in ["bridgeplay-proton-winecx-11.17", "bridgeplay-proton"] {
            let folder = f.tools.appending(path: name)
            #expect(try f.read(folder.appending(path: "compatibilitytool.vdf")) == Self.toolFiles(name)[1].1)
            #expect(try f.read(folder.appending(path: "toolmanifest.vdf")) == Self.toolFiles(name)[0].1)
            #expect(try f.read(folder.appending(path: "run")) == """
                #!/bin/sh
                # notproton CrossOver compatibility tool shim
                np_support="$HOME/Library/Application Support/bridgeplay"
                loader_root="$HOME/Library/Application Support/bridgeplay/launchers/$app_id"
                log="$STEAM_COMPAT_DATA_PATH/bridgeplay-run.log"
                marker="$STEAM_COMPAT_DATA_PATH/notproton-msync"
                backends="$CX_ROOT/lib/notproton-backends"
                lock="$CX_ROOT/.notproton-msync"
                pad="$HOME/.bridgeplay/libnp_gamepad.dylib"
                id="com.notproton.launcher.$app_id"
                frames="${NOTPROTON_FRAMEGEN:-0}"

                """)
            let permissions = try FileManager.default.attributesOfItem(
                atPath: f.path(folder.appending(path: "run")))[.posixPermissions] as? Int
            #expect(permissions == 0o755)
            #expect(try f.read(folder.appending(path: "run.bak-tcc")) == Self.runScript)
        }
        let ours = try FileManager.default.contentsOfDirectory(atPath: f.path(f.tools)).filter { $0.hasPrefix("bridgeplay") }
        #expect(ours.sorted() == ["bridgeplay-proton", "bridgeplay-proton-winecx-11.17"])

        // Per-game run logs in every library; prefix markers stay.
        for game in f.runLogGames {
            #expect(try f.read(game.appending(path: "bridgeplay-run.log")) == "run log\n")
            #expect(!f.exists(game.appending(path: "notproton-run.log")))
            #expect(f.exists(game.appending(path: "notproton-msync")))
        }
        #expect(try f.read(f.tools.appending(path: "GE-Proton9/compatibilitytool.vdf")) == Self.toolFiles("GE-Proton9")[1].1)

        // config.vdf: only the two mappings that are ours.
        #expect(try f.read(f.config) == Self.configText
            .replacingOccurrences(of: "\"notproton-winecx-11.17\"", with: "\"bridgeplay-proton-winecx-11.17\"")
            .replacingOccurrences(of: "\"name\"\t\t\"notproton\"\n", with: "\"name\"\t\t\"bridgeplay-proton\"\n"))

        // localconfig.vdf: only LaunchOptions values, only word-initial NOTPROTON_.
        #expect(try f.read(f.localConfig) == Self.localConfigText(home: home)
            .replacingOccurrences(of: "\(home)/.notproton/np-native NP_PAD_MODE=hid NOTPROTON_FRAMEGEN=2",
                                  with: "\(home)/.bridgeplay/np-native NP_PAD_MODE=hid BRIDGEPLAY_FRAMEGEN=2")
            .replacingOccurrences(of: "\\\"NOTPROTON_ text\\\"", with: "\\\"BRIDGEPLAY_ text\\\""))

        // Backups hold the originals.
        let backups = new.appending(path: BrandMigration.backupFolder)
        #expect(try f.read(backups.appending(path: "config/config.vdf")) == Self.configText)
        #expect(try f.read(backups.appending(path: "userdata/123/config/localconfig.vdf")) == Self.localConfigText(home: home))
        #expect(f.exists(backups.appending(path: "userdata/123/config/compat.vdf")))

        #expect(try f.read(new.appending(path: BrandMigration.markerName)).contains("done"))
        #expect(!f.migration.isNeeded)
    }

    @Test("Moves every name over and is a no-op the second time")
    func migratesAndIsIdempotent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.migration.isNeeded)

        let summary = try f.migration.run()
        #expect(summary.toolsRenamed == 2)
        #expect(summary.mappingsRewritten == 2)
        #expect(summary.launchOptionsRewritten == 2)
        #expect(summary.symlinksFixed == 2)
        #expect(summary.logsRenamed == 4)
        #expect(summary.notes.isEmpty)
        try expectMigrated(f)

        #expect(try f.migration.run() == BrandMigration.Summary())
        try expectMigrated(f)
    }

    @Test("A run log that can't be renamed stays put and the move still finishes")
    func runLogThatCannotBeRenamed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let locked = f.runLogGames[1]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.path(locked))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path(locked)) }

        let summary = try f.migration.run()

        #expect(summary.logsRenamed == 3)
        #expect(summary.logsLeft == 1)
        #expect(summary.notes.isEmpty)
        #expect(try f.read(locked.appending(path: "notproton-run.log")) == "run log\n")
        #expect(!f.exists(locked.appending(path: "bridgeplay-run.log")))
        #expect(try f.read(f.support.appending(path: BrandMigration.markerName)).contains("done"))
        #expect(!f.migration.isNeeded)
    }

    @Test("A crash after the move resumes from the marker")
    func resumesAfterMove() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // Do steps 1 and 2 by hand the way run() records them, then "crash".
        var notes: [String] = []
        let backups = f.legacySupport.appending(path: BrandMigration.backupFolder)
        try Self.write(Self.configText, to: backups.appending(path: "config/config.vdf"))
        try Self.write(Self.localConfigText(home: f.path(f.root.appending(path: "home"))),
                       to: backups.appending(path: "userdata/123/config/localconfig.vdf"))
        try Self.write("x", to: backups.appending(path: "userdata/123/config/compat.vdf"))
        try Self.write("backup\nmove\n", to: f.legacySupport.appending(path: BrandMigration.markerName))
        try BrandMigration.merge(f.legacySupport, into: f.support, notes: &notes)
        try BrandMigration.merge(f.migration.legacyCaches, into: f.migration.caches, notes: &notes)
        try BrandMigration.merge(f.migration.legacyHome, into: f.migration.home, notes: &notes)
        // Half of step 5 too: one tool folder renamed but not rewritten.
        try FileManager.default.moveItem(at: f.tools.appending(path: "notproton"), to: f.tools.appending(path: "bridgeplay-proton"))

        #expect(!f.exists(f.legacySupport))
        #expect(f.migration.isNeeded)
        let summary = try f.migration.run()
        #expect(summary.toolsRenamed == 1)
        #expect(summary.symlinksFixed == 2)
        try expectMigrated(f)
    }

    @Test("An existing bridgeplay directory is merged without overwriting")
    func mergesIntoExistingDestination() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Self.write("new app log\n", to: f.support.appending(path: "app.log"))
        try Self.write("already\n", to: f.support.appending(path: "launchers/7/kept"))
        try Self.write("dsstore", to: f.support.appending(path: ".DS_Store"))
        try Self.write("dsstore", to: f.legacySupport.appending(path: ".DS_Store"))

        let summary = try f.migration.run()
        #expect(try f.read(f.support.appending(path: "app.log")) == "new app log\n")
        #expect(f.exists(f.support.appending(path: "launchers/7/kept")))
        #expect(f.exists(f.support.appending(path: "launchers/42/Game.app/Contents/MacOS/launcher")))
        // The conflicting app.log stays where it was, with the legacy directory around it.
        #expect(try f.read(f.legacySupport.appending(path: "app.log")) == "app log\n")
        #expect(summary.notes.count == 1)
        #expect(summary.notes.first?.contains("app.log") == true)
        #expect(!f.exists(f.legacySupport.appending(path: BrandMigration.markerName)))
        #expect(!f.migration.isNeeded)
        #expect(try f.read(f.support.appending(path: "tools")).hasPrefix("bridgeplay-proton-winecx-11.17\t"))
    }

    @Test("A compatibility tool whose new name exists is left in place")
    func keepsToolWhenTargetExists() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Self.write("mine\n", to: f.tools.appending(path: "bridgeplay-proton-winecx-11.17/run"))

        let summary = try f.migration.run()
        #expect(summary.toolsRenamed == 1)
        #expect(f.exists(f.tools.appending(path: "notproton-winecx-11.17/run")))
        #expect(try f.read(f.tools.appending(path: "bridgeplay-proton-winecx-11.17/run")) == "mine\n")
        #expect(summary.notes.contains { $0.contains("notproton-winecx-11.17") })
    }

    @Test("Refuses while Steam or a game runs, and does nothing for a fresh install")
    func preconditions() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var steam = f.migration
        steam.steamRunning = { true }
        #expect(steam.canRun() == .steamRunning)
        #expect(throws: BrandMigration.Failure.blocked(.steamRunning)) { try steam.run() }
        var game = f.migration
        game.gameRunning = { true }
        #expect(game.canRun() == .gameRunning)
        #expect(f.exists(f.legacySupport))
        #expect(f.migration.canRun() == nil)

        let fresh = try scratchDirectory("brand-migration-fresh")
        defer { try? FileManager.default.removeItem(at: fresh) }
        #expect(!BrandMigration.isNeeded(
            legacySupport: fresh.appending(path: "notproton"), support: fresh.appending(path: "bridgeplay")))
    }

    @Test("Every migrated tool name contains \"proton\", so Steam maps Cloud save paths for it")
    func migratedNamesContainProton() {
        let names = ["notproton", "notproton-winecx-11.17", "notproton-winehq", "notproton-winecx",
                     "notproton-fex-winecx-11.17", "notproton-x"]
        for name in names {
            let moved = BrandMigration.migratedToolName(name)
            #expect(moved?.contains("proton") == true)
            #expect(moved?.hasPrefix("bridgeplay-proton") == true)
        }
    }

    @Test("Libraries come from libraryfolders.vdf, with Steam's own folder always first")
    func readsLibraries() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.migration.libraries().map(f.path) == [
            f.path(f.steam), f.path(f.external), f.path(f.root.appending(path: "unmounted")),
        ])
    }

    @Test("Tool names: only ours are renamed")
    func toolNames() {
        #expect(BrandMigration.migratedToolName("notproton") == "bridgeplay-proton")
        #expect(BrandMigration.migratedToolName("notproton.none") == "bridgeplay-proton.none")
        #expect(BrandMigration.migratedToolName("notprotonish") == nil)
        #expect(BrandMigration.migratedToolName("notproton-winecx-11.17") == "bridgeplay-proton-winecx-11.17")
        #expect(BrandMigration.migratedToolName("notproton-fex-winecx-11.17") == "bridgeplay-proton-fex-winecx-11.17")
        #expect(BrandMigration.migratedToolName("notprotonx") == nil)
        #expect(BrandMigration.migratedToolName("proton_experimental") == nil)
        #expect(BrandMigration.migratedToolName("bridgeplay-proton-winehq") == nil)
    }
}
