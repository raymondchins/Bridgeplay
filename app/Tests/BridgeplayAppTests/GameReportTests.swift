import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Reports describe the Mac and the last launch")
struct GameReportTests {

    private let log = """
        runner: build winecx-11.15 (WineCX 11.15 (msync, D3DMetal)) at /Users/tester/Library/Application Support/bridgeplay/runners/a
        graphics: backend=dxmt
        === launching (run): /Users/tester/Library/Application Support/bridgeplay/runners/a/wine
        runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /Users/tester/Library/Application Support/bridgeplay/runners/b
        graphics: backend=d3dmetal (carried over from the last launch)
        """

    @Test("Chip and memory map onto the form's options")
    func machineFields() {
        #expect(GameReport.chip("Apple M5 Max") == "M5 Max")
        #expect(GameReport.chip("Apple M9") == "Other")
        #expect(GameReport.memory(64 * 1_073_741_824) == "64 GB")
        #expect(GameReport.memory(20 * 1_073_741_824) == "Other")
    }

    @Test("The last launch in the log wins")
    func lastLaunch() {
        let launch = GameReport.lastLaunch(in: log)
        #expect(launch.engine == "WineCX 11.17 (msync, D3DMetal)")
        #expect(launch.backend == "d3dmetal")
    }

    @Test("A run aborted before launch does not replace the one that ran")
    func abortedRun() {
        let runs = """
            === bridgeplay run Thu Oct 22 09:44:35 WIB 2026 ===
            runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /a
            graphics: backend=d3dmetal (auto-detected, the engine has D3DMetal)
            === launching (waitforexitandrun): /a/wine /g/INSIDE.exe ===
            === bridgeplay run Thu Oct 22 09:48:47 WIB 2026 ===
            runner: build winehq-11.15 (WineHQ 11.15 - Rosetta) at /b
            === prefix was last run by build winecx-11.17 and this compatibility tool runs winehq-11.15 ===
            === aborted during prefix build check (exit 1) before launch ===
            """
        let launch = GameReport.lastLaunch(in: runs)
        #expect(launch.engine == "WineCX 11.17 (msync, D3DMetal)")
        #expect(launch.backend == "d3dmetal")
        let only = GameReport.lastLaunch(in: runs.components(separatedBy: "\n").suffix(4).joined(separator: "\n"))
        #expect(only.engine == "WineHQ 11.15 - Rosetta")
    }

    @Test("The copied log hides the home folder")
    func redaction() {
        let text = GameReport.redacted(log, home: "/Users/tester")
        #expect(!text.contains("/Users/tester"))
        #expect(text.contains("~/Library/Application Support/bridgeplay"))
    }

    @Test("The copy hides Steam accounts, IDs, user, computer and drive names")
    func privateDetails() {
        let raw = """
            SteamUser=player_one
            SteamAppUser=player_one
            STEAMVIDEOTOKEN=1002
            SteamAppId=1245620
            SteamInternal_SetMinidumpSteamID:  Caching Steam ID:  76561198012345678 [API loaded no]
            account [U:1:52079950] signed in
            bash    76349 tester    8w   REG   1,18        0 57027247 /Users/tester/Library/x.lock
            STEAM_COMPAT_LIBRARY_PATHS=/Volumes/Tester's T7/SteamLibrary:/Volumes/Preboot/x
            host Testers-MacBook-Pro wrote to someone@example.com
            C:/users/crossover/AppData
            could not open working directory L"Z:\\Users\\oldname\\Library" C:\\users\\crossover
            """
        let text = GameReport.redacted(raw, home: "/Users/tester", user: "tester",
                                       computerNames: ["Tester's MacBook Pro", "Testers-MacBook-Pro"])
        for secret in ["oldname", "player_one", "1002", "76561198012345678", "52079950", "tester", "Tester's T7",
                       "Testers-MacBook-Pro", "someone@example.com"] {
            #expect(!text.contains(secret), "\(secret) is still in the log")
        }
        #expect(text.contains("SteamUser=<redacted>"))
        #expect(text.contains("SteamAppId=1245620"))
        #expect(text.contains("bash    76349 <user>    8w"))
        #expect(text.contains("/Volumes/<drive>/SteamLibrary:/Volumes/Preboot/x"))
        #expect(text.contains("C:/users/crossover/AppData"))
        #expect(text.contains("~/Library/x.lock"))
    }

    @Test("The account ID in a Steam userdata path is hidden")
    func userdataPaths() {
        let raw = #"""
            C:\Program Files (x86)\Steam\userdata\52345678\1245620\remote\save.dat
            C:\\Program Files (x86)\\Steam\\userdata\\52345678\\730\\cfg
            /Users/tester/Library/Application Support/Steam/userdata/52345678/730/local/cfg/config.cfg
            """#
        let text = GameReport.redacted(raw, home: "/Users/tester", user: "tester", computerNames: [])
        #expect(!text.contains("52345678"))
        #expect(text.contains(#"userdata\<id>\1245620"#))
        #expect(text.contains(#"userdata\\<id>\\730"#))
        #expect(text.contains("userdata/<id>/730"))
    }

    @Test("A home folder that isn't spelled like this one's is hidden too")
    func otherHomes() {
        let raw = """
            === exit cause: wine: could not load /Users/josé/Library/x.dll ===
            lsof: /Users/other/Library/y.lock and /Users/tester/z
            STEAM_COMPAT_LIBRARY_PATHS=/Users/Shared/SteamLibrary
            accounts named like it: /Users/Shared-jane/a /Users/Shared.work/b
            only the folder: /Users/Shared
            """
        let text = GameReport.redacted(raw, home: "/Users/tester", user: "tester", computerNames: [])
        #expect(!text.contains("jos") && !text.contains("other") && !text.contains("jane") && !text.contains("work"))
        #expect(text.contains("like it: /Users/<user>/a /Users/<user>/b"))
        #expect(text.contains("only the folder: /Users/Shared"))
        #expect(text.contains("load /Users/<user>/Library/x.dll"))
        #expect(text.contains("lsof: /Users/<user>/Library/y.lock and ~/z"))
        #expect(text.contains("=/Users/Shared/SteamLibrary"))
    }
}
