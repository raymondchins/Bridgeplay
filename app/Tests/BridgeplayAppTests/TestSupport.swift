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
// The folder is deleted when the test process exits; ScratchDefaultsTests checks the location.
// A suite name passed in must be unique: nothing clears the state an earlier test left under it.
func scratchDefaults(suite name: String = scratchSuiteName()) -> UserDefaults {
    // An absolute path as the suite name keeps the plist at that path.
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("UserDefaults refused the suite \(name)")
    }
    return defaults
}

func scratchSuiteName() -> String {
    ScratchDefaults.folder.appending(path: UUID().uuidString).path(percentEncoded: false)
}

enum ScratchDefaults {
    static let folder: URL = {
        let fm = FileManager.default
        // A run that crashed or was killed never reached the exit hook; clear what it left.
        let stale = Date().addingTimeInterval(-24 * 3600)
        for old in (try? fm.contentsOfDirectory(
            at: URL.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("np-defaults-")
            && ((try? old.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantFuture) < stale {
            try? fm.removeItem(at: old)
        }
        let url = URL.temporaryDirectory.appending(path: "np-defaults-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { fatalError("Cannot create scratch defaults folder \(url.path): \(error)") }
        atexit { try? FileManager.default.removeItem(at: ScratchDefaults.folder) }
        return url
    }()
}
