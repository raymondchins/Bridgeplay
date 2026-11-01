// 'Install' logic for the Steam patch componen

import Foundation

enum InstallPhase: Sendable {
    case checkingPayload
    case stagingBridge
    case preflight
    case stoppingClient
    case copyingDylib
    case installingSignatures
    case installingOverlayShim
    case settingInsert
    case signing
    case registering
    case finished

    var label: String {
        switch self {
        case .checkingPayload: String(localized: "Preparing")
        case .stagingBridge: String(localized: "Staging components")
        case .preflight: String(localized: "Checking Steam")
        case .stoppingClient: String(localized: "Stopping Steam")
        case .copyingDylib: String(localized: "Installing")
        case .installingSignatures: String(localized: "Installing signatures")
        case .installingOverlayShim: String(localized: "Installing components")
        case .settingInsert: String(localized: "Configuring Steam")
        case .signing: String(localized: "Signing")
        case .registering: String(localized: "Finishing up")
        case .finished: String(localized: "Done")
        }
    }
}

struct InstallOutcome: Sendable {
    let stoppedClient: Bool
    let version: String
    let build: DeploymentContent.Build
    let signatureDatabases: Int
    let backedUpPlist: Bool
    // Input access services macOS refused to reset after Steam's signature changed. nil when
    // the signature didn't change, so no reset ran.
    var failedInputResets: [String]?
}

enum SteamInstaller {
    static let step = String(localized: "Install Bridgeplay")

    typealias ClientStopper = @Sendable (URL, () -> Void) throws -> Bool
    typealias BundleRegistrar = @Sendable (URL) -> Void

    static let stopTheClient: ClientStopper = { app, onStopping in
        try SteamBundle.stopClient(app: app, step: step, onStopping: onStopping)
    }

    // For an install nobody asked for: it was decided while Steam was closed, and checking
    // again here, under the installation lock, keeps a Steam opened since then running.
    static let leaveTheClient: ClientStopper = { _, _ in
        if SteamBundle.isRunning { throw ClientStarted() }
        return false
    }

    struct ClientStarted: LocalizedError {
        var errorDescription: String? {
            String(localized: "Steam opened while Bridgeplay was getting ready to update it, so Steam was left alone.")
        }
    }

    // Typed so Setup can offer Repair Steam for it.
    struct ForeignInsert: LocalizedError {
        let tool: String

        var errorDescription: String? {
            StepFailure(step: SteamInstaller.step,
                        detail: String(localized: "\(tool) is already set up in Steam, and Bridgeplay won't install on top of it. Repair Steam to remove it, then try again."))
                .errorDescription
        }
    }

    static func run(
        payload suppliedPayload: InstallPayload.Located? = nil,
        bridgePayload suppliedBridge: BridgePayload.Located? = nil,
        version: String = AppVersion.bundled,
        app: URL = SupportPaths.Steam.app,
        bridge: URL = SupportPaths.bridge,
        signatures: URL = SupportPaths.signatures,
        fonts: URL = SupportPaths.fonts,
        overlayShim: URL = SupportPaths.overlayShim,
        iconmaker: URL = SupportPaths.iconmaker,
        appinfo: URL = SupportPaths.appinfo,
        deployedVersion: URL = SupportPaths.deployedVersion,
        backups: URL = SupportPaths.backups,
        compatTools: URL = SupportPaths.Steam.compatTools,
        holdingInstallationLock: Bool = false,
        lockFolder: URL = SupportPaths.applicationSupport,
        modifications: SteamModifications = .shared,
        runnerIsRunning: @Sendable (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) },
        launchingBuild: (URL) -> String? = { RunnerInstaller.launchingBuild(tools: SupportPaths.Steam.ourTools(in: $0)) },
        verifyRunner: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        patchRunner: (RunnerBuild, URL, URL) throws -> Void = { build, root, bridge in
            _ = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: bridge)
            _ = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        },
        stopClient: ClientStopper = stopTheClient,
        register: BundleRegistrar = { SteamBundle.register($0) },
        resetInputAccess: () -> [String] = resetInputAccess,
        onInputReset: ([String]) -> Void = { _ in },
        report: @escaping @Sendable (InstallPhase) -> Void = { _ in }
    ) throws -> InstallOutcome {
        report(.checkingPayload)
        let payload = try suppliedPayload ?? InstallPayload.locate()
        let bridgeLocated = try suppliedBridge ?? BridgePayload.locate()

        report(.preflight)
        let plist = app.appending(path: "Contents/Info.plist")
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        try assertBundleIsPresent(app)
        try assertInsertIsDeployedOrAbsent(at: plist, dylib: dylib)
        let installationLock = holdingInstallationLock
            ? nil : try DeploymentContent.acquireInstallationLock(in: lockFolder, steamFolder: app.deletingLastPathComponent())
        defer { installationLock?.release() }
        guard let dylibHashes = try MachOBuild.hashesIgnoringSignature(of: payload.dylib) else {
            throw StepFailure(step: step, detail: String(localized: "The bundled Bridgeplay dylib is invalid."))
        }
        let build = DeploymentContent.Build(version: version, builtAt: payload.builtAt,
                                            dylibHashes: dylibHashes)
        let record = DeploymentContent.record(beside: deployedVersion)
        let previousBuild = try DeploymentContent.readBuild(at: record)
        let support = deployedVersion.deletingLastPathComponent()
        let runners = support.appending(path: "runners")
        let tools = CompatToolList.installed(runners: runners, file: support.appending(path: "tools"))
        let files = DeploymentContent.files(
            payload: payload, bridgePayload: bridgeLocated, app: app, bridge: bridge,
            signatures: signatures, fonts: fonts, overlayShim: overlayShim, iconmaker: iconmaker, appinfo: appinfo,
            compatTools: compatTools, tools: tools, runners: runners,
            gamefixes: support.appending(path: "gamefixes-default"))
        let content = try DeploymentContent.inspect(files: files, bundled: build, installed: previousBuild,
                                                   legacyVersion: SteamBundle.deployedVersion(at: deployedVersion))
        guard content != .newerInstalled else {
            throw StepFailure(step: step, detail: String(localized: "A newer Bridgeplay build is installed. Use that build to update or repair the installed files."))
        }
        func refuseRunningRunners() throws {
            for id in RunnerStore.clonedBuilds(in: runners) where runnerIsRunning(SupportPaths.runnerRoot(forBuild: id, runners: runners)) {
                throw StepFailure(step: step, detail: String(localized: "A game or Wine tool is running on build \(id). Quit it before updating Bridgeplay."))
            }
            if let id = launchingBuild(compatTools) {
                throw StepFailure(step: step, detail: String(localized: "A game or Wine tool is running on build \(id). Quit it before updating Bridgeplay."))
            }
        }
        try refuseRunningRunners()
        let builds = RunnerStore.installedBuilds(in: runners)
        for build in builds {
            try verifyRunner(build, SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
        }
        try modifications.mark(app)
        let patching = try needsPatching(plist: plist, dylib: dylib, shipping: payload.dylib, app: app)
        let replacingFiles = try files.contains {
            try $0.needsClientStopped && !$0.matches() && FileManager.default.fileExists(atPath: $0.destination.path(percentEncoded: false))
        }
        let pinned = try DeploymentContent.pinnedFiles(bridge: bridge, runners: runners)
        let existingAccount = previousBuild != nil || SteamBundle.deployedVersion(at: deployedVersion) != nil
            || pinned.contains { FileManager.default.fileExists(atPath: $0.destination.path(percentEncoded: false)) }
        let replacingPinned = existingAccount && pinned.contains { Digest.sha256IfPresent($0.destination) != $0.hash }

        var stopped = false
        if patching || replacingFiles || replacingPinned {
            stopped = try stopClient(app) { report(.stoppingClient) }
        }
        try refuseRunningRunners()
        _ = try CompatToolList.sync(runners: runners, bridge: bridge,
                                   file: support.appending(path: "tools"), compatTools: compatTools)

        report(.stagingBridge)
        _ = try BridgePayload.stage(located: bridgeLocated, bridge: bridge)
        for build in builds {
            try patchRunner(build, SupportPaths.clonedRoot(forBuild: build.id, runners: runners), bridge)
        }

        if patching {
            report(.copyingDylib)
            try install(payload.dylib, at: dylib)
        }

        report(.installingSignatures)
        report(.installingOverlayShim)
        for file in files where file.destination != dylib {
            try installIfChanged(file)
        }
        pruneGamefixes(keeping: payload.gamefixes.map(\.lastPathComponent),
                       in: deployedVersion.deletingLastPathComponent().appending(path: "gamefixes-default"))
        seedControllerMappings(from: payload.dylib.deletingLastPathComponent(), in: support)
        // The shipped defaults now sit in gamefixes-default/, so the user's file keeps only their own.
        do {
            try GameDefaults.splitShipped(in: support)
        } catch {
            AppLog.note("game defaults: could not split the shipped defaults out: \(error.localizedDescription)")
        }
        // The CJK fonts come from their own download, so they aren't in the payload.
        try removeStaleFonts(in: fonts, keeping: payload.fonts + CJKFonts.files.keys + CJKFonts.licences)

        var backedUp = false
        var failedInputResets: [String]?
        if patching {
            report(.settingInsert)
            backedUp = try backUpPlist(plist, into: backups)

            let priorPlist = try? Data(contentsOf: plist)
            let priorRequirement = designatedRequirement(of: app)
            do {
                try setInsert(at: plist, to: dylib)

                report(.signing)
                try LocalSigning.unlocked(signingIdentity()) { identity in
                    try sign(dylib, identity: identity)
                    try sign(app.appending(path: "Contents/MacOS/steam_osx"), identity: identity)
                    try sign(app, identity: identity)
                }
            } catch {
                do {
                    try revertPlist(priorPlist, at: plist, app: app)
                } catch let revertFailure {
                    AppLog.note("install: putting the plist back failed: \(revertFailure.localizedDescription)")
                    throw StepFailure(step: step, detail: error.localizedDescription + " " + String(localized: "Putting Steam back as it was also failed, so Steam may not start: \(revertFailure.localizedDescription) Use Repair Steam to restore it."))
                }
                throw error
            }
            // macOS keys Steam's input access to the designated requirement. Ad hoc that is the
            // cdhash, which every new dylib changes; signed with the local identity it is the
            // certificate, so the approval survives updates and is only cleared on a change.
            if designatedRequirement(of: app) != priorRequirement {
                let failed = resetInputAccess()
                failedInputResets = failed
                // Told now: the reset stays done even if the install throws below.
                onInputReset(failed)
            }
        }

        report(.registering)
        register(app)

        let landed = SteamBundle.currentInsert(at: plist)
        guard landed == dylib.path(percentEncoded: false) else {
            AppLog.note("install: bundle declares \(landed ?? "no insert")")
            throw StepFailure(
                step: step,
                detail: String(localized: "Steam is set up to inject a different dylib. Please repair Steam before installing Bridgeplay.")
            )
        }

        let remaining = try files.filter { try !$0.matches() }.map(\.name)
        guard remaining.isEmpty else {
            throw StepFailure(step: step, detail: String(localized: "These files did not update: \(remaining.joined(separator: ", "))."))
        }

        if let executable = Bundle.main.executableURL {
            do {
                try RebuildPrefixCommand.recordExecutable(executable, in: support)
            } catch {
                AppLog.note("install: could not record the rebuild app: \(error.localizedDescription)")
            }
        }
        report(.finished)
        return InstallOutcome(
            stoppedClient: stopped,
            version: version,
            build: build,
            signatureDatabases: payload.signatures.count,
            backedUpPlist: backedUp,
            failedInputResets: failedInputResets
        )
    }

    static func finish(
        _ outcome: InstallOutcome,
        deployedVersion: URL = SupportPaths.deployedVersion,
        isCurrent: (String) -> Bool = { DeploymentContent.current(version: $0) == .current }
    ) throws {
        guard isCurrent(outcome.version) else {
            throw StepFailure(step: step,
                              detail: String(localized: "Installed content could not be verified. Refresh the Status view for the files that still need attention."))
        }
        try write(outcome.version, to: deployedVersion)
        try atomicReplace(DeploymentContent.record(beside: deployedVersion),
                          with: JSONEncoder().encode(outcome.build), step: step)
    }

    // The shipped defaults are replaced as a set, so a fix dropped from the app stops applying.
    static func pruneGamefixes(keeping names: [String], in directory: URL) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !names.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
        }
    }

    static func removeStaleFonts(in fonts: URL, keeping shipped: [String]) throws {
        let files = FileManager.default
        let keep = Set(shipped)
        for rel in files.subpaths(atPath: fonts.path(percentEncoded: false)) ?? [] where !keep.contains(rel) {
            let url = fonts.appending(path: rel)
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
                continue
            }
            try WriteRefused.catching(url) { try files.removeItem(at: url) }
        }
    }

    // The user's own mappings, so an existing file stays. Without one a pad SDL does not know,
    // such as the GameSir G7 Pro, reaches games in its raw button order.
    static func seedControllerMappings(from payload: URL, in support: URL) {
        let fm = FileManager.default
        let source = payload.appending(path: "gamecontrollerdb.txt")
        let mappings = support.appending(path: "gamecontrollerdb.txt")
        guard fm.fileExists(atPath: source.path(percentEncoded: false)),
            !fm.fileExists(atPath: mappings.path(percentEncoded: false))
        else { return }
        do {
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: mappings)
        } catch {
            AppLog.note("controllers: could not seed the mappings: \(error.localizedDescription)")
        }
    }

    static func installIfChanged(_ file: DeploymentContent.File) throws {
        if try file.matches() { return }
        try install(file.source, at: file.destination)
        if file.executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.destination.path(percentEncoded: false))
        }
    }


    static func assertBundleIsPresent(_ app: URL) throws {
        guard FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(app.path(percentEncoded: false)) is not there, so there is nothing to install into.")
            )
        }
    }

    static func assertInsertIsDeployedOrAbsent(at plist: URL, dylib: URL) throws {
        guard let insert = SteamBundle.currentInsert(at: plist), !insert.isEmpty else { return }

        if let tool = SteamBundle.foreignTool(in: insert, deployed: dylib.path(percentEncoded: false)) {
            throw ForeignInsert(tool: tool)
        }
    }

    static func needsPatching(plist: URL, dylib: URL, shipping: URL, app: URL) throws -> Bool {
        let deployed = SteamBundle.currentInsert(at: plist) == dylib.path(percentEncoded: false)
            && SteamBundle.currentControllerBlock(at: plist) == SteamBundle.controllerBlockValue
        let file = DeploymentContent.File(source: shipping, destination: dylib, name: "notproton.dylib", allowsResigning: true)
        if deployed, try file.matches() {
            AppLog.note("install: Steam already carries this dylib, installing for this account only")
            return false
        }

        do {
            try assertBundleIsWritable(app)
        } catch let refusal as WriteRefused {
            guard let detail = refusalDetail(refusal.remedy, deployed: deployed) else { throw refusal }
            throw StepFailure(step: step, detail: detail)
        }
        return true
    }

    // What to say when Steam.app can't be written for a reason this account can't fix.
    static func refusalDetail(_ remedy: Remedy, deployed: Bool) -> String? {
        switch remedy {
        case .otherAccount: deployed ? mismatchAcrossAccounts : unpatchedAcrossAccounts
        case .rootOwned: deployed ? mismatchRootOwned + " " + remedy.advice : remedy.advice
        case .appManagement, .ownership: nil
        }
    }

    private static let mismatchAcrossAccounts =
        String(localized: "Steam has a different copy of Bridgeplay, installed by another account on this Mac. Update Bridgeplay from that account, then try again.")

    private static let mismatchRootOwned =
        String(localized: "Steam has a different copy of Bridgeplay, and this account cannot update it.")

    private static let unpatchedAcrossAccounts =
        String(localized: "Steam has not been set up for Bridgeplay, and this account cannot change it. Install from the account that owns Steam.")

    static func assertBundleIsWritable(_ app: URL) throws {
        let directory = app.appending(path: "Contents/MacOS")
        let probe = directory.appending(path: ".bridgeplay-write-probe-\(UUID().uuidString)")
        do {
            try Data("probe".utf8).write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: directory.path(percentEncoded: false), errno: WriteRefused.posixCode(of: error))
        } catch {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(directory.path(percentEncoded: false)) could not be written. ")
                    + error.localizedDescription
            )
        }
    }

    static func install(_ source: URL, at destination: URL) throws {
        try WriteRefused.catching(destination) {
            try atomicReplace(destination, from: source, step: step)
        }
    }

    static func write(_ version: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("\(version)\n".utf8).write(to: url)
    }

    static func backUpPlist(_ plist: URL, into backups: URL) throws -> Bool {
        let destination = backups.appending(path: SteamBundle.plistBackupName)
        let legacy = backups.appending(path: SteamBundle.legacyPlistBackupName)
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path(percentEncoded: false)),
              !files.fileExists(atPath: legacy.path(percentEncoded: false)) else { return false }
        guard files.fileExists(atPath: plist.path(percentEncoded: false)) else { return false }

        try files.createDirectory(at: backups, withIntermediateDirectories: true)
        try files.copyItem(at: plist, to: destination)
        return true
    }

    // Throws when either half fails: a plist that still declares the insert, or a bundle
    // whose seal no longer matches it, is a Steam that does not start.
    static func revertPlist(_ bytes: Data?, at plist: URL, app: URL) throws {
        guard let bytes else { return }
        try WriteRefused.catching(plist) { try bytes.write(to: plist) }
        try adHocSign(app)
    }

    static func setInsert(at plist: URL, to dylib: URL) throws {
        guard var dict = SteamBundle.readInfoPlist(at: plist) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(plist.path(percentEncoded: false)) could not be read as a property list.")
            )
        }

        var environment = dict[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        environment[SteamBundle.insertKey] = dylib.path(percentEncoded: false)
        environment[SteamBundle.controllerBlockKey] = SteamBundle.controllerBlockValue
        dict[SteamBundle.environmentKey] = environment
        try SteamBundle.writeInfoPlist(dict, at: plist)
    }

    static func adHocSign(_ url: URL, step: String = step) throws {
        try sign(url, identity: "-", step: step)
    }

    // A self-signed code signing identity, in Bridgeplay's own keychain (or the login keychain
    // on older installs). When it exists Steam is signed with it instead of ad hoc, which keeps
    // its designated requirement, and with it the user's Input Monitoring approval, the same
    // across Bridgeplay updates.
    static let localSigningIdentity = "NotProton Local Signing"

    // LocalSigning creates it from the Setup Assistant or the Status page.
    static func signingIdentity() -> LocalSigning.Identity? {
        LocalSigning.existing()
    }

    static func sign(_ url: URL, identity: LocalSigning.Identity?, step: String = step) throws {
        try sign(url, identity: identity?.hash ?? "-", keychain: identity?.keychain, step: step)
    }

    static func sign(_ url: URL, identity: String, keychain: URL? = nil, step: String = step) throws {
        let path = url.path(percentEncoded: false)
        let lookup = keychain.map { ["--keychain", $0.path(percentEncoded: false)] } ?? []
        var result = try Shell.run("/usr/bin/codesign", ["-f", "-s", identity] + lookup + [path])
        // Fixes codesign refusing a Steam.app that carries Finder info or a resource fork.
        if !result.succeeded, result.stderr.contains("detritus not allowed") {
            clearFinderData(in: enclosingBundle(of: url))
            result = try Shell.run("/usr/bin/codesign", ["-f", "-s", identity] + lookup + [path])
        }
        // A keychain that refuses the identity must not leave Steam unsigned.
        if !result.succeeded, identity != "-" {
            result = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", path])
        }
        guard result.succeeded else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(path) could not be signed. ")
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func designatedRequirement(of url: URL) -> String? {
        guard let result = try? Shell.run("/usr/bin/codesign", ["-d", "-r-", url.path(percentEncoded: false)])
        else { return nil }
        return (result.stdout + result.stderr).split(separator: "\n")
            .first { $0.hasPrefix("designated => ") }
            .map(String.init)
    }

    static func enclosingBundle(of url: URL) -> URL {
        var candidate = url
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return url
    }

    static func clearFinderData(in root: URL) {
        var paths = [root.path(percentEncoded: false)]
        if let walk = FileManager.default.enumerator(atPath: paths[0]) {
            while let relative = walk.nextObject() as? String {
                paths.append(root.appending(path: relative).path(percentEncoded: false))
            }
        }
        for path in paths {
            for name in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
                removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }

    // macOS does not automatically clear a pre-existing input access approval, so it needs to be cleared
    // or Steam Input will silently not work.
    static let inputAccessServices = ["Accessibility", "PostEvent", "ListenEvent"]

    // Returns what macOS refused to reset, so the Status page can say so.
    static func resetInputAccess() -> [String] {
        let failed = failedInputAccessResets()
        for service in failed {
            AppLog.note("install: could not reset \(service) for Steam")
        }
        return failed
    }

    static func failedInputAccessResets() -> [String] {
        inputAccessServices.filter { service in
            let result = try? Shell.run("/usr/bin/tccutil", ["reset", service, "com.valvesoftware.steam"])
            return result?.succeeded != true
        }
    }

}
