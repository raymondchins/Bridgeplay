import Foundation

// Moving a user from an older WineCX release to the current one. Each release has its own
// engine bundle, runner and tool, so installing the current one leaves the older one working
// and selectable. A new runtime has a new build id, so it reads as missing rather than
// outdated, and nothing downloads it unasked (UpdateEverything): the Status page offers it.
enum WinecxUpgrade {

    struct Offer: Equatable, Sendable {
        // Build ids, newest older release set up and the current release.
        let from: String
        let to: String
    }

    // The current release, when it isn't unpacked and an older one is. `builds` runs from
    // the current release to the oldest, as FreeEngineWinecx.releases does.
    static func offer(
        installs: [CrossOverInstall],
        builds: [String] = FreeEngineWinecx.releases.map(\.build)
    ) -> Offer? {
        let unpacked = Set(installs.filter(\.isFree).compactMap(FreeEngineStatus.buildID(of:)))
        guard let current = builds.first, !unpacked.contains(current),
              let older = builds.dropFirst().first(where: unpacked.contains)
        else { return nil }
        return Offer(from: older, to: current)
    }

    static func offer(_ snapshot: StatusSnapshot) -> Offer? {
        offer(installs: snapshot.crossOver)
    }
}

extension FreeEngineWinecx {
    static var currentTool: String? { current.runner.tools.first?.name }

    // The tool of the release that was current before this one.
    static var previousTool: String? {
        releases.first { $0.build != current.build }?.runner.tools.first?.name
    }

    // The tools of every release but the current one.
    static var olderTools: Set<String> {
        Set(releases.filter { $0.build != current.build }.flatMap { $0.runner.tools.map(\.name) })
    }
}
