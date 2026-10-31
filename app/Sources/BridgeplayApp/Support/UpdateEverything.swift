import Foundation

// Brings everything this Bridgeplay ships up to date in one go: the patch inside Steam, then
// every engine that is unpacked but no longer matches this build's pins (a release that
// rebuilt a Wine file). It uses the Status page's own buttons, so it refuses what they
// refuse, and it does nothing while Steam, a game or a Wine tool runs; the Status rows keep
// offering the update until then. An engine the user never set up is left alone, and so is
// a newer runtime: it has a new build id, so it reads as missing.
extension SystemStatus {

    enum UpdatePlan: Equatable, Sendable {
        case steamPatch
        case winecx
        case winehq
    }

    nonisolated static func updatePlan(
        steam: SteamDeployment,
        hasRunner: Bool,
        winecx: FreeEngineState,
        winehq: FreeEngineState
    ) -> [UpdatePlan] {
        var plan: [UpdatePlan] = []
        if hasRunner, case .outdated(let deployed, let bundled) = steam, !deployed.isEmpty, deployed != bundled {
            plan.append(.steamPatch)
        }
        if winecx == .outdated { plan.append(.winecx) }
        if winehq == .outdated { plan.append(.winehq) }
        return plan
    }

    // The launch passes includingSteamPatch false: PostUpdateRefresh owns that, with its
    // stricter rule about which version may re-patch Steam unasked.
    func updateEverything(includingSteamPatch: Bool = true) async {
        guard canInstall, let snapshot else { return }
        let plan = Self.updatePlan(
            steam: snapshot.steam,
            hasRunner: snapshot.runner != .none,
            winecx: freeEngineState(FreeEngineWinecx.current.build),
            winehq: freeEngineState(FreeEngine.current.build)
        ).filter { includingSteamPatch || $0 != .steamPatch }
        guard !plan.isEmpty else { return }

        // pgrep and ps can take seconds, so neither runs on the main actor.
        let busy = await Task.detached(priority: .utility) {
            SteamBundle.isRunning || RunnerInstaller.runningBuild() != nil
        }.value
        if snapshot.steamRunning || busy {
            AppLog.note("update: \(plan) waiting for Steam and games to close")
            return
        }

        AppLog.note("update: \(plan)")
        for step in plan {
            guard canInstall else { return }
            switch step {
            case .steamPatch: await requestInstall(unattended: true)
            case .winecx: await installWinecxEngine()
            case .winehq: await installFreeEngine()
            }
        }
    }
}
