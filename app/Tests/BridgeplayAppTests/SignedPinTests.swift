import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Signed pins")
struct SignedPinTests {

    private var machOResources: [URL] {
        ["so", "dylib"].flatMap { Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            + [Bundle.module.url(forResource: "cabextract", withExtension: nil)].compactMap { $0 }
    }

    // A rebuilt Wine binary with a new sha256 pin but a stale content line would pass in a
    // checkout and fail every engine install from a release.
    @Test("Every bundled Mach-O file has a content pin that matches it")
    func everyResourcePinned() throws {
        let files = machOResources
        #expect(files.count == SignedPin.content.count)
        for file in files {
            let sha = try Digest.sha256(of: file)
            let expected = try #require(SignedPin.content[sha], "\(file.lastPathComponent) has no SignedPin entry")
            let hashes = try #require(try MachOBuild.hashesIgnoringSignature(of: file))
            #expect(hashes.joined(separator: ",") == expected, "\(file.lastPathComponent)")
        }
    }

    // What a release does to the file (another signature over the same code) still matches;
    // a changed byte of code does not.
    @Test("A re-signed copy matches its pin, a modified copy does not")
    func resignedAndModified() throws {
        let original = try #require(Bundle.module.url(forResource: "winemac-winehq-11.15", withExtension: "so"))
        let pin = try Digest.sha256(of: original)
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-signedpin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resigned = dir.appending(path: "resigned.so")
        try FileManager.default.copyItem(at: original, to: resigned)
        let sign = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", "-i", "com.bridgeplay.signedpin-test",
                                                       resigned.path(percentEncoded: false)])
        #expect(sign.succeeded)
        #expect(try Digest.sha256(of: resigned) != pin)
        #expect(SignedPin.matches(resigned, sha256: pin))

        let modified = dir.appending(path: "modified.so")
        var bytes = try Data(contentsOf: original)
        bytes[0x2000] ^= 0xff
        try bytes.write(to: modified)
        // Validly signed again, so only the code differs.
        #expect(try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", modified.path(percentEncoded: false)]).succeeded)
        #expect(!SignedPin.matches(modified, sha256: pin))
        #expect(!SignedPin.matches(dir.appending(path: "missing.so"), sha256: pin))
    }
}
