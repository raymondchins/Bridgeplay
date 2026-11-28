import Foundation
import Security

// Creates the self-signed code signing identity that SteamInstaller signs Steam with, so
// Steam's designated requirement (and with it the Input Monitoring approval macOS keys to
// it) stays the same across Bridgeplay updates. Without it Steam is signed ad hoc, the
// requirement is the cdhash, and every update makes macOS forget the controller approval.
//
// Design, checked on macOS 27:
// - The identity lives in a keychain of Bridgeplay's own, in the support folder and outside
//   the user's search list, with a random password. A key that `security import` adds,
//   even with `-T /usr/bin/codesign`, carries a partition list codesign is not in, so in the
//   login keychain macOS asked for the login password once per signed file until the user
//   picked Always Allow. Only the keychain's password can change that list, and Bridgeplay
//   knows this one: `set-key-partition-list -S apple-tool:,apple:,codesign:` runs at
//   creation and codesign never asks.
// - The keychain stays locked except while Steam is signed. Its password is a generic
//   password in the login keychain that only Bridgeplay's signature can read, so other
//   processes can't unlock it and sign as Steam (after Always Allow, any process could run
//   codesign with the login keychain key).
// - Macs that already have the identity in the login keychain keep using it: a new
//   certificate would change Steam's requirement and drop the controller approval once more.
// - The key and certificate come from /usr/bin/openssl. The certificate is NOT marked
//   trusted, so the designated requirement is `certificate leaf = H"<sha1>"`.
// - The name stays "NotProton Local Signing": existing installs look it up by that name.
enum LocalSigning {

    static let name = SteamInstaller.localSigningIdentity
    static let step = String(localized: "Trust Bridgeplay on this Mac")

    typealias Runner = @Sendable (String, [String]) throws -> CommandResult

    static let realRunner: Runner = { try Shell.run($0, $1) }

    static var privateKeychain: URL {
        SupportPaths.support.appending(path: "signing/local-signing.keychain-db")
    }

    // Where the identity is: `keychain` is nil for one in the user's search list (the login
    // keychain of older installs), else Bridgeplay's own keychain, passed to codesign.
    struct Identity: Equatable, Sendable {
        let hash: String
        let keychain: URL?
    }

    enum Outcome: Equatable, Sendable {
        case alreadyPresent(hash: String)
        case created(hash: String)
    }

    // The private keychain's password, kept in the login keychain.
    struct Secrets: Sendable {
        var save: @Sendable (String) throws -> Void
        var load: @Sendable () -> String?
        var delete: @Sendable () -> Void

        static let service = "com.bridgeplay.local-signing"

        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: "keychain"]
        }

        static let live = Secrets(
            save: { password in
                SecItemDelete(query as CFDictionary)
                var item = query
                item[kSecAttrLabel as String] = "Bridgeplay signing keychain"
                item[kSecValueData as String] = Data(password.utf8)
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    AppLog.note("signing: saving the keychain password failed: \(status)")
                    throw StepFailure(step: step, detail: String(localized: "macOS did not add the certificate to your keychain."))
                }
            },
            load: {
                var read = query
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(read as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else {
                    if status != errSecItemNotFound { AppLog.note("signing: reading the keychain password failed (\(status))") }
                    return nil
                }
                return String(data: data, encoding: .utf8)
            },
            delete: { SecItemDelete(query as CFDictionary) }
        )
    }

    // `security find-identity -p codesigning` without -v, so an untrusted identity, which
    // is what this creates, still counts. Each line reads `  1) <SHA-1> "<name>" (...)`.
    static func identityHash(in output: String, named wanted: String = name) -> String? {
        for line in output.split(separator: "\n") where line.contains("\"\(wanted)\"") {
            let fields = line.split(separator: " ")
            if let hash = fields.first(where: { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) {
                return String(hash)
            }
        }
        return nil
    }

    // Looks in the given keychains, or in the user's search list when none are given.
    static func existingHash(in keychains: [URL] = [], run: Runner = realRunner) -> String? {
        let arguments = ["find-identity", "-p", "codesigning"] + keychains.map { $0.path(percentEncoded: false) }
        guard let result = try? run("/usr/bin/security", arguments), result.succeeded else { return nil }
        return identityHash(in: result.stdout)
    }

    // An identity from an older install in the search list first, then Bridgeplay's own.
    static func existing(lookIn: [URL] = [], privateKeychain: URL = privateKeychain,
                         run: Runner = realRunner) -> Identity? {
        if let hash = existingHash(in: lookIn, run: run) { return Identity(hash: hash, keychain: nil) }
        guard FileManager.default.fileExists(atPath: privateKeychain.path(percentEncoded: false)),
              let hash = existingHash(in: [privateKeychain], run: run) else { return nil }
        return Identity(hash: hash, keychain: privateKeychain)
    }

    struct Command: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    // The commands that make the identity, in order. The key only ever exists in `work`,
    // which ensure() creates private to this user and removes afterwards.
    static func creationCommands(work: URL, keychain: URL, keychainPassword: String,
                                 transportPassword: String) -> [Command] {
        let key = work.appending(path: "key.pem").path(percentEncoded: false)
        let cert = work.appending(path: "cert.pem").path(percentEncoded: false)
        let bundle = work.appending(path: "identity.p12").path(percentEncoded: false)
        let path = keychain.path(percentEncoded: false)
        return [
            Command(executable: "/usr/bin/security", arguments: ["create-keychain", "-p", keychainPassword, path]),
            Command(executable: "/usr/bin/openssl", arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "7300",
                "-subj", "/CN=\(name)",
                "-addext", "extendedKeyUsage=critical,codeSigning",
                "-addext", "keyUsage=critical,digitalSignature",
                "-addext", "basicConstraints=critical,CA:false",
                "-keyout", key, "-out", cert,
            ]),
            // security import refuses a PKCS#12 with an empty password, so the bundle gets a
            // random one that lives only as long as the file.
            Command(executable: "/usr/bin/openssl", arguments: [
                "pkcs12", "-export", "-inkey", key, "-in", cert, "-name", name,
                "-out", bundle, "-passout", "pass:\(transportPassword)",
            ]),
            Command(executable: "/usr/bin/security", arguments: ["unlock-keychain", "-p", keychainPassword, path]),
            Command(executable: "/usr/bin/security", arguments: [
                "import", bundle, "-k", path, "-f", "pkcs12", "-P", transportPassword, "-T", "/usr/bin/codesign",
            ]),
            Command(executable: "/usr/bin/security", arguments: [
                "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychainPassword, path,
            ]),
            Command(executable: "/usr/bin/security", arguments: ["lock-keychain", path]),
        ]
    }

    // Creates the identity unless one is already there. Never asks for a password.
    static func ensure(
        privateKeychain: URL = privateKeychain,
        lookIn: [URL] = [],
        run: Runner = realRunner,
        secrets: Secrets = .live,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> Outcome {
        if let identity = existing(lookIn: lookIn, privateKeychain: privateKeychain, run: run) {
            return .alreadyPresent(hash: identity.hash)
        }
        let files = FileManager.default
        let work = temporaryRoot.appending(path: "bridgeplay-signing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: work, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }
        try files.createDirectory(at: privateKeychain.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        // A keychain left by a failed attempt has a password nobody kept.
        try? files.removeItem(at: privateKeychain)

        let password = randomPassword()
        try secrets.save(password)
        var created = false
        do {
            for command in creationCommands(work: work, keychain: privateKeychain, keychainPassword: password,
                                            transportPassword: UUID().uuidString) {
                let result = try run(command.executable, command.arguments)
                guard result.succeeded else {
                    let tool = (command.executable as NSString).lastPathComponent
                    AppLog.note("signing: \(tool) \(command.arguments.first ?? "") failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                    throw StepFailure(step: step, detail: String(localized: "macOS did not add the certificate to your keychain."))
                }
                if command.arguments.first == "create-keychain" {
                    created = true
                    leaveSearchList(privateKeychain, run: run)
                }
            }
            guard let hash = existingHash(in: [privateKeychain], run: run) else {
                throw StepFailure(step: step, detail: String(localized: "The certificate was added, but macOS does not offer it for signing."))
            }
            AppLog.note("signing: created \(name) \(hash) in Bridgeplay's keychain")
            return .created(hash: hash)
        } catch {
            if created { _ = try? run("/usr/bin/security", ["delete-keychain", privateKeychain.path(percentEncoded: false)]) }
            try? files.removeItem(at: privateKeychain)
            secrets.delete()
            throw error
        }
    }

    // Some macOS versions add a new keychain to the user's search list. A locked keychain
    // there could make other apps ask for a password the user never set, so it comes out.
    // Every other entry is passed back as it was, one argument each.
    static func leaveSearchList(_ keychain: URL, run: Runner = realRunner) {
        guard let result = try? run("/usr/bin/security", ["list-keychains", "-d", "user"]), result.succeeded else { return }
        let ours = keychain.resolvingSymlinksInPath().path(percentEncoded: false)
        let entries = result.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        let others = entries.filter { URL(filePath: $0).resolvingSymlinksInPath().path(percentEncoded: false) != ours }
        guard others.count == entries.count - 1, !others.isEmpty else { return }
        _ = try? run("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + others)
    }

    // Runs `body` with Bridgeplay's keychain unlocked and locks it again after. `body` gets
    // the identity to sign with: nil when the keychain can't be unlocked, so Steam is signed
    // ad hoc. codesign must never meet that keychain locked: on macOS 27 an attempt leaves it
    // refusing its own password afterwards. An identity in the search list needs nothing, but
    // codesign may ask to use its key, and a run with prompts off has nobody to answer: it signs
    // ad hoc instead.
    static func unlocked<T>(_ identity: Identity?, secrets: Secrets = .live, promptsAllowed: () -> Bool = promptsAllowed,
                            _ body: (Identity?) throws -> T) rethrows -> T {
        guard let identity else { return try body(nil) }
        guard let path = identity.keychain?.path(percentEncoded: false) else {
            guard promptsAllowed() else {
                AppLog.note("signing: the login keychain's identity may ask for approval and nobody is watching, signing ad hoc")
                return try body(nil)
            }
            return try body(identity)
        }
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain, let password = secrets.load() else {
            AppLog.note("signing: Bridgeplay's keychain or its password is missing, signing ad hoc")
            return try body(nil)
        }
        let bytes = Array(password.utf8)
        let status = SecKeychainUnlock(keychain, UInt32(bytes.count), bytes, true)
        var state: SecKeychainStatus = 0
        guard status == errSecSuccess, SecKeychainGetStatus(keychain, &state) == errSecSuccess,
              state & UInt32(kSecUnlockStateStatus) != 0 else {
            AppLog.note("signing: unlocking Bridgeplay's keychain failed (\(status)), signing ad hoc")
            return try body(nil)
        }
        defer { SecKeychainLock(keychain) }
        return try body(identity)
    }

    // Only the build that saved the keychain password reads it without asking. Any other build,
    // a local test build for one, gets a macOS prompt, and a run nobody watches (a script, the
    // background check) waited on it forever behind a locked screen. With prompts off the read
    // fails at once and Steam is signed ad hoc, as when the password is missing.
    // kSecUseAuthenticationUIFail does not cover this prompt; this switch does (macOS 27).
    static func allowPrompts(_ allowed: Bool) {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    static func promptsAllowed() -> Bool {
        var allowed: DarwinBoolean = true
        return SecKeychainGetUserInteractionAllowed(&allowed) != errSecSuccess || allowed.boolValue
    }

    // Uninstall: the keychain file goes with the support folder, its password goes here.
    static func forgetPrivateKeychain(secrets: Secrets = .live) {
        secrets.delete()
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
