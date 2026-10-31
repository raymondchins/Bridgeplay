// Finds CrossOver installs on disk and checks for support

import Foundation

enum CrossOverSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
    case unreadable
}

struct CrossOverInstall: Sendable, Identifiable {
    let bundle: URL
    let releaseVersion: String?
    let support: CrossOverSupport

    // Selected by the user rather than found on disk by tool.
    var isManual = false

    var id: String { bundle.path(percentEncoded: false) }
    var name: String { bundle.deletingPathExtension().lastPathComponent }
    var crossOverRoot: URL { SupportPaths.crossOverRoot(inBundle: bundle) }

    var isPreview: Bool { name.localizedCaseInsensitiveContains("Preview") }

    var isFree: Bool {
        if case .supported(let build) = support { return build.isFree }
        return false
    }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }
}

enum CrossOverSource {

    static let searchRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    private static let manualKey = "manualCrossOverPaths"
    // 1.0/1.0.1 kept a single chosen copy under this key.
    private static let legacyManualKey = "manualCrossOverPath"

    static func manualBundles(_ defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: manualKey)
            ?? defaults.string(forKey: legacyManualKey).map { [$0] } ?? []
        return paths.filter { !$0.isEmpty }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func setManualBundles(_ bundles: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(bundles.map { $0.path(percentEncoded: false) }, forKey: manualKey)
        defaults.removeObject(forKey: legacyManualKey)
    }

    static func addManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        let current = manualBundles(defaults)
        guard !current.contains(where: { same($0, bundle) }) else { return }
        setManualBundles(current + [bundle], defaults)
    }

    static func removeManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        setManualBundles(manualBundles(defaults).filter { !same($0, bundle) }, defaults)
    }

    static func isSearched(_ bundle: URL) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        return searchRoots.contains { same($0, parent) }
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
    }

    // A CrossOver bundle without this directory is bad!
    static func looksLikeCrossOver(_ bundle: URL) -> Bool {
        let root = SupportPaths.crossOverRoot(inBundle: bundle)
        return FileManager.default.fileExists(
            atPath: root.appending(path: "lib/wine").path(percentEncoded: false)
        )
    }

    static func discover() -> [CrossOverInstall] {
        let fm = FileManager.default
        var found: [CrossOverInstall] = []
        var seen: Set<String> = []

        func consider(_ bundle: URL, isManual: Bool) {
            let key = bundle.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key), looksLikeCrossOver(bundle) else { return }
            seen.insert(key)
            found.append(inspect(bundle: bundle, isManual: isManual))
        }

        for manual in manualBundles() where !isSearched(manual) { consider(manual, isManual: true) }

        for root in searchRoots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app" {
                guard entry.deletingPathExtension().lastPathComponent.hasPrefix("CrossOver") else { continue }
                consider(entry, isManual: false)
            }
        }

        let engines = (try? fm.contentsOfDirectory(at: SupportPaths.engines, includingPropertiesForKeys: nil)) ?? []
        for entry in engines where entry.pathExtension == "app" {
            consider(entry, isManual: false)
        }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: CrossOverInstall, _ b: CrossOverInstall) -> Bool {
        if a.isManual != b.isManual { return a.isManual }
        if a.isUsable != b.isUsable { return a.isUsable }
        if a.isFree != b.isFree { return a.isFree }
        if a.isPreview != b.isPreview { return a.isPreview }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    static func inspect(bundle: URL, isManual: Bool = false) -> CrossOverInstall {
        guard let version = releaseVersion(of: bundle) else {
            return CrossOverInstall(bundle: bundle, releaseVersion: nil, support: .unreadable, isManual: isManual)
        }
        guard let hash = Digest.sha256IfPresent(unixLoader(inBundle: bundle)) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version, support: .unreadable, isManual: isManual
            )
        }

        guard let build = SupportedRunners.build(loaderSHA256: hash) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version,
                support: .unsupportedBuild(version), isManual: isManual
            )
        }

        return CrossOverInstall(
            bundle: bundle, releaseVersion: version, support: .supported(build), isManual: isManual
        )
    }

    // CrossOver puts the build date here and the version number in
    // CFBundleVersion, so this is the string its download page shows.
    static func releaseVersion(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func unixLoader(inBundle bundle: URL) -> URL {
        unixLoader(inRoot: SupportPaths.crossOverRoot(inBundle: bundle))
    }

    static func unixLoader(inRoot root: URL) -> URL {
        root.appending(path: "lib/wine/x86_64-unix/wine")
    }

    static func verifyPatchInputs(root: URL, build: RunnerBuild) throws {
        for arch in WineArch.allCases {
            guard let expected = build.cleanNtdll[arch] else { continue }
            let ntdll = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
            guard let actual = Digest.sha256IfPresent(ntdll) else {
                throw StepFailure(
                    step: String(localized: "Verify CrossOver"),
                    detail: String(localized: "\(arch.rawValue)/ntdll.dll is missing from \(root.path(percentEncoded: false)).")
                )
            }
            guard actual == expected else {
                throw StepFailure(
                    step: String(localized: "Verify CrossOver"),
                    detail: String(localized: "\(arch.rawValue)/\(ntdll.lastPathComponent) is not the build \(build.bundleVersion) copy. Expected \(expected.prefix(16)), found \(actual.prefix(16)).")
                )
            }
        }
    }
}
