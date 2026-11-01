import CryptoKit
import Foundation

/// Puts the unpacked components in place: Steam from Valve when it is missing, then Apple's
/// Game Porting Toolkit, the DXMT and DXVK archives and the default configs. What
/// Install.command does for its own zip; the zip still carries that script for app versions
/// that run it, but this app does not.
struct ComponentsPlacement {
    /// The `Bridgeplay` folder inside the unpacked components zip.
    let source: URL
    var home = FileManager.default.homeDirectoryForCurrentUser
    var applications = URL(fileURLWithPath: "/Applications")
    var installSteam: (_ applications: URL, _ download: @escaping @Sendable (InstallerDownloadProgress) -> Void) throws -> Void = ValveSteam.install
    /// Shows the Setup Assistant again even if an earlier Bridgeplay was dismissed.
    var resetSetupAssistant: () -> Void = {
        _ = try? InstallerComponents.run("/usr/bin/defaults", ["delete", "com.bridgeplay.Bridgeplay", "setupAssistantFinished"])
    }
    var oldConfs = ComponentsPlacement.oldInstallerConfs
    var log: (String) -> Void = { InstallerLog.write($0) }

    static let steamStatus = "Installing Steam from Valve"
    static let copyStatus = "Copying the Game Porting Toolkit, DXMT, DXVK and configs"

    // Installers up to 3.0.1 copied their own per-game confs into the user's gamefixes/,
    // where they override the shipped defaults. A copy still byte-identical to one of those
    // was never edited, so it goes; an edited one stays.
    static let oldInstallerConfs = [
        "1422450": "3ec703897532711d09717384333bce001642c16e9b33875e20f685af8fd09279",
        "3669870": "e5aa727e1f42de9db3a0975a1837974334dd3691fab13138b299902a68737f02",
        "3764200": "fef67384fb54b17d0f9818273f09548b699186e320eeae933b388f3b0aeda02f",
    ]

    func place(status: @escaping @Sendable (String) -> Void = { _ in },
               download: @escaping @Sendable (InstallerDownloadProgress) -> Void = { _ in }) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: applications.appending(path: "Steam.app").path) {
            status(Self.steamStatus)
            try installSteam(applications, download)
        }

        status(Self.copyStatus)
        let (support, caches) = folders()
        for folder in [support.appending(path: "gamefixes"), support.appending(path: "gamefixes-default"),
                       support.appending(path: ".installer"), caches] {
            try fail("Bridgeplay's folders in Library could not be made.") {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        // Copied beside the old one first, so a failed copy leaves the working toolkit alone.
        try fail("The Game Porting Toolkit could not be copied.") {
            try Self.put(source.appending(path: "gptk"), at: support.appending(path: "gptk"))
        }
        // Bridgeplay reuses any cached file whose hash matches its pin, so DXMT and DXVK are
        // not downloaded again. The WineCX runtime is not in the zip; the app downloads it.
        try fail("The engine files could not be copied.") {
            try InstallerComponents.run("/usr/bin/ditto", [source.appending(path: "cache").path, caches.path])
        }

        // Per-game confs are Bridgeplay's shipped defaults. They go to gamefixes-default/,
        // which the app owns and refreshes on every update; the user's gamefixes/ holds only
        // their overrides, and its default.conf is never written here.
        let defaults = source.appending(path: "config/gamefixes-default")
        let confs = (try? fm.contentsOfDirectory(at: defaults, includingPropertiesForKeys: nil)) ?? []
        for conf in confs where conf.pathExtension == "conf" {
            try fail("A game config could not be copied.") {
                try Self.put(conf, at: support.appending(path: "gamefixes-default/\(conf.lastPathComponent)"))
            }
        }
        for (appid, sha256) in oldConfs {
            let old = support.appending(path: "gamefixes/\(appid).conf")
            guard let data = fm.contents(atPath: old.path), Self.hex(SHA256.hash(data: data)) == sha256 else { continue }
            try fail("An old game config could not be removed: \(old.path)") {
                do { try fm.removeItem(at: old) } catch where !fm.fileExists(atPath: old.path) {}
            }
        }

        // The user's own controller mappings: only seeded when there are none yet.
        let mappings = support.appending(path: "gamecontrollerdb.txt")
        if !fm.fileExists(atPath: mappings.path) {
            try fail("gamecontrollerdb.txt could not be copied.") {
                try Self.put(source.appending(path: "config/gamecontrollerdb.txt"), at: mappings, replacing: false)
            }
        }
        resetSetupAssistant()
    }

    // Bridgeplay before 3.0.0 kept its files under "notproton". The app moves them to
    // "bridgeplay" itself on first launch (with a backup); while only the old folders exist,
    // the files go there so that move carries them along.
    func folders() -> (support: URL, caches: URL) {
        let library = home.appending(path: "Library")
        func pick(_ parent: String) -> URL {
            let current = library.appending(path: "\(parent)/bridgeplay"), legacy = library.appending(path: "\(parent)/notproton")
            let fm = FileManager.default
            return !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: legacy.path) ? legacy : current
        }
        return (pick("Application Support"), pick("Caches"))
    }

    // Copies to a name unique to this run beside the target, then swaps it in atomically, so the
    // installer and the app's Setup Assistant placing at once never leave a target missing or
    // half-written. With replacing false, a target that appeared meanwhile is kept.
    static func put(_ source: URL, at target: URL, replacing: Bool = true) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try InstallerComponents.run("/usr/bin/ditto", [source.path, staged.path])
        do { try fm.moveItem(at: staged, to: target) }
        catch where fm.fileExists(atPath: target.path) {
            if replacing { _ = try fm.replaceItemAt(target, withItemAt: staged) }
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private func fail(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch {
            log("\(message) \(error)")
            throw InstallerError.componentsFailure(message)
        }
    }
}

/// Steam from Valve's CDN, installed only when Valve's signature on it checks out.
enum ValveSteam {
    static let url = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/steam.dmg")!
    /// The trust chain, Valve's Team ID and Steam's bundle identifier, checked as one requirement.
    static let requirement = #"=anchor apple generic and certificate leaf[subject.OU] = "MXGJJ98X76" and identifier "com.valvesoftware.steam""#

    static func install(into applications: URL, download: @escaping @Sendable (InstallerDownloadProgress) -> Void) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "bridgeplay-steam-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let dmg = work.appending(path: "steam.dmg"), mount = work.appending(path: "mnt")

        do {
            try InstallerComponents.run("/usr/bin/curl", ["-fL", "--retry", "3", "--connect-timeout", "20",
                                                          "-o", dmg.path, url.absoluteString]) { line in
                if let meter = InstallerDownloadProgress(curlMeter: line) { download(meter) }
            }
        } catch {
            InstallerLog.write("Steam download failed: \(error)")
            throw InstallerError.componentsFailure("Steam could not be downloaded. Check the internet connection and try again.")
        }
        // A UDIF disk image ends with a 512-byte trailer that starts with "koly".
        guard isDiskImage(dmg) else {
            throw InstallerError.componentsFailure("The Steam download is not Valve's installer. Try again later.")
        }
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try InstallerComponents.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                                             "-mountpoint", mount.path, dmg.path])
        } catch {
            InstallerLog.write("Opening the Steam installer failed: \(error)")
            throw InstallerError.componentsFailure("The Steam installer could not be opened.")
        }
        defer { _ = try? InstallerComponents.run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
        let steam = mount.appending(path: "Steam.app")
        guard (try? InstallerComponents.run("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, steam.path])) != nil else {
            throw InstallerError.componentsFailure("The Steam download is not signed by Valve, so it was not installed.")
        }
        // Staged under its own name, so a failed copy never leaves a half-copied Steam.app that
        // would pass as installed, and never removes one another placement put there meanwhile.
        do {
            try ComponentsPlacement.put(steam, at: applications.appending(path: "Steam.app"), replacing: false)
        } catch {
            InstallerLog.write("Copying Steam failed: \(error)")
            throw InstallerError.componentsFailure("Steam could not be copied to Applications.")
        }
    }

    static func isDiskImage(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 512 else { return false }
        try? handle.seek(toOffset: size - 512)
        return (try? handle.read(upToCount: 4)) == Data("koly".utf8)
    }
}
