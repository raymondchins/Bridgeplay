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
func scratchDefaults() -> UserDefaults {
    scratchDefaultsAndPlist().defaults
}

// The same, with the path its plist will be written to.
func scratchDefaultsAndPlist() -> (defaults: UserDefaults, plist: String) {
    let name = ScratchDefaults.folder.appending(path: UUID().uuidString).path(percentEncoded: false)
    // An absolute path as the suite name keeps the plist at that path.
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("UserDefaults refused the suite \(name)")
    }
    return (defaults, name + ".plist")
}

enum ScratchDefaults {
    static let folder: URL = {
        let fm = FileManager.default
        let url = URL.temporaryDirectory.appending(path: "np-defaults-\(UUID().uuidString)")
        atexit { try? FileManager.default.removeItem(at: ScratchDefaults.folder) }

        // A run that crashed or was killed never reached the exit hook; clear what it left.
        // A week is far longer than any test run.
        let stale = Date().addingTimeInterval(-7 * 24 * 3600)
        for old in (try? fm.contentsOfDirectory(
            at: URL.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("np-defaults-") {
            let modified = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < stale { try? fm.removeItem(at: old) }
        }
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            fatalError("Cannot create scratch defaults folder \(url.path): \(error)")
        }
        return url
    }()
}
