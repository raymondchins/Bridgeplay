import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Scratch defaults")
struct ScratchDefaultsTests {

    // The reason the helper exists: a named suite would leave a plist in ~/Library/Preferences.
    @Test("A suite keeps its plist in the temporary folder, not in Preferences")
    func staysOutOfPreferences() throws {
        let defaults = scratchDefaults()
        defaults.set("value", forKey: "key")
        #expect(defaults.string(forKey: "key") == "value")
        defaults.synchronize()

        // The write is asynchronous, so wait for the plist to show up where it belongs.
        let folder = ScratchDefaults.folder.path(percentEncoded: false)
        var written: [String] = []
        for _ in 0..<50 where written.isEmpty {
            written = try FileManager.default.contentsOfDirectory(atPath: folder)
            if written.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(!written.isEmpty)
        // Look for this suite only: other processes may be writing to Preferences meanwhile.
        let preferences = try #require(written.first.map { try preferenceFiles(named: $0) })
        #expect(preferences.isEmpty)
    }

    private func preferenceFiles(named name: String) throws -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        return try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix(name.replacingOccurrences(of: ".plist", with: "")) }
    }
}
