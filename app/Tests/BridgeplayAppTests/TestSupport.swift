import Foundation

@testable import BridgeplayApp

func scratchDirectory(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func isolatedValveDownloads(in work: URL) throws -> URL {
    let downloads = work.appending(path: "downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    if let bundle = try ValvePackageManifest.bundled().bundle {
        let cached = SupportPaths.packageDownloads.appending(path: bundle.file)
        let destination = downloads.appending(path: bundle.file)
        if FileManager.default.fileExists(atPath: cached.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: cached, to: destination)
        }
    }
    return downloads
}

// A UserDefaults that lives in a temporary folder, not in ~/Library/Preferences. Even after
// removePersistentDomain, a named suite leaves its plist behind there, one file per test run.
// The folder is deleted when the test process exits.
func scratchDefaults() -> UserDefaults {
    let name = ScratchDefaultsFolder.shared.url.appending(path: UUID().uuidString)
        .path(percentEncoded: false)
    // An absolute path as the suite name keeps the plist at that path.
    return UserDefaults(suiteName: name)!
}

private final class ScratchDefaultsFolder: Sendable {
    static let shared = ScratchDefaultsFolder()
    let url = URL.temporaryDirectory.appending(path: "np-defaults-\(UUID().uuidString)")

    private init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ScratchDefaultsFolder.shared.url) }
    }
}
