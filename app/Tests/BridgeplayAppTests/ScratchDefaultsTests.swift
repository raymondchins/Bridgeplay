import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Scratch defaults")
struct ScratchDefaultsTests {

    // The reason the helper exists: a named suite would leave a plist in ~/Library/Preferences,
    // so the suite's own file has to show up at the path it was given.
    @Test("A suite keeps its plist in the temporary folder")
    func staysOutOfPreferences() throws {
        let (defaults, plist) = scratchDefaultsAndPlist()
        defaults.set("value", forKey: "key")
        #expect(defaults.string(forKey: "key") == "value")
        defaults.synchronize()

        // The write is asynchronous, so wait for the plist to show up where it belongs.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: plist) { Thread.sleep(forTimeInterval: 0.1) }
        #expect(FileManager.default.fileExists(atPath: plist))
    }
}
