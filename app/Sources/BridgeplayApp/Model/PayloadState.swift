// Checks files on disk versus the manifest, presents state to user

import Foundation

struct PayloadState: Sendable {
    var expected: Int
    var present: Int
    var missing: [PayloadEntry]
    var overlayShimPresent: Bool
    var iconmakerPresent: Bool
    var appinfoPresent: Bool
    var gamefixPrepPresent: Bool
    var signatureDatabase: String?
    var legacyCompatPresent: Int
    var legacyCompatExpected: Int
    var manifestProblem: String?

    var isSteamComplete: Bool {
        manifestProblem == nil && missingSteamFiles.isEmpty && signatureDatabase != nil
    }

    var missingSteamFiles: [String] {
        var names = missing(origin: .built).map(\.path)
        if !overlayShimPresent { names.append("overlay-shim.dylib") }
        if !iconmakerPresent { names.append("iconmaker") }
        if !appinfoPresent { names.append("appinfo") }
        if !gamefixPrepPresent { names.append("gamefix-prep") }
        return names
    }

    var isComplete: Bool {
        isSteamComplete && missing.isEmpty
    }

    var isEmpty: Bool {
        present == 0 && !overlayShimPresent && !iconmakerPresent && !appinfoPresent
            && !gamefixPrepPresent && signatureDatabase == nil
    }

    func missing(origin: PayloadOrigin) -> [PayloadEntry] {
        missing.filter { $0.origin == origin }
    }
}

enum PayloadInspector {

    static func inspect(
        bridge: URL = SupportPaths.bridge, builds: [RunnerBuild] = RunnerStore.installedBuilds()
    ) -> PayloadState {
        let fm = FileManager.default

        var expected = 0
        var missing: [PayloadEntry] = []
        var problem: String?

        do {
            let manifest = try PayloadManifest.bundled()
            let entries = manifest.entries.flatMap { expand($0, for: builds) }
            expected = entries.count
            missing = entries.filter {
                !fm.fileExists(atPath: bridge.appending(path: $0.path).path(percentEncoded: false))
            }
        } catch {
            problem = error.localizedDescription
        }

        let legacyNames = ((try? ValvePackageManifest.bundled())?.files ?? [])
            .filter { $0.bridgePath.hasPrefix("legacycompat/") }
            .map { URL(filePath: $0.bridgePath).lastPathComponent }
        let legacyPresent = legacyNames.filter {
            fm.fileExists(
                atPath: SupportPaths.Steam.legacyCompat
                    .appending(path: $0).path(percentEncoded: false)
            )
        }.count

        return PayloadState(
            expected: expected,
            present: expected - missing.count,
            missing: missing,
            overlayShimPresent: fm.fileExists(atPath: SupportPaths.overlayShim.path(percentEncoded: false)),
            iconmakerPresent: fm.fileExists(atPath: SupportPaths.iconmaker.path(percentEncoded: false)),
            appinfoPresent: fm.fileExists(atPath: SupportPaths.appinfo.path(percentEncoded: false)),
            gamefixPrepPresent: fm.isExecutableFile(atPath: SupportPaths.gamefixPrep.path(percentEncoded: false)),
            signatureDatabase: newestSignatureDatabase(),
            legacyCompatPresent: legacyPresent,
            legacyCompatExpected: legacyNames.count,
            manifestProblem: problem
        )
    }

    private static func expand(_ entry: PayloadEntry, for builds: [RunnerBuild]) -> [PayloadEntry] {
        guard entry.origin == .patched,
              let arch = WineArch.allCases.first(where: {
                  entry.path == "wine/\($0.rawValue)/ntdll.dll"
              })
        else { return [entry] }
        return builds.filter { $0.patchedNtdll[arch] != nil }.map {
            PayloadEntry(origin: .patched, path: "wine/\($0.id)/\(arch.rawValue)/ntdll.dll")
        }
    }

    static func newestSignatureDatabase(in directory: URL = SupportPaths.signatures) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .map(\.lastPathComponent)
            .compactMap { name -> (name: String, build: UInt64)? in
                guard name.hasSuffix(".json"),
                      let build = UInt64(name.dropLast(5)), build > 0
                else { return nil }
                return (name, build)
            }
            .max { $0.build < $1.build }?
            .name
    }
}
