// Downloads needed components from Valve

import Foundation

enum ValveFetcher {

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case extracting
        case verifying
        case installing
        case finished

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .extracting: String(localized: "Extracting")
            case .verifying: String(localized: "Verifying")
            case .installing: String(localized: "Installing")
            case .finished: String(localized: "Done")
            }
        }
    }

    struct Outcome: Sendable {
        let installed: [String]
        let unchanged: [String]

        var wroteNothing: Bool { installed.isEmpty }
    }

    static let step = String(localized: "Fetch the Valve binaries")

    static func run(
        manifest suppliedManifest: ValvePackageManifest? = nil,
        bridge: URL = SupportPaths.bridge,
        downloads: URL = SupportPaths.packageDownloads,
        report: @Sendable (Phase) -> Void = { _ in }
    ) async throws -> Outcome {
        let manifest = try suppliedManifest ?? ValvePackageManifest.bundled()
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)

        let extracted = downloads.appending(path: "extract")
        try? files.removeItem(at: extracted)
        try files.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: extracted) }

        for package in manifest.packages {
            let archive = try await obtain(package, bases: manifest.bases, downloads: downloads, report: report)
            report(.extracting)
            try extract(manifest.innerPaths(package: package.id), from: archive, into: extracted)
        }

        report(.verifying)
        let wrong = manifest.files.filter { Digest.sha256IfPresent(extracted.appending(path: $0.innerPath)) != $0.sha256 }
        guard wrong.isEmpty else {
            AppLog.note("valve fetch: \(wrong.count) of \(manifest.files.count) files missed their pinned hash: \(wrong.map(\.bridgePath).joined(separator: ", "))")
            throw StepFailure(
                step: step,
                detail: String(localized: "Something is wrong with the downloaded files. Please check for a Bridgeplay update.")
            )
        }

        report(.installing)
        let outcome = try install(manifest, from: extracted, into: bridge)

        report(.finished)
        return outcome
    }

    static func install(
        _ manifest: ValvePackageManifest, from extracted: URL, into bridge: URL
    ) throws -> Outcome {
        let files = FileManager.default
        var installed: [String] = []
        var unchanged: [String] = []

        for file in manifest.files {
            let destination = bridge.appending(path: file.bridgePath)
            if Digest.sha256IfPresent(destination) == file.sha256 {
                unchanged.append(file.bridgePath)
                continue
            }
            try files.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )

            let pending = destination.appendingPathExtension("bridgeplay-pending")
            try? files.removeItem(at: pending)
            try files.copyItem(at: extracted.appending(path: file.innerPath), to: pending)

            if files.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try files.replaceItemAt(destination, withItemAt: pending)
            } else {
                try files.moveItem(at: pending, to: destination)
            }
            installed.append(file.bridgePath)
        }

        return Outcome(installed: installed, unchanged: unchanged)
    }

    private static func obtain(
        _ package: ValvePackage,
        bases: [URL],
        downloads: URL,
        report: @Sendable (Phase) -> Void
    ) async throws -> URL {
        try await PinnedDownload.obtain(
            file: package.file, sha256: package.sha256, bases: bases, into: downloads, step: step
        ) { report(.downloading($0)) }
    }

    private static func extract(_ inner: [String], from archive: URL, into destination: URL) throws {
        try Shell.check(
            "/usr/bin/unzip",
            ["-q", "-o", archive.path(percentEncoded: false)]
                + inner
                + ["-d", destination.path(percentEncoded: false)]
        )
    }
}
