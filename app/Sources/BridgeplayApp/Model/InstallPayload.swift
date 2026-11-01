// Deploys core Bridgeplay components into the copy of CrossOver that Bridgeplay deploys to the Steam location

import Foundation

enum InstallPayload {
    static let step = String(localized: "Find Bridgeplay's components")

    struct Located: Sendable {
        let dylib: URL
        let overlayShim: URL
        let iconmaker: URL
        let appinfo: URL
        let gamefixPrep: URL
        let run: URL
        let builtAt: Int64

        let signatures: [URL]
        let fontsRoot: URL
        let fonts: [String]
        // payload/gamefixes/*.conf, installed into SupportPaths.gamefixesDefault.
        var gamefixes: [URL] = []
    }

    static func root(in bundle: Bundle = .module) throws -> URL {
        guard let url = bundle.url(forResource: "payload", withExtension: nil) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "This build of Bridgeplay carries no components at all.")
            )
        }
        return url
    }

    static func locate(in bundle: Bundle = .module) throws -> Located {
        try locate(root: try root(in: bundle))
    }

    static func locateGamefixes(in root: URL) throws -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: "gamefixes"), includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "conf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func locate(root: URL) throws -> Located {
        let files = FileManager.default

        let dylib = root.appending(path: SupportPaths.dylibName)
        let shim = root.appending(path: "overlay-shim.dylib")
        let iconmaker = root.appending(path: "iconmaker")
        let appinfo = root.appending(path: "appinfo")
        let gamefixPrep = root.appending(path: "gamefix-prep")
        let run = root.appending(path: "run")
        let stamp = try? String(contentsOf: root.appending(path: "build-time"), encoding: .utf8)
        let builtAt = stamp.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var missing: [String] = []
        if !files.fileExists(atPath: dylib.path(percentEncoded: false)) {
            missing.append(SupportPaths.dylibName)
        }
        if !files.fileExists(atPath: shim.path(percentEncoded: false)) {
            missing.append("overlay-shim.dylib")
        }
        if !files.fileExists(atPath: iconmaker.path(percentEncoded: false)) {
            missing.append("iconmaker")
        }
        if !files.fileExists(atPath: appinfo.path(percentEncoded: false)) {
            missing.append("appinfo")
        }
        if !files.isExecutableFile(atPath: gamefixPrep.path(percentEncoded: false)) {
            missing.append("gamefix-prep")
        }
        if !files.fileExists(atPath: run.path(percentEncoded: false)) { missing.append("run") }
        if (builtAt ?? 0) <= 0 { missing.append("build-time") }

        let signatureDir = root.appending(path: "signatures/macos.arm64")
        let signatures = ((try? files.contentsOfDirectory(
            at: signatureDir, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if signatures.isEmpty { missing.append("signatures/macos.arm64/*.json") }

        let fontsRoot = root.appending(path: "fonts")
        let fonts = (files.subpaths(atPath: fontsRoot.path(percentEncoded: false)) ?? [])
            .filter { $0.hasSuffix(".ttf") || $0.hasSuffix(".ttc") }.sorted()
        if fonts.isEmpty { missing.append("fonts") }

        guard missing.isEmpty, let builtAt, builtAt > 0 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "These components are missing: \(missing.joined(separator: ", ")). Run make app-payload and build the app again.")
            )
        }

        let gamefixes = try locateGamefixes(in: root)

        return Located(
            dylib: dylib, overlayShim: shim, iconmaker: iconmaker,
            appinfo: appinfo, gamefixPrep: gamefixPrep, run: run,
            builtAt: builtAt, signatures: signatures,
            fontsRoot: fontsRoot, fonts: fonts,
            gamefixes: gamefixes
        )
    }
}
