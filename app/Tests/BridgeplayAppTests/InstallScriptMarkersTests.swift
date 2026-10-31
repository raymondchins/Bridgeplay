import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Install script markers")
struct InstallScriptMarkersTests {

    // Marvel's Spider-Man 2's installscript.vdf, which put the PlayStation PC SDK in
    // drive_c and recorded it in HKCU.
    private static let script = """
        "InstallScript"
        {
        \t"Run Process"
        \t{
        \t\t"PlayStation SDK 3.50"
        \t\t{
        \t\t\t"HasRunKey"\t\t"HKEY_CURRENT_USER\\\\SOFTWARE\\\\Insomniac Games\\\\Marvel's Spider-Man 2"
        \t\t\t"Process 1"\t\t"%INSTALLDIR%\\\\install_pspc_sdk_runtime.bat"
        \t\t}
        \t\t"Machine Wide"
        \t\t{
        \t\t\t"HasRunKey"\t\t"HKEY_LOCAL_MACHINE\\\\Software\\\\Example"
        \t\t}
        \t}
        \t"Firewall"
        \t{
        \t\t"Marvel's Spider-Man 2"\t\t"%INSTALLDIR%\\\\Spider-Man2.exe"
        \t}
        }
        "kvsignatures"
        {
        \t"InstallScript"\t\t"87acaad9"
        }
        """

    private static let registry = """
        WINE REGISTRY Version 2

        [Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2] 1791694571
        #time=1dd593cd5fa8332
        "FirstRun"=dword:00000000
        "PlayStation SDK 3.50"=dword:00000001
        "ShowLauncher"=dword:00000000

        [Software\\\\Other] 1791694571
        "PlayStation SDK 3.50"=dword:00000001

        """

    @Test("Only HKCU Run Process markers are read, keyed as user.reg names them")
    func readsMarkers() {
        #expect(InstallScriptMarkers.markers(inScript: Self.script) == [
            .init(key: "SOFTWARE\\Insomniac Games\\Marvel's Spider-Man 2", value: "PlayStation SDK 3.50")
        ])
    }

    @Test("A script with Windows line endings gives the same markers")
    func readsCRLFScript() {
        let crlf = Self.script.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(InstallScriptMarkers.markers(inScript: crlf) == InstallScriptMarkers.markers(inScript: Self.script))
        #expect(InstallScriptMarkers.markers(inScript: crlf).count == 1)
    }

    @Test("The marker goes and the game's other settings and keys stay")
    func clearsOnlyTheMarker() {
        let result = InstallScriptMarkers.clear(
            InstallScriptMarkers.markers(inScript: Self.script), in: Self.registry)
        #expect(result.removed.map(\.value) == ["PlayStation SDK 3.50"])
        #expect(!result.text.contains("Spider-Man 2] 1791694571\n#time=1dd593cd5fa8332\n\"FirstRun\"=dword:00000000\n\"PlayStation"))
        #expect(result.text.contains("\"FirstRun\"=dword:00000000\n\"ShowLauncher\"=dword:00000000"))
        #expect(result.text.contains("[Software\\\\Other] 1791694571\n\"PlayStation SDK 3.50\"=dword:00000001"))
    }

    @Test("A game without an install script leaves user.reg untouched")
    func noScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = dir.appending(path: "user.reg")
        try Data(Self.registry.utf8).write(to: reg)
        #expect(InstallScriptMarkers.clear(userReg: reg, installDirectory: dir).isEmpty)
        #expect(try String(contentsOf: reg, encoding: .utf8) == Self.registry)

        try Data(Self.script.utf8).write(to: dir.appending(path: "installscript.vdf"))
        #expect(InstallScriptMarkers.clear(userReg: reg, installDirectory: dir) == ["PlayStation SDK 3.50"])
        #expect(try !String(contentsOf: reg, encoding: .utf8).contains("Spider-Man 2] 1791694571\n#time=1dd593cd5fa8332\n\"FirstRun\"=dword:00000000\n\"PlayStation"))
    }
}
