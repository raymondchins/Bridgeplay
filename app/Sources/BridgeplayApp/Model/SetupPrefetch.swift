import Foundation

// Set Up's downloads, fetched into the caches while Steam is still open. The installs that
// follow find each archive by its pin (PinnedDownload.obtain), so Steam is closed only for
// the local work. Nothing outside the caches is written here.
enum SetupPrefetch {
    struct Pinned: Sendable, Equatable {
        let file: String
        let sha256: String
        let bases: [URL]
        let into: URL
        let step: String
        let source: String
    }

    // The engine and its DXMT archive, and Valve's packages when a bridge file misses its pin,
    // the same test installIntoSteam makes before it fetches them.
    static func files(
        release: WinecxRelease = FreeEngineWinecx.current,
        valve: ValvePackageManifest? = try? ValvePackageManifest.bundled(),
        bridge: URL = SupportPaths.bridge,
        engineCache: URL? = nil,
        rendererCache: URL = FreeEngine.downloads,
        valveCache: URL = SupportPaths.packageDownloads
    ) -> [Pinned] {
        var files = [
            Pinned(file: release.archive, sha256: release.sha256, bases: release.bases,
                   into: engineCache ?? FreeEngineWinecx.downloads(for: release), step: FreeEngineWinecx.step, source: "GitHub"),
            Pinned(file: release.renderer.archive, sha256: release.renderer.sha256, bases: release.renderer.bases,
                   into: rendererCache, step: FreeEngineWinecx.step, source: "GitHub"),
        ]
        if let valve, valve.files.contains(where: { Digest.sha256IfPresent(bridge.appending(path: $0.bridgePath)) != $0.sha256 }) {
            files += valve.packages.map {
                Pinned(file: $0.file, sha256: $0.sha256, bases: valve.bases, into: valveCache, step: ValveFetcher.step, source: "Valve")
            }
        }
        return files
    }

    static func run(
        _ files: [Pinned] = files(),
        obtain: (Pinned) async throws -> Void = { pinned in
            _ = try await PinnedDownload.obtain(file: pinned.file, sha256: pinned.sha256, bases: pinned.bases,
                                                into: pinned.into, step: pinned.step, from: pinned.source)
        }
    ) async throws {
        for file in files {
            try Task.checkCancellation()
            try await obtain(file)
        }
    }
}
