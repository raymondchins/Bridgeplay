import Foundation
import Testing
@testable import BridgeplayApp

@Suite struct GameDefaultsTests {
    @Test func readsTheLastAssignmentInEitherSpelling() {
        #expect(GameDefaults.isOn(.highResolution, in: "RETINA=1\n"))
        #expect(GameDefaults.isOn(.highResolution, in: "  BRIDGEPLAY_RETINA=1  \n"))
        #expect(!GameDefaults.isOn(.highResolution, in: "RETINA=1\nRETINA=0\n"))
        #expect(!GameDefaults.isOn(.metalHUD, in: "# MTL_HUD_ENABLED=1\n"))
        #expect(!GameDefaults.isOn(.metalHUD, in: ""))
    }

    @Test func keepsEveryOtherLineAndReplacesOnlyItsOwn() {
        let text = "# mine\nMTL_HUD_ENABLED=1\nRETINA=1\nBRIDGEPLAY_RETINA=1\nROSETTA_ADVERTISE_AVX=1\n"
        let off = GameDefaults.setting(.highResolution, to: "0", in: text)
        #expect(off == "# mine\nMTL_HUD_ENABLED=1\nROSETTA_ADVERTISE_AVX=1\n")
        let on = GameDefaults.setting(.metalHUD, to: "1", in: "# mine\nROSETTA_ADVERTISE_AVX=1")
        #expect(on == "# mine\nROSETTA_ADVERTISE_AVX=1\nMTL_HUD_ENABLED=1\n")
    }

    @Test func startsANewFileWithItsHeaderAndEmptiesItWhenAllIsOff() {
        let on = GameDefaults.setting(.metalHUD, to: "1", in: "")
        #expect(on == GameDefaults.header + "\nMTL_HUD_ENABLED=1\n")
        #expect(GameDefaults.setting(.metalHUD, to: "0", in: "MTL_HUD_ENABLED=1\n") == "")
    }

    @Test func writesAndReadsBackAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gamedefaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "gamefixes/default.conf")
        let shipped = dir.appending(path: "gamefixes-default/default.conf")
        try GameDefaults.set(.highResolution, to: true, at: url, shipped: shipped)
        #expect(GameDefaults.isOn(.highResolution, at: url, shipped: shipped))
        try GameDefaults.set(.highResolution, to: false, at: url, shipped: shipped)
        #expect(!GameDefaults.isOn(.highResolution, at: url, shipped: shipped))
    }

    // MARK: Over Bridgeplay's shipped defaults

    @Test func offOverAShippedOnIsWrittenAsZero() {
        let shipped = "NVAPI=1\nROSETTA_ADVERTISE_AVX=1\n"
        #expect(GameDefaults.isOn(.nvapi, in: "", shipped: shipped))
        let off = GameDefaults.setting(.nvapi, to: "0", in: "", shipped: shipped)
        #expect(off == GameDefaults.header + "\nNVAPI=0\n")
        #expect(!GameDefaults.isOn(.nvapi, in: off, shipped: shipped))
        // Back on is what the shipped file already gives, so the line goes.
        #expect(GameDefaults.setting(.nvapi, to: "1", in: off, shipped: shipped) == GameDefaults.header + "\n")
    }

    @Test func resetRemovesTheLineWhateverItSays() {
        let text = "# mine\nBACKEND=dxvk\nFRAMEGEN=3\n"
        #expect(GameDefaults.setting(.backend, to: nil, in: text) == "# mine\nFRAMEGEN=3\n")
        #expect(GameDefaults.resettingAll(in: text + "WINEDEBUG=-all\n") == "# mine\nWINEDEBUG=-all\n")
    }

    @Test func choicesAndTheirFallbacks() {
        #expect(GameDefaults.setting(.backend, to: "dxvk", in: "") == GameDefaults.header + "\nBACKEND=dxvk\n")
        // Protect UI is on when unset, so on writes nothing and off writes 0.
        #expect(GameDefaults.setting(.frameGenUI, to: "1", in: "") == "")
        #expect(GameDefaults.setting(.frameGenUI, to: "0", in: "") == GameDefaults.header + "\nFRAMEGEN_UI=0\n")
        #expect(GameDefaults.setting(.frameGenQuality, to: "balanced", in: "") == "")
        #expect(GameDefaults.value(.frameGen, in: "BRIDGEPLAY_FRAMEGEN=1\n") == "2")
    }

    // The run script applies these only on D3DMetal, so their rows carry its caption.
    @Test func d3dMetalSettingsNameTheirRequirement() {
        let needing = GameDefaults.Setting.allCases.filter { $0.requirement == .d3dmetal }
        #expect(Set(needing) == [.nvapi, .dlssFrameGen, .metalFX])
    }

    @Test func layersResolveAsTheRunScriptReadsThem() {
        let shipped = "NVAPI=1\nBACKEND=dxmt\n"
        let user = "BACKEND=dxvk\n"
        #expect(GameDefaults.resolve(.backend, user: user, shipped: shipped) == .init(value: "dxvk", source: .user))
        #expect(GameDefaults.resolve(.nvapi, user: user, shipped: shipped) == .init(value: "1", source: .bridgeplay))
        #expect(GameDefaults.resolve(.metalHUD, user: user, shipped: shipped) == .init(value: "0", source: .engine))
        #expect(GameDefaults.resolve(.msync, user: user, shipped: shipped) == .init(value: nil, source: .engine))
    }

    @Test func refusedValuesAreSkippedAndReported() throws {
        // The run script skips a refused line, so the one before it still applies.
        #expect(GameDefaults.value(.backend, in: "BACKEND=dxvk\nBACKEND=vulkan\n") == "dxvk")
        #expect(GameDefaults.value(.metalHUD, in: "MTL_HUD_ENABLED=$(evil)\n") == nil)
        let problems = GameDefaults.problems(in: "BACKEND=vulkan\nRETINA=yes\nWINEDEBUG=-all\n")
        #expect(problems.map(\.setting) == [.backend, .highResolution])
        #expect(GameDefaults.refusal("dxvk", for: .backend) == nil)
        #expect(GameDefaults.refusal("a\"b", for: .dllOverrides) != nil)
        #expect(GameDefaults.refusal(String(repeating: "a", count: 1025), for: .metalHUD) != nil)
        #expect(GameDefaults.refusal("2", for: .metalHUD) == nil)
        #expect(GameDefaults.refusal("2", for: .nvapi) != nil)

        let dir = FileManager.default.temporaryDirectory.appending(path: "gamedefaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.conf")
        #expect(throws: GameDefaults.Refused.self) {
            try GameDefaults.set(.backend, to: "vulkan", at: url, shipped: dir.appending(path: "none"))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func dllOverridesFollowWineSyntax() {
        for good in ["dinput8=n,b", "dinput8=n,b;xinput1_3=n", "d3d9,d3d11=b", "a.dll=d", ";"] {
            #expect(GameDefaults.validDLLOverrides(good), "\(good)")
        }
        for bad in ["", "dinput8", "dinput8=x", ",a=n", "a,=n", "a,,b=n", "a b=n", "=n"] {
            #expect(!GameDefaults.validDLLOverrides(bad), "\(bad)")
        }
    }

    // MARK: Splitting the shipped defaults out of the user's file

    private static let shipped = "# Global defaults\n# Rosetta hides AVX\nROSETTA_ADVERTISE_AVX=1\nD3DM_ENABLE_METALFX=1\nNVAPI=1\n"

    @Test func anUneditedCopyLeavesNothing() {
        #expect(GameDefaults.splitText(Self.shipped, baseline: Self.shipped) == nil)
    }

    @Test func anEditedCopyKeepsOnlyTheUsersChanges() {
        // The user turned on the HUD, set their own backend and deleted NVAPI=1.
        let user = "# Global defaults\n# Rosetta hides AVX\nROSETTA_ADVERTISE_AVX=1\nD3DM_ENABLE_METALFX=1\n" +
            "# my HUD\nMTL_HUD_ENABLED=1\nBACKEND=dxvk\n"
        #expect(GameDefaults.splitText(user, baseline: Self.shipped) == "# my HUD\nMTL_HUD_ENABLED=1\nBACKEND=dxvk\nNVAPI=0\n")
        // A shipped value the user changed stays theirs.
        #expect(GameDefaults.splitText(Self.shipped.replacingOccurrences(of: "NVAPI=1", with: "NVAPI=0"),
                                       baseline: Self.shipped) == "NVAPI=0\n")
    }

    @Test func splitsOnceWithABackup() throws {
        let support = try scratchDirectory("gamedefaults-split")
        defer { try? FileManager.default.removeItem(at: support) }
        func put(_ path: String, _ text: String) throws {
            let url = support.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let user = support.appending(path: "gamefixes/default.conf")
        try put("gamefixes/default.conf", Self.shipped + "MTL_HUD_ENABLED=1\n")
        try put(".installer/default.conf", Self.shipped)
        // Nothing happens before the shipped file is installed.
        #expect(try !GameDefaults.splitShipped(in: support))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: GameDefaults.splitMarker).path))

        try put("gamefixes-default/default.conf", Self.shipped)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try GameDefaults.splitShipped(in: support, now: now))
        #expect(GameDefaults.read(user) == "MTL_HUD_ENABLED=1\n")
        #expect(GameDefaults.read(support.appending(path: "backups/default.conf.1800000000")) == Self.shipped + "MTL_HUD_ENABLED=1\n")
        #expect(FileManager.default.fileExists(atPath: support.appending(path: GameDefaults.splitMarker).path))

        // Once only: a later edit that matches a shipped line is the user's now.
        try put("gamefixes/default.conf", "NVAPI=1\n")
        #expect(try !GameDefaults.splitShipped(in: support, now: now))
        #expect(GameDefaults.read(user) == "NVAPI=1\n")
    }

    @Test func anUneditedFileIsRemoved() throws {
        let support = try scratchDirectory("gamedefaults-unedited")
        defer { try? FileManager.default.removeItem(at: support) }
        for path in ["gamefixes/default.conf", "gamefixes-default/default.conf"] {
            let url = support.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.shipped.utf8).write(to: url)
        }
        #expect(try GameDefaults.splitShipped(in: support))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "gamefixes/default.conf").path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: support.appending(path: "backups").path)
        #expect(backups.count == 1)
    }

    @Test func onlyARecordedCopyTurnsADeletedKeyOff() throws {
        func split(_ text: String, record: String?) throws -> String {
            let support = try scratchDirectory("gamedefaults-record")
            defer { try? FileManager.default.removeItem(at: support) }
            var files = ["gamefixes/default.conf": text, "gamefixes-default/default.conf": Self.shipped]
            if let record { files[".installer/default.conf"] = record }
            for (path, text) in files {
                let url = support.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try GameDefaults.splitShipped(in: support)
            return GameDefaults.read(support.appending(path: "gamefixes/default.conf"))
        }
        // The app wrote these, not an installer: nothing was deleted, so nothing is turned off.
        #expect(try split("MTL_HUD_ENABLED=1\n", record: nil) == "MTL_HUD_ENABLED=1\n")
        #expect(try split("", record: nil) == "")
        // The user deleted NVAPI=1 from the copy the installer recorded, or wrote NVAPI=0.
        #expect(try split(Self.shipped.replacingOccurrences(of: "NVAPI=1\n", with: ""), record: Self.shipped) == "NVAPI=0\n")
        #expect(try split(Self.shipped.replacingOccurrences(of: "NVAPI=1", with: "NVAPI=0"), record: Self.shipped) == "NVAPI=0\n")
    }

    // MARK: Games with their own settings

    @Test func launchVariablesAreTheWordsBeforeCommand() {
        #expect(GameDefaults.launchVariables("CX_GRAPHICS_BACKEND=dxvk FOO=1 %command% -BAR=1") == ["CX_GRAPHICS_BACKEND", "FOO"])
        #expect(GameDefaults.launchVariables("-novid MTL_HUD_ENABLED=1") == [])
        #expect(GameDefaults.launchOverrides("NOTPROTON_RETINA=1 WINEMSYNC=0 %COMMAND%") == [.highResolution, .msync])
    }

    @Test func scansConfsAndEveryAccountsLaunchOptions() throws {
        let root = try scratchDirectory("gamedefaults-overrides")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try put("gamefixes/1245620.conf", "BACKEND=dxvk\nWINEDEBUG=-all\n")
        try put("gamefixes/990080.conf", "WINEDEBUG=-all\n")
        try put("gamefixes/default.conf", "BACKEND=dxmt\n")
        let localconfig = """
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
        \t\t\t\t\t"287700"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"CX_GRAPHICS_BACKEND=dxmt BRIDGEPLAY_FRAMEGEN=2 %command%"
        \t\t\t\t\t}
        \t\t\t\t\t"440"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"-novid"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """
        try put("steam/userdata/111/config/localconfig.vdf", localconfig)
        try put("steam/userdata/222/config/localconfig.vdf", localconfig.replacingOccurrences(of: "CX_GRAPHICS_BACKEND=dxmt ", with: ""))

        let found = GameDefaults.overrides(gamefixes: root.appending(path: "gamefixes"),
                                           steamUserData: root.appending(path: "steam"), libraries: [])
        #expect(found == [
            .init(appID: "1245620", place: .conf, settings: [.backend]),
            .init(appID: "287700", place: .launchOptions(account: "111"), settings: [.backend, .frameGen]),
            .init(appID: "287700", place: .launchOptions(account: "222"), settings: [.frameGen]),
        ])
    }

    @Test func namesEachGameFromItsManifestOrShortcut() throws {
        let root = try scratchDirectory("gamedefaults-names")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ path: String, _ data: Data) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for appID in ["3372060", "990080", "3000000000"] {
            try put("gamefixes/\(appID).conf", Data("MTL_HUD_ENABLED=0\n".utf8))
        }
        let library = SteamLibrary(root: root.appending(path: "external"))
        try put("external/steamapps/appmanifest_3372060.acf",
                Data("\"AppState\"\n{\n\t\"appid\"\t\t\"3372060\"\n\t\"name\"\t\t\"Hell \\\"Maiden\\\"\"\n}\n".utf8))
        var vdf: [UInt8] = [0x00] + Array("shortcuts".utf8) + [0] + [0x00, 0x30, 0]
        vdf += [0x02] + Array("appid".utf8) + [0] + withUnsafeBytes(of: UInt32(3_000_000_000).littleEndian, Array.init)
        vdf += [0x01] + Array("AppName".utf8) + [0] + Array("Postal2".utf8) + [0]
        vdf += [0x08, 0x08, 0x08]
        try put("steam/userdata/111/config/shortcuts.vdf", Data(vdf))

        let found = GameDefaults.overrides(gamefixes: root.appending(path: "gamefixes"),
                                           steamUserData: root.appending(path: "steam"), libraries: [library])
        #expect(found.map(\.name) == ["Postal2", "Hell \"Maiden\"", nil])
    }

    @Test func useDefaultsForAConfKeepsOtherLinesAndABackup() throws {
        let root = try scratchDirectory("gamedefaults-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let gamefixes = root.appending(path: "gamefixes")
        try FileManager.default.createDirectory(at: gamefixes, withIntermediateDirectories: true)
        try Data("# fix\nBACKEND=dxvk\nWINEDEBUG=-all\n".utf8).write(to: gamefixes.appending(path: "42.conf"))
        let backups = root.appending(path: "backups")
        try GameDefaults.clearConf(appID: "42", gamefixes: gamefixes, backups: backups,
                                   now: Date(timeIntervalSince1970: 5))
        #expect(GameDefaults.read(gamefixes.appending(path: "42.conf")) == "# fix\nWINEDEBUG=-all\n")
        #expect(GameDefaults.read(backups.appending(path: "42.conf.5")) == "# fix\nBACKEND=dxvk\nWINEDEBUG=-all\n")
    }
}
