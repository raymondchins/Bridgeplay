// Clones CrossOver, throws it in bridge, invokes ntdll patch,

import Foundation

enum RunnerSetup {

    enum Phase: Sendable {
        case cloning
        case staging
        case patching
        case finished

        var label: String {
            switch self {
            case .cloning: String(localized: "Copying Wine")
            case .staging: String(localized: "Patching")
            case .patching: String(localized: "Installing compatibility tool")
            case .finished: String(localized: "Done")
            }
        }
    }

    struct Outcome: Sendable {
        let staged: [WineArch]
        let installed: RunnerPatcher.Outcome
        var toolsChanged = false

        var stagedNothing: Bool { staged.isEmpty && installed.wroteNothing && !toolsChanged }
    }

    static func run(
        from install: CrossOverInstall,
        replacingExisting: Bool = false,
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        try CrossOverLicense.requireValid(for: install)

        report(.cloning)
        let build = try RunnerInstaller.clone(from: install, replacingExisting: replacingExisting)
        return try prepare(build, report: report)
    }

    static let prepareStep = String(localized: "Set up compatibility tool")

    static func prepare(
        _ build: RunnerBuild,
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        toolList: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        license: (URL) -> CrossOverLicense.Status = { CrossOverLicense.check(crossOverRoot: $0) },
        verify: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        stage: (RunnerBuild, URL, URL) throws -> [WineArch] = {
            try NtdllPatcher.stage(build: $0, runnerRoot: $1, bridge: $2)
        },
        patch: (RunnerBuild, URL, URL) throws -> RunnerPatcher.Outcome = {
            try RunnerPatcher.install(build: $0, root: $1, bridge: $2)
        },
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        guard RunnerInstaller.hasClone(forBuild: build.id, runners: runners) else {
            throw StepFailure(
                step: prepareStep, detail: String(localized: "Build \(build.displayVersion) has not been set up.")
            )
        }

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let status = license(root)
        guard status.licensed else {
            throw StepFailure(step: String(localized: "Verify CrossOver license"), detail: status.detail)
        }

        try verify(build, root)

        report(.staging)
        let staged = try stage(build, root, bridge)

        report(.patching)
        var outcome = Outcome(staged: staged, installed: try patch(build, root, bridge))
        outcome.toolsChanged = try CompatToolList.sync(
            runners: runners, bridge: bridge, file: toolList, compatTools: compatTools
        )
        for tool in CompatToolList.installed(runners: runners, file: toolList) {
            let run = compatTools.appending(path: "\(tool.name)/run")
            if FileManager.default.fileExists(atPath: run.path(percentEncoded: false)) { continue }
            try SteamInstaller.installIfChanged(DeploymentContent.File(
                source: try runScript(), destination: run, name: "\(tool.name)/run", executable: true))
        }

        report(.finished)
        return outcome
    }
}
