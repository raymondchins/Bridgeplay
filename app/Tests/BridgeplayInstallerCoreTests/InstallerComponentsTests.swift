import Foundation
import CryptoKit
import Testing
@testable import BridgeplayInstallerCore

@Suite("Installer components")
struct InstallerComponentsTests {
    private let key = Curve25519.Signing.PrivateKey()

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "components-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func signed(_ data: Data) throws -> InstallerComponents {
        let signature = try key.signature(for: data).base64EncodedString()
        return try InstallerComponents(signatureFile: "\(signature) \(data.count)\n",
                                       verificationKey: key.publicKey.rawRepresentation)
    }

    @Test("The signature file is a base64 EdDSA signature and a length")
    func parse() throws {
        let signature = Data(repeating: 7, count: 64).base64EncodedString()
        #expect(try InstallerComponents(signatureFile: "\(signature) 504399923").length == 504_399_923)
        for bad in ["", signature, "\(signature) 0", "\(signature) -5", "\(signature) 12a", "AAAA 10",
                    "\(signature) 10 extra", "\(signature) 99999999999"] {
            #expect(throws: InstallerError.self) { try InstallerComponents(signatureFile: bad) }
        }
    }

    @Test("Only an archive signed by the key, at the signed length, passes")
    func verify() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("components".utf8)
        let archive = dir.appending(path: "Bridgeplay-Installer.zip")
        try payload.write(to: archive)
        try signed(payload).verify(archive)

        try Data("tampered!!".utf8).write(to: archive)
        #expect(throws: InstallerError.self) { try signed(payload).verify(archive) }
        try Data("longer components".utf8).write(to: archive)
        #expect(throws: InstallerError.self) { try signed(payload).verify(archive) }
    }

    @Test("Needed without GPTK in either support folder, or without Steam")
    func needed() throws {
        let home = try scratch(), apps = try scratch()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: apps) }
        #expect(InstallerComponents.needed(home: home, applications: apps))
        try FileManager.default.createDirectory(at: apps.appending(path: "Steam.app"), withIntermediateDirectories: true)
        #expect(InstallerComponents.needed(home: home, applications: apps))
        let legacy = home.appending(path: "Library/Application Support/notproton/gptk")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(!InstallerComponents.needed(home: home, applications: apps))
        try FileManager.default.removeItem(at: apps.appending(path: "Steam.app"))
        #expect(InstallerComponents.needed(home: home, applications: apps))
    }

    @Test("A failing tool reports its last message, or its exit status when it says nothing")
    func toolFailure() throws {
        func reason(of script: String) throws -> String? {
            let failure = try #require(throws: InstallerError.self) {
                try InstallerComponents.run("/bin/sh", ["-c", script])
            }
            if case .componentsFailure(let reason) = failure { return reason }
            return nil
        }
        #expect(try reason(of: "echo step; echo 'disk full' >&2; echo >&2; exit 1") == "disk full")
        #expect(try reason(of: "exit 3") == "exit 3")
        let output = try InstallerComponents.run("/bin/sh", ["-c", "printf '==> one\\n==> two\\n'"])
        #expect(output == "==> one\n==> two\n")
    }

    @Test("GPTK passes only when D3DMetal.framework and every other Mach-O file are Apple-signed")
    func appleSignedGPTK() throws {
        let gptk = try scratch()
        defer { try? FileManager.default.removeItem(at: gptk) }
        let framework = gptk.appending(path: "external/D3DMetal.framework")
        try FileManager.default.createDirectory(at: framework.appending(path: "Versions/A"), withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0]).write(to: framework.appending(path: "Versions/A/D3DMetal"))
        try FileManager.default.createDirectory(at: gptk.appending(path: "wine/x86_64-windows"), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: gptk.appending(path: "wine/x86_64-windows/d3d11.dll"))
        // Only the framework so far: no other Mach-O file means libd3dshared.dylib is missing.
        #expect(throws: InstallerError.self) { try InstallerComponents.verifyAppleSigned(gptk: gptk) { _ in true } }

        let shared = gptk.appending(path: "external/libd3dshared.dylib")
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0]).write(to: shared)
        var checked: [String] = []
        try InstallerComponents.verifyAppleSigned(gptk: gptk) { checked.append($0.lastPathComponent); return true }
        // The framework as one bundle, then the dylib; the PE file and the framework's insides are skipped.
        #expect(checked == ["D3DMetal.framework", "libd3dshared.dylib"])

        #expect(throws: InstallerError.self) {
            try InstallerComponents.verifyAppleSigned(gptk: gptk) { $0.lastPathComponent != "libd3dshared.dylib" }
        }
        #expect(throws: InstallerError.self) {
            try InstallerComponents.verifyAppleSigned(gptk: gptk) { $0.lastPathComponent != "D3DMetal.framework" }
        }
    }
}
