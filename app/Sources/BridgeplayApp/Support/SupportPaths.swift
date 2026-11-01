// Path construction for the Bridgeplay support directory and Steam

import Foundation

enum SupportPaths {

    static let supportDirName = "bridgeplay"
    // Builds before 3.0 kept everything under "notproton". BrandMigration moves it.
    static let legacySupportDirName = "notproton"
    // Shared with upstream NotProton: Steam's Info.plist and the dylib's own checks name it.
    static let dylibName = "notproton.dylib"

    static var home: URL {
        URL(filePath: NSHomeDirectory())
    }

    static var applicationSupport: URL {
        home.appending(path: "Library/Application Support")
    }

    // ~/Library/Application Support/bridgeplay
    static var support: URL {
        applicationSupport.appending(path: supportDirName)
    }

    // ~/Library/Application Support/notproton, where builds before 3.0 kept their data.
    static var legacyApplicationSupport: URL {
        applicationSupport.appending(path: legacySupportDirName)
    }

    // ~/Library/Caches/bridgeplay
    static var caches: URL {
        home.appending(path: "Library/Caches/\(supportDirName)")
    }

    static var legacyCaches: URL {
        home.appending(path: "Library/Caches/\(legacySupportDirName)")
    }

    // ~/.bridgeplay: np-native and libnp_gamepad.dylib, at a path launch options can spell.
    static var homeDir: URL { home.appending(path: ".\(supportDirName)") }
    static var legacyHomeDir: URL { home.appending(path: ".\(legacySupportDirName)") }

    // The Steam bundles Bridgeplay modified, kept outside support so a reinstall keeps it.
    static var steamBundlesRecord: URL {
        applicationSupport.appending(path: "\(supportDirName)-steam-bundles.json")
    }

    static var legacySteamBundlesRecord: URL {
        applicationSupport.appending(path: "\(legacySupportDirName)-steam-bundles.json")
    }

    static var bridge: URL { support.appending(path: "bridge") }
    static var runners: URL { support.appending(path: "runners") }
    static var backups: URL { support.appending(path: "backups") }
    static var launchers: URL { support.appending(path: "launchers") }
    // Free WineHQ engines Bridgeplay downloaded, laid out like a CrossOver bundle.
    static var engines: URL { support.appending(path: "engines") }
    // Per-game defaults Bridgeplay ships. Replaced on every install; the user's own
    // overrides live in the sibling "gamefixes" directory. Bridgeplay writes there only the
    // lines GameDefaults owns, in default.conf and, on Use Defaults, in a game's <appid>.conf,
    // and keeps everything else as it is.
    static var gamefixesDefault: URL { support.appending(path: "gamefixes-default") }
    static var gamefixes: URL { support.appending(path: "gamefixes") }
    // Where Remove Everything moves the user's own overrides, outside the folder it deletes.
    static var keptGamefixes: URL { applicationSupport.appending(path: "\(supportDirName)-gamefixes") }

    static var signatures: URL {
        support.appending(path: "signatures/macos.arm64")
    }

    static var fonts: URL { support.appending(path: "fonts") }
    static var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
    static var iconmaker: URL { support.appending(path: "iconmaker") }
    static var appinfo: URL { support.appending(path: "appinfo") }

    static var packageDownloads: URL { caches.appending(path: "valve-packages") }

    static var winetricksDownloads: URL { caches.appending(path: "winetricks") }

    static var deployedVersion: URL { support.appending(path: "dylib.version") }

    // Read by the dylib at Steam launch, in np_compat_load_tool_list.
    static var toolList: URL { support.appending(path: "tools") }

    static func runnerRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: "crossover-\(build)")
    }

    static func crossOverRoot(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/SharedSupport/CrossOver")
    }

    static func clonedRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runnerRoot(forBuild: build, runners: runners).appending(path: "CrossOver")
    }

    static func prefixTemplates(forBuild build: String, in library: SteamLibrary) -> [URL] {
        CompatTool.Flavor.allCases.map { prefixTemplate(forBuild: build, flavor: $0, in: library) }
    }

    static func prefixTemplate(forBuild build: String, flavor: CompatTool.Flavor, in library: SteamLibrary) -> URL {
        library.compatdata.appending(path: prefixTemplateFolder).appending(path: "crossover-\(build)-\(flavor.unixDir)")
    }

    // Inside each library's compatdata, beside the prefixes. Keeps its old name so the
    // templates already built there stay usable.
    static let prefixTemplateFolder = "notproton-template"
    static let bridgeCacheFolder = "bridge"

    enum Steam {
        static let defaultApp = URL(filePath: "/Applications/Steam.app")
        static let appPathKey = "steamAppPath"

        static var app: URL {
            UserDefaults.standard.string(forKey: appPathKey).map { URL(filePath: $0) } ?? defaultApp
        }
        static func isUnreachable(_ bundle: URL = app) -> Bool {
            !FileManager.default.fileExists(atPath: bundle.deletingLastPathComponent().path(percentEncoded: false))
        }
        static var infoPlist: URL { infoPlist(inBundle: app) }
        static var deployedDylib: URL { deployedDylib(inBundle: app) }

        static func infoPlist(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/Info.plist")
        }

        static func deployedDylib(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/MacOS/\(dylibName)")
        }

        static var userData: URL {
            SupportPaths.applicationSupport.appending(path: "Steam")
        }

        static var configFile: URL { userData.appending(path: "steam.cfg") }

        static var innerApp: URL { userData.appending(path: "Steam.AppBundle/Steam") }
        static var innerInfoPlist: URL { innerApp.appending(path: "Contents/Info.plist") }

        static var innerClient: URL { innerApp.appending(path: "Contents/MacOS") }

        static var innerConfigFile: URL { innerClient.appending(path: "steam.cfg") }
        static var legacyCompat: URL { innerClient.appending(path: "legacycompat") }

        static var compatTools: URL { userData.appending(path: "compatibilitytools.d") }

        // Every compatibility tool Bridgeplay wrote, under either name.
        static func ourTools(in directory: URL = compatTools) -> [URL] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            return entries.filter { ToolName.isOurs($0.lastPathComponent) }
        }

        static var libraryFoldersVDF: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    }
}

// Steam compatibility tool names. Bridgeplay writes bridgeplay-proton-*; builds before 3.0
// wrote notproton-*, and those folders stay Bridgeplay's until BrandMigration renames them.
// Steam maps Cloud's Windows path roots into the prefix only for a tool whose name contains
// "proton" (see dylib/feats/compat.c), so both prefixes keep it.
enum ToolName {
    static let prefix = "bridgeplay-proton"
    static let legacyPrefix = "notproton"

    // notproton-winecx-11.17 -> bridgeplay-proton-winecx-11.17, notproton -> bridgeplay-proton.
    // Any other name, including one already migrated, comes back unchanged.
    static func migrated(_ name: String) -> String {
        guard isLegacy(name) else { return name }
        return prefix + name.dropFirst(legacyPrefix.count)
    }

    static func isLegacy(_ name: String) -> Bool { name.hasPrefix(legacyPrefix) }

    static func isOurs(_ name: String) -> Bool { name.hasPrefix(prefix) || isLegacy(name) }
}
