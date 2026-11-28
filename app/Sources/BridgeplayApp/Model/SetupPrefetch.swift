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
        // A file Setup can do without (the restore bundle): a failed download is logged, not fatal.
        var optional = false
    }

    // The engine and its DXMT archive, Valve's packages when a bridge file misses its pin,
    // the same test installIntoSteam makes before it fetches them.
    static func files(
        release: WinecxRelease = FreeEngineWinecx.current,
        valve: ValvePackageManifest? = try? ValvePackageManifest.bundled(),
        bridge: URL = SupportPaths.bridge,
        engineCache: URL? = nil,
        rendererCache: URL = FreeEngine.downloads,
        valveCache: URL = SupportPaths.packageDownloads,
        kept: URL = SupportPaths.steamRestore
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
        // Valve's restore bundle, which installIntoSteam keeps (SteamRepair.keepForOffline) after
        // Steam quits. It lands in the kept folder, so that step finds it; a copy already kept or
        // cached is a local move and needs no download.
        if let valve, let bundle = valve.bundle,
           SteamRepair.keptArchive(bundle, in: kept) == nil,
           Digest.sha256IfPresent(valveCache.appending(path: bundle.file)) != bundle.sha256 {
            files.append(Pinned(file: bundle.file, sha256: bundle.sha256, bases: valve.bases, into: kept,
                                step: SteamRepair.step, source: "Valve", optional: true))
        }
        return files
    }

    // Set Up has at most five files on two hosts (GitHub, Valve's CDN), so all of them start
    // at once and the bar has its total within a second.
    static let parallel = 4

    // Fetches every file, `limit` at a time. The first failure cancels the rest; their .part
    // files stay for the next try, and nothing is moved into place that missed its pin.
    static func run(
        _ files: [Pinned] = files(),
        limit: Int = parallel,
        obtain: @escaping @Sendable (Pinned) async throws -> Void = { pinned in
            _ = try await PinnedDownload.obtain(file: pinned.file, sha256: pinned.sha256, bases: pinned.bases,
                                                into: pinned.into, step: pinned.step, from: pinned.source)
        }
    ) async throws {
        // An optional file that fails leaves Setup going; it is fetched again where it is needed.
        let fetch: @Sendable (Pinned) async throws -> Void = { pinned in
            guard pinned.optional else { return try await obtain(pinned) }
            do { try await obtain(pinned) } catch is CancellationError { throw CancellationError() } catch {
                AppLog.note("setup: \(pinned.file) not fetched ahead, it is fetched when needed: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        let keys = files.map(\.archivePath)
        await MainActor.run { DownloadMeter.shared.begin(batch: keys) }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var waiting = files.makeIterator()
                for _ in 0..<max(limit, 1) {
                    guard let file = waiting.next() else { break }
                    group.addTask { try await fetch(file) }
                }
                while try await group.next() != nil {
                    if let file = waiting.next() { group.addTask { try await fetch(file) } }
                }
            }
        } catch {
            await MainActor.run { DownloadMeter.shared.endBatch() }
            throw error
        }
        await MainActor.run { DownloadMeter.shared.endBatch() }
    }
}

extension SetupPrefetch.Pinned {
    /// The meter's key for this file: the path PinnedDownload.obtain keeps it at.
    var archivePath: String { into.appending(path: file).path(percentEncoded: false) }
}
