import Foundation
import Testing
@testable import BridgeplayInstallerCore

struct ControllerMappingsTests {
    private let shipped = """
        # header
        aaaa,Pad A,a:b0
        # about B
        # second line
        bbbb,Pad B,a:b1
        # about C
        cccc,Pad C,a:b2

        """

    @Test("Only the GUIDs the file lacks are appended, with their comments, and the user's lines stay")
    func appendsMissing() {
        let mine = "# header\naaaa,My Pad A,a:b9\nbbbb,Pad B,a:b1\nzzzz,Mine,a:b3"
        #expect(ControllerMappings.additions(to: mine, shipped: shipped) == "\n# about C\ncccc,Pad C,a:b2\n")
    }

    @Test("A CRLF-terminated file gets no extra blank line, and a GUID in another case is the same pad")
    func crlfAndCase() {
        #expect(ControllerMappings.additions(to: "AAAA,Mine,a:b9\r\nBBBB,Mine,a:b9\r\n", shipped: shipped) == "# about C\ncccc,Pad C,a:b2\n")
    }

    @Test("Running it again changes nothing")
    func idempotent() throws {
        let mine = "zzzz,Mine,a:b3\n"
        let once = mine + (try #require(ControllerMappings.additions(to: mine, shipped: shipped)))
        #expect(ControllerMappings.additions(to: once, shipped: shipped) == nil)
        #expect(ControllerMappings.additions(to: shipped, shipped: shipped) == nil)
    }

    @Test("A file on disk is appended to in place, a non-UTF-8 one too, and a missing one throws")
    func updatesFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appending(path: "shipped.txt"), mine = dir.appending(path: "mine.txt")
        try Data(shipped.utf8).write(to: source)
        try Data("aaaa,Mine,a:b9\n".utf8).write(to: mine)
        try ControllerMappings.update(mine, from: source)
        let text = try String(contentsOf: mine, encoding: .utf8)
        #expect(text.hasPrefix("aaaa,Mine,a:b9\n"))
        #expect(text.contains("bbbb,Pad B,a:b1") && text.contains("cccc,Pad C,a:b2"))
        let after = try Data(contentsOf: mine)
        try ControllerMappings.update(mine, from: source)
        #expect(try Data(contentsOf: mine) == after)
        try Data([0x61, 0x61, 0x61, 0x61, 0x2c, 0xe9, 0x0a]).write(to: mine)
        try ControllerMappings.update(mine, from: source)
        #expect(try Data(contentsOf: mine).count > 7)
        #expect(throws: (any Error).self) { try ControllerMappings.update(dir.appending(path: "missing.txt"), from: source) }
    }
}
