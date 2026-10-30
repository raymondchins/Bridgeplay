// Patcher logic

import Foundation

enum RunnerPatcher {

    static let step = String(localized: "Patch the compatibility tool")

    private static let dyldEntitlement = "com.apple.security.cs.allow-dyld-environment-variables"

    static let windowsBuiltins = [
        (arch: "i386-windows", name: "lsteamclient.dll"),
        (arch: "x86_64-windows", name: "lsteamclient.dll"),
    ]

    static func builtins(in root: URL) -> [(arch: String, name: String)] {
        windowsBuiltins + unixArches(in: root).map { (arch: $0, name: "lsteamclient.so") }
    }

    static func unixArches(in root: URL) -> [String] {
        let arches = unixLoaders(in: root).compactMap { loader in
            loader.pathComponents.last { $0.hasSuffix("-unix") }
        }
        let present = ["aarch64-unix", "x86_64-unix"].filter { arches.contains($0) }
        return present.isEmpty ? ["x86_64-unix"] : present
    }

    struct Outcome: Sendable {
        var ntdll: [WineArch] = []
        var builtins: [String] = []
        var loaders: [String] = []

        var wroteNothing: Bool { ntdll.isEmpty && builtins.isEmpty && loaders.isEmpty }
    }

    static func install(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) throws -> Outcome {
        var outcome = Outcome()
        outcome.ntdll = try installNtdll(build: build, root: root, bridge: bridge)
        outcome.builtins = try installBuiltins(root: root, bridge: bridge)
        outcome.loaders = try grantLoaderEntitlement(root: root)
        return outcome
    }

    static func verify(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) -> [String] {
        var wrong: [String] = []
        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let live = root.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
            guard let actual = Digest.sha256IfPresent(live) else {
                wrong.append(String(localized: "\(arch.rawValue)/ntdll.dll is missing"))
                continue
            }
            if actual != expected {
                wrong.append(String(localized: "\(arch.rawValue)/ntdll.dll is not the patched copy"))
            }
        }
        for builtin in builtins(in: root) {
            let installed = Digest.sha256IfPresent(
                root.appending(path: "lib/wine/\(builtin.arch)/\(builtin.name)"))
            guard let installed else {
                wrong.append(String(localized: "\(builtin.arch)/\(builtin.name) is missing"))
                continue
            }

            let staged = Digest.sha256IfPresent(
                bridge.appending(path: "\(builtin.arch)/\(builtin.name)"))
            if let staged, staged != installed {
                wrong.append(String(localized: "\(builtin.arch)/\(builtin.name) is out of date"))
            }
        }

        for loader in unixLoaders(in: root) where isHardened(loader) {
            let granted = entitlements(of: loader)
            if granted?.contains(restrictedEntitlement) == true {
                if !signatureIsValid(signingTarget(for: loader)) {
                    wrong.append(String(localized: "\(name(of: loader)) has a broken signature"))
                }
            } else if granted?.contains(dyldEntitlement) != true {
                wrong.append(String(localized: "\(name(of: loader)) is missing the dyld entitlement"))
            }
        }

        return wrong
    }

    private static func installNtdll(
        build: RunnerBuild, root: URL, bridge: URL
    ) throws -> [WineArch] {
        var installed: [WineArch] = []

        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let staged = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)

            guard Digest.sha256IfPresent(staged) == expected else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "The patched \(arch.rawValue) ntdll has not been copied into place.")
                )
            }

            let live = root.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
            if Digest.sha256IfPresent(live) == expected { continue }

            try keepClean(live)
            try atomicReplace(live, with: Data(contentsOf: staged), step: step)
            installed.append(arch)
        }

        return installed
    }

    private static func installBuiltins(root: URL, bridge: URL) throws -> [String] {
        var installed: [String] = []

        for builtin in builtins(in: root) {
            let source = bridge.appending(path: "\(builtin.arch)/\(builtin.name)")
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(builtin.arch)/\(builtin.name) is not in the bridge. Install Bridgeplay first.")
                )
            }

            let destination = root.appending(path: "lib/wine/\(builtin.arch)/\(builtin.name)")
            if Digest.sha256IfPresent(source) == Digest.sha256IfPresent(destination) { continue }

            try atomicReplace(destination, with: Data(contentsOf: source), step: step)
            installed.append("\(builtin.arch)/\(builtin.name)")
        }

        return installed
    }

    private static func grantLoaderEntitlement(root: URL) throws -> [String] {
        var signed: [String] = []

        for loader in unixLoaders(in: root) where isHardened(loader) {
            let existing = entitlements(of: loader)
            if existing?.contains(restrictedEntitlement) == true { continue }
            if existing?.contains(dyldEntitlement) == true,
               signatureIsValid(signingTarget(for: loader)) { continue }

            guard let existing, !existing.isEmpty else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(name(of: loader)) carries no entitlements to extend.")
                )
            }

            do {
                try sign(loader, addingTo: existing)
            } catch {
                restoreClean(loader)
                throw error
            }
            signed.append(name(of: loader))
        }

        return signed
    }

    static func unixLoaders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let wine = root.appending(path: "lib/wine")
        let entries = (try? fm.contentsOfDirectory(at: wine, includingPropertiesForKeys: nil)) ?? []

        return entries
            .filter { $0.lastPathComponent.hasSuffix("-unix") }
            .flatMap { [$0.appending(path: "wine"), $0.appending(path: "wine.app/Contents/MacOS/wine")] }
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
            .sorted { $0.path < $1.path }
    }

    static func name(of loader: URL) -> String {
        let parts = loader.pathComponents
        guard let arch = parts.lastIndex(where: { $0.hasSuffix("-unix") }) else {
            return loader.lastPathComponent
        }
        return parts[arch...].joined(separator: "/")
    }

    private static func entitlements(of loader: URL) -> String? {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["-d", "--entitlements", ":-", loader.path(percentEncoded: false)]
        ), result.status == 0 else { return nil }
        return result.stdout
    }

    private static func sign(_ loader: URL, addingTo existing: String) throws {
        let plist = FileManager.default.temporaryDirectory
            .appending(path: "np-entitlements-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plist) }

        try Data(existing.utf8).write(to: plist)
        _ = try Shell.run("/usr/libexec/PlistBuddy", [
            "-c", "Add :\(dyldEntitlement) bool true", plist.path(percentEncoded: false),
        ])

        try keepClean(loader)
        let target = signingTarget(for: loader)
        let result = try Shell.run("/usr/bin/codesign", [
            "-f", "-s", "-", "--options", "runtime",
            "--entitlements", plist.path(percentEncoded: false),
            target.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }


        guard entitlements(of: loader)?.contains(dyldEntitlement) == true else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(name(of: loader)) was re-signed without the dyld entitlement.")
            )
        }
    }

    private static func signingTarget(for loader: URL) -> URL {
        enclosingBundle(of: loader) ?? loader
    }

    private static func enclosingBundle(of loader: URL) -> URL? {
        var candidate = loader.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    // WineHQ's loader is ad hoc signed without the hardened runtime, so dyld already
    // honours the DYLD_* variables and there is nothing to grant. Re-signing it
    // with the runtime on would take away the JIT and library freedoms Wine needs.
    static func isHardened(_ loader: URL) -> Bool {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["-dv", signingTarget(for: loader).path(percentEncoded: false)]
        ) else { return true }
        let described = result.stderr + result.stdout
        // An unsigned loader (WineCX ships one) has no hardened runtime, so dyld already
        // honours DYLD_* and there is nothing to extend.
        if result.status != 0 { return !described.contains("not signed at all") }
        return described.split(separator: "\n").contains {
            $0.hasPrefix("CodeDirectory") && $0.contains("runtime")
        }
    }

    static let restrictedEntitlement = "com.apple.developer.cross-architecture-support"

    private static func signatureIsValid(_ target: URL) -> Bool {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["--verify", "--strict", target.path(percentEncoded: false)]
        ) else { return false }
        return result.status == 0
    }

    static func keepClean(_ file: URL, cp: String = "/bin/cp") throws {
        let backup = Clean.copy(of: file)
        guard backup == file else { return }

        let destination = file.appendingPathExtension(Clean.backupSuffix)
        let staging = file.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).new")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try Shell.run(cp, [
            "-p", file.path(percentEncoded: false), staging.path(percentEncoded: false),
        ])
        guard result.status == 0,
            rename(staging.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0
        else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Keeping the shipped \(file.lastPathComponent) failed. ")
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func restoreClean(_ file: URL) {
        let backup = file.appendingPathExtension(Clean.backupSuffix)
        guard FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        _ = try? Shell.run("/bin/cp", [
            "-p", backup.path(percentEncoded: false), file.path(percentEncoded: false),
        ])
    }

}
