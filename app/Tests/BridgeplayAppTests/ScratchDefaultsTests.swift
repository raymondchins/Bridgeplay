import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Scratch defaults")
struct ScratchDefaultsTests {

    // The reason the helper exists: a named suite would leave a plist in ~/Library/Preferences.
    @Test("A suite keeps its plist in the temporary folder, not in Preferences")
    func staysOutOfPreferences() throws {
        let suite = scratchSuiteName()
        let defaults = scratchDefaults(suite: suite)
        defaults.set("value", forKey: "key")
        #expect(defaults.string(forKey: "key") == "value")
        defaults.synchronize()

        // The write is asynchronous, so wait for the plist to show up where it belongs.
        let plist = suite + ".plist"
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: plist) { Thread.sleep(forTimeInterval: 0.1) }
        #expect(FileManager.default.fileExists(atPath: plist))

        // Look for this suite only: other processes may be writing to Preferences meanwhile.
        let id = URL(filePath: suite).lastPathComponent
        #expect(try preferenceFiles(containing: id).isEmpty)
    }

    private func preferenceFiles(containing id: String) throws -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        return try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.contains(id) }
    }
}
