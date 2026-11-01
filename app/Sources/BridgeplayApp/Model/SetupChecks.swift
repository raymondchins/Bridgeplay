import Foundation

// What the Setup Assistant checks and installs before Bridgeplay itself: the Mac, Rosetta,
// Steam and the user's Steam sign-in.
enum SetupChecks {
    static let minimumMacOS = 26
    static let requiredBytes: Int64 = 3 * 1_000_000_000
    static let steamInstaller = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg")!

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var macOSVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var macOSDisplay: String {
        let v = macOSVersion
        return v.patchVersion == 0 ? "macOS \(v.majorVersion).\(v.minorVersion)" : "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var chipName: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    static func freeBytes(at url: URL = SupportPaths.home) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // Rosetta's runtime lives here once installed; its absence is what softwareupdate fixes.
    static let rosettaRuntime = URL(filePath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")

    static func rosettaInstalled(runtime: URL = rosettaRuntime) -> Bool {
        FileManager.default.fileExists(atPath: runtime.path(percentEncoded: false))
    }

    // softwareupdate needs root, so this goes through the standard administrator prompt.
    static func installRosetta() throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        try Shell.check("/usr/bin/osascript", ["-e", script])
    }

    // osascript's own error text ("execution error: User canceled. (-128)") means nothing to
    // most people, so the two common cases get plain sentences.
    static func rosettaFailure(_ error: Error) -> String {
        let text = error.localizedDescription
        if rosettaCancelled(error) {
            return String(localized: "Rosetta is still needed to run Windows games. The password window was closed, so it wasn't installed. Press Install to try again.")
        }
        if text.contains("(-60005)") || text.contains("(-60007)") {
            return String(localized: "Rosetta wasn't installed because macOS didn't accept the password. Use the name and password of an administrator of this Mac.")
        }
        return String(localized: "Rosetta wasn't installed. Check your internet connection and try again.")
    }

    // Closing the password window is a choice, not a failure to report.
    static func rosettaCancelled(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("(-128)") || text.localizedCaseInsensitiveContains("user canceled")
    }

    static var loginUsers: URL {
        SupportPaths.Steam.userData.appending(path: "config/loginusers.vdf")
    }

    // Steam writes every account that signed in on this Mac to loginusers.vdf.
    static func steamSignedIn(loginUsers file: URL = loginUsers) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.range(of: "\"AccountName\"", options: .caseInsensitive) != nil
    }

    // Downloads Valve's installer image and copies Steam.app into /Applications.
    static func installSteam(to app: URL = SupportPaths.Steam.defaultApp, report: @Sendable (String) -> Void) async throws {
        report(String(localized: "Downloading Steam"))
        let host = steamInstaller.host() ?? "Valve"
        let (download, response) = try await withoutActuallyEscaping(report) { report in
            let relay = ProgressRelay(host: host) { report($0.label) }
            defer { relay.finish(); Task { @MainActor in DownloadMeter.shared.clear() } }
            return try await URLSession.shared.download(from: steamInstaller, delegate: relay)
        }
        defer { try? FileManager.default.removeItem(at: download) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StepFailure(step: step, detail: "Valve answered \(http.statusCode).")
        }
        report(String(localized: "Installing Steam"))
        try DiskImage.withMounted(download) { volume in
            try copySteam(from: volume, to: app)
        }
    }

    // The download carries no quarantine, so nothing else looks at it before it runs: the
    // copy in the image has to carry Valve's signature before it reaches /Applications.
    static func copySteam(
        from volume: URL, to app: URL,
        verify: (URL) throws -> Void = { try SteamRepair.verifyValveSignature($0, step: step) },
        copy: (URL, URL) throws -> Void = { source, target in
            try Shell.check("/usr/bin/ditto", [source.path(percentEncoded: false), target.path(percentEncoded: false)])
        }
    ) throws {
        let mounted = volume.appending(path: "Steam.app")
        try verify(mounted)
        // Staged under its own name, so a failed copy never leaves a half-copied Steam.app that
        // would pass as installed. A Steam.app that appeared meanwhile is kept.
        let fm = FileManager.default
        let staged = app.deletingLastPathComponent().appending(path: "\(stagedPrefix)\(UUID().uuidString)")
        let hold = try StageLock(claiming: staged)
        defer {
            try? fm.removeItem(at: staged)
            hold.release()
        }
        StageLock.sweep(in: staged.deletingLastPathComponent(), prefix: stagedPrefix)
        try copy(mounted, staged)
        do { try fm.moveItem(at: staged, to: app) }
        catch where isAppBundle(app) {}
    }

    private static let stagedPrefix = ".Steam.app-"

    private static func isAppBundle(_ app: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let plist = app.appending(path: "Contents/Info.plist").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: plist, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static let step = String(localized: "Install Steam")
}

// Read-only disk image mounts that are always detached again.
enum DiskImage {
    static func withMounted<T>(_ image: URL, _ body: (URL) throws -> T) throws -> T {
        let mount = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try Shell.check("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-quiet",
                                             "-mountpoint", mount.path(percentEncoded: false), image.path(percentEncoded: false)])
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path(percentEncoded: false)]) }
        return try body(mount)
    }
}

// Copies Game Porting Toolkit's redist/lib out of Apple's disk image into the folder
// WinecxD3DMetal.locate looks in first.
enum GPTKImport {
    static var downloads: URL { SupportPaths.home.appending(path: "Downloads", directoryHint: .isDirectory) }

    // Downloads is only read while no Game Porting Toolkit is installed, so a Mac that has one
    // never sees the Downloads folder access prompt.
    static func candidatesIfMissing(installed: Bool, scan: () -> [URL] = { candidates() }) -> [URL] {
        installed ? [] : scan()
    }

    // Apple names the image Game_Porting_Toolkit_<version>.dmg; the newest name sorts last.
    static func candidates(in folder: URL = downloads) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names
            .filter { $0.hasPrefix("Game_Porting_Toolkit") && $0.lowercased().hasSuffix(".dmg") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { folder.appending(path: $0) }
    }

    // The outer image holds "Evaluation environment for Windows games <version>.dmg", which
    // holds redist/lib.
    static func innerImage(in volume: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volume.path(percentEncoded: false))) ?? []
        return names.first { $0.hasPrefix("Evaluation environment") && $0.lowercased().hasSuffix(".dmg") }
            .map { volume.appending(path: $0) }
    }

    static func importImage(_ image: URL, into destination: URL = WinecxD3DMetal.userFolder) throws -> WinecxD3DMetal.Payload {
        try DiskImage.withMounted(image) { outer in
            let lib: (URL) throws -> Void = { volume in
                let source = volume.appending(path: "redist/lib", directoryHint: .isDirectory)
                guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                    throw StepFailure(step: step, detail: "\(image.lastPathComponent) has no redist/lib folder.")
                }
                let staging = destination.deletingLastPathComponent().appending(path: ".gptk-import", directoryHint: .isDirectory)
                try? FileManager.default.removeItem(at: staging)
                try Shell.check("/usr/bin/ditto", [source.path(percentEncoded: false), staging.path(percentEncoded: false)])
                for name in ["License.rtf"] where !FileManager.default.fileExists(atPath: staging.appending(path: name).path(percentEncoded: false)) {
                    try? FileManager.default.copyItem(at: volume.appending(path: name), to: staging.appending(path: name))
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            if let inner = innerImage(in: outer) {
                try DiskImage.withMounted(inner, lib)
            } else {
                try lib(outer)
            }
        }
        guard let payload = WinecxD3DMetal.locate(in: [destination]) else {
            throw StepFailure(step: step, detail: "The copied Game Porting Toolkit is incomplete.")
        }
        return payload
    }

    static let step = String(localized: "Add the Game Porting Toolkit")
}
