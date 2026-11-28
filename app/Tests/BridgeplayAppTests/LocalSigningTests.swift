import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Local signing identity")
struct LocalSigningTests {

    // What `security find-identity -p codesigning` printed on a Mac carrying the identity,
    // untrusted, next to another one.
    private static let listing = """

    Policy: Code Signing
      Matching identities
      1) 1111111111111111111111111111111111111111 "Apple Development: someone@example.com (ABCDE12345)"
      2) E9B6B93497770DB40F9E30E511810EC68B9D4D93 "NotProton Local Signing" (CSSMERR_TP_NOT_TRUSTED)
         2 identities found

      Valid identities only
      1) 1111111111111111111111111111111111111111 "Apple Development: someone@example.com (ABCDE12345)"
         1 valid identities found
    """

    // Records every command and answers find-identity from a script of listings.
    private final class FakeSecurity: @unchecked Sendable {
        private let lock = NSLock()
        private var listings: [String]
        private(set) var commands: [[String]] = []
        var failing: String?

        init(listings: [String]) { self.listings = listings }

        var runner: LocalSigning.Runner {
            { executable, arguments in
                self.lock.lock(); defer { self.lock.unlock() }
                self.commands.append([executable] + arguments)
                if arguments.first == "find-identity" {
                    let next = self.listings.count > 1 ? self.listings.removeFirst() : (self.listings.first ?? "")
                    return CommandResult(status: 0, stdout: next, stderr: "")
                }
                if let failing = self.failing, arguments.first == failing {
                    return CommandResult(status: 1, stdout: "", stderr: "refused")
                }
                return CommandResult(status: 0, stdout: "", stderr: "")
            }
        }

        var created: [[String]] { commands.filter { $0[1] != "find-identity" } }
    }

    @Test("The identity is found by name even when macOS does not trust it")
    func findsUntrustedIdentity() {
        #expect(LocalSigning.identityHash(in: Self.listing) == "E9B6B93497770DB40F9E30E511810EC68B9D4D93")
        #expect(LocalSigning.identityHash(in: Self.listing, named: "Someone Else") == nil)
        #expect(LocalSigning.identityHash(in: "\n     0 valid identities found\n") == nil)
    }

    @Test("The installer keeps signing with the same name")
    func keepsTheExistingName() {
        #expect(LocalSigning.name == "NotProton Local Signing")
        #expect(SteamInstaller.localSigningIdentity == LocalSigning.name)
    }

    @Test("An existing identity is kept and nothing is created")
    func idempotent() throws {
        let fake = FakeSecurity(listings: [Self.listing])
        let outcome = try LocalSigning.ensure(run: fake.runner)
        #expect(outcome == .alreadyPresent(hash: "E9B6B93497770DB40F9E30E511810EC68B9D4D93"))
        #expect(fake.created.isEmpty)
        #expect(fake.commands == [["/usr/bin/security", "find-identity", "-p", "codesigning"]])
    }

    private final class MemorySecrets: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? { lock.withLock { stored } }
        var secrets: LocalSigning.Secrets {
            LocalSigning.Secrets(save: { value in self.lock.withLock { self.stored = value } },
                                 load: { self.lock.withLock { self.stored } },
                                 delete: { self.lock.withLock { self.stored = nil } })
        }
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "signing-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A missing identity goes into Bridgeplay's own keychain, with codesign in its partition list")
    func createsWhenMissing() throws {
        let temporary = try directory("work")
        let home = try directory("home")
        defer { try? FileManager.default.removeItem(at: temporary); try? FileManager.default.removeItem(at: home) }
        let keychain = home.appending(path: "signing/local-signing.keychain-db")
        let fake = FakeSecurity(listings: ["  0 identities found\n", Self.listing])
        let memory = MemorySecrets()

        let outcome = try LocalSigning.ensure(privateKeychain: keychain, run: fake.runner, secrets: memory.secrets,
                                              temporaryRoot: temporary)

        #expect(outcome == .created(hash: "E9B6B93497770DB40F9E30E511810EC68B9D4D93"))
        let steps = fake.created.filter { $0[1] != "list-keychains" }
        #expect(steps.map { "\(($0[0] as NSString).lastPathComponent) \($0[1])" } == [
            "security create-keychain", "openssl req", "openssl pkcs12", "security unlock-keychain",
            "security import", "security set-key-partition-list", "security lock-keychain",
        ])
        #expect(steps[1].contains("/CN=NotProton Local Signing"))
        #expect(steps[1].contains("keyUsage=critical,digitalSignature"))
        let password = try #require(memory.value)
        #expect(steps[0].contains(password) && steps[3].contains(password) && steps[5].contains(password))
        #expect(steps[5].firstIndex(of: "-S").map { steps[5][$0 + 1] } == "apple-tool:,apple:,codesign:")
        #expect(steps[4].firstIndex(of: "-T").map { steps[4][$0 + 1] } == "/usr/bin/codesign")
        #expect(steps.allSatisfy { $0.contains(keychain.path(percentEncoded: false)) || $0[0] == "/usr/bin/openssl" })
        // No trust settings change, nothing in the login keychain but the password.
        #expect(!fake.commands.joined().contains("add-trusted-cert"))
        // The private key never outlives the call.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false)).isEmpty)
    }

    @Test("A keychain without its password signs ad hoc instead of meeting codesign locked")
    func missingPasswordFallsBack() throws {
        let identity = LocalSigning.Identity(hash: "E9B6B93497770DB40F9E30E511810EC68B9D4D93",
                                             keychain: URL(filePath: "/nonexistent/k.keychain-db"))
        let nothing = LocalSigning.Secrets(save: { _ in }, load: { nil }, delete: {})
        #expect(LocalSigning.unlocked(identity, secrets: nothing) { $0 } == nil)
        let login = LocalSigning.Identity(hash: identity.hash, keychain: nil)
        #expect(LocalSigning.unlocked(login, secrets: nothing, promptsAllowed: { true }) { $0 } == login)
    }

    @Test("With prompts off, a login keychain identity signs ad hoc rather than let codesign ask")
    func unattendedSkipsLoginIdentity() {
        let login = LocalSigning.Identity(hash: "E9B6B93497770DB40F9E30E511810EC68B9D4D93", keychain: nil)
        let nothing = LocalSigning.Secrets(save: { _ in }, load: { nil }, delete: {})
        #expect(LocalSigning.unlocked(login, secrets: nothing, promptsAllowed: { false }) { $0 } == nil)
        #expect(LocalSigning.unlocked(nil, secrets: nothing, promptsAllowed: { true }) { $0 } == nil)
    }

    @Test("An older install's identity in the login keychain is kept")
    func keepsLoginKeychainIdentity() throws {
        let fake = FakeSecurity(listings: [Self.listing])
        let identity = LocalSigning.existing(privateKeychain: URL(filePath: "/nonexistent/k.keychain-db"), run: fake.runner)
        #expect(identity == LocalSigning.Identity(hash: "E9B6B93497770DB40F9E30E511810EC68B9D4D93", keychain: nil))
    }

    @Test("The PKCS#12 password matches between export and import")
    func transportPasswordMatches() {
        let commands = LocalSigning.creationCommands(work: URL(filePath: "/w"), keychain: URL(filePath: "/k"),
                                                     keychainPassword: "kc", transportPassword: "secret")
        #expect(commands[2].arguments.contains("pass:secret"))
        #expect(commands[4].arguments.firstIndex(of: "-P").map { commands[4].arguments[$0 + 1] } == "secret")
    }

    @Test("Only Bridgeplay's keychain leaves the search list, every other entry stays as it was")
    func leavesSearchList() {
        let ours = URL(filePath: "/Users/x/Library/Application Support/bridgeplay/signing/local-signing.keychain-db")
        let fake = FakeSecurity(listings: [])
        let listing = """
            "/Users/x/Library/Keychains/login.keychain-db"
            "/Users/x/Library/Application Support/bridgeplay/signing/local-signing.keychain-db"
            "/Users/x/Library/Keychains/other one.keychain-db"
        """
        let runner: LocalSigning.Runner = { executable, arguments in
            _ = try fake.runner(executable, arguments)
            return CommandResult(status: 0, stdout: arguments.contains("-s") ? "" : listing, stderr: "")
        }
        LocalSigning.leaveSearchList(ours, run: runner)
        #expect(fake.commands.last == ["/usr/bin/security", "list-keychains", "-d", "user", "-s",
                                       "/Users/x/Library/Keychains/login.keychain-db",
                                       "/Users/x/Library/Keychains/other one.keychain-db"])

        let untouched = FakeSecurity(listings: [])
        LocalSigning.leaveSearchList(URL(filePath: "/elsewhere.keychain-db")) { executable, arguments in
            _ = try untouched.runner(executable, arguments)
            return CommandResult(status: 0, stdout: listing, stderr: "")
        }
        #expect(untouched.commands.count == 1)
    }

    @Test("A refused import is reported and leaves no key, keychain or password behind")
    func refusedImport() throws {
        let temporary = try directory("work")
        let home = try directory("home")
        defer { try? FileManager.default.removeItem(at: temporary); try? FileManager.default.removeItem(at: home) }
        let keychain = home.appending(path: "signing/local-signing.keychain-db")
        let fake = FakeSecurity(listings: [""])
        fake.failing = "import"
        let memory = MemorySecrets()

        #expect(throws: StepFailure.self) {
            try LocalSigning.ensure(privateKeychain: keychain, run: fake.runner, secrets: memory.secrets, temporaryRoot: temporary)
        }
        #expect(memory.value == nil)
        #expect(!FileManager.default.fileExists(atPath: keychain.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false)).isEmpty)
    }

    // Uses the real tools against a throwaway keychain and signs a copy of /bin/echo: proves
    // codesign uses the identity without a prompt. Off by default because a prompt would hang the run.
    @Test("A real identity in Bridgeplay's keychain signs without a prompt",
          .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_KEYCHAIN_TEST"] != nil))
    func realKeychain() throws {
        let work = try directory("real")
        defer { try? FileManager.default.removeItem(at: work) }
        let keychain = work.appending(path: "signing/local-signing.keychain-db")
        let nowhere = work.appending(path: "none.keychain-db")
        let memory = MemorySecrets()
        let searchList = try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).stdout

        let first = try LocalSigning.ensure(privateKeychain: keychain, lookIn: [nowhere], secrets: memory.secrets)
        defer { _ = try? Shell.run("/usr/bin/security", ["delete-keychain", keychain.path(percentEncoded: false)]) }
        guard case .created(let hash) = first else { Issue.record("expected a new identity, got \(first)"); return }
        #expect(try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).stdout == searchList)
        #expect(try LocalSigning.ensure(privateKeychain: keychain, lookIn: [nowhere], secrets: memory.secrets) == .alreadyPresent(hash: hash))
        let identity = try #require(LocalSigning.existing(lookIn: [nowhere], privateKeychain: keychain))

        let binary = work.appending(path: "echo")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: binary)
        try LocalSigning.unlocked(identity, secrets: memory.secrets) { unlocked in
            #expect(unlocked == identity)
            try Shell.check("/usr/bin/codesign", ["-f", "-s", hash, "--keychain", keychain.path(percentEncoded: false),
                                                  binary.path(percentEncoded: false)])
        }
        let requirement = try Shell.run("/usr/bin/codesign", ["-d", "-r-", binary.path(percentEncoded: false)])
        #expect((requirement.stdout + requirement.stderr).lowercased().contains("h\"\(hash.lowercased())\""))
    }

    // A password saved by another program (here `security`, the only app its ACL names) is
    // what a test build meets: with prompts on, macOS asks and the read waits for an answer.
    // With prompts off it must fail at once, so an unattended install signs ad hoc instead.
    @Test("With prompts off, a password another program saved is refused at once",
          .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_KEYCHAIN_TEST"] != nil))
    func refusedWithoutPrompt() throws {
        let work = try directory("prompt")
        defer { try? FileManager.default.removeItem(at: work) }
        let keychain = work.appending(path: "other.keychain-db").path(percentEncoded: false)
        try Shell.check("/usr/bin/security", ["create-keychain", "-p", "kc", keychain])
        defer { _ = try? Shell.run("/usr/bin/security", ["delete-keychain", keychain]) }
        LocalSigning.leaveSearchList(URL(filePath: keychain))
        try Shell.check("/usr/bin/security", ["unlock-keychain", "-p", "kc", keychain])
        try Shell.check("/usr/bin/security", ["add-generic-password", "-s", LocalSigning.Secrets.service,
                                              "-a", "keychain", "-w", "secret", keychain])

        var opened: SecKeychain?
        #expect(SecKeychainOpen(keychain, &opened) == errSecSuccess)
        let read: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: LocalSigning.Secrets.service,
                                   kSecAttrAccount as String: "keychain",
                                   kSecMatchSearchList as String: [try #require(opened)],
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        LocalSigning.allowPrompts(false)
        defer { LocalSigning.allowPrompts(true) }
        let started = Date()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        #expect(status != errSecSuccess)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
