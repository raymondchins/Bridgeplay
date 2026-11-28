// I Love Logs

import Foundation

enum AppLog {

    static var file: URL { SupportPaths.support.appending(path: "app.log") }

    private static let sizeLimit = 512 * 1024

    private static let queue = DispatchQueue(label: "bridgeplay.applog")

    private nonisolated(unsafe) static var isOn = false
    // Off after Remove Everything: a log line must not bring the removed folder back.
    private nonisolated(unsafe) static var makesFolder = true

    static func stopMakingFolder() { queue.sync { makesFolder = false } }

    static func start() {
        queue.async {
            isOn = true
            append("--- \(ProductVersion.display) started ---\n")
        }
    }

    static func note(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        queue.async { append(line) }
    }

    // The command line paths exit() as soon as they finish, which would drop queued lines,
    // so they pass their exit status through here first.
    static func finished(_ status: Int32) -> Int32 {
        note("command line: exit \(status)")
        queue.sync {}
        return status
    }

    static func note(_ snapshot: StatusSnapshot) {
        var lines = [
            "state steam=\(describe(snapshot.steam))",
            "state steamRunning=\(snapshot.steamRunning) updatesBlocked=\(snapshot.updateBlocked)",
            "state runner=\(describe(snapshot.runner))",
            "state steamHealth=\(snapshot.health.freshness) mode=\(snapshot.health.health?.mode.rawValue ?? "none") "
                + "strikes=\(snapshot.health.health?.strikes ?? snapshot.health.bootStrikes ?? 0) paused=\(snapshot.health.paused) "
                + "steamBuild=\(snapshot.health.health?.steamBuild ?? "none")",
            "state installContent=\(snapshot.installContent)",
        ]

        if snapshot.crossOver.isEmpty {
            lines.append("state crossOver=none found")
        }
        for install in snapshot.crossOver {
            lines.append(
                "state crossOver \(install.name) version=\(install.releaseVersion ?? "unreadable") "
                    + "support=\(describe(install.support))"
                    + (install.isManual ? " chosen" : "")
                    + " at=\(install.bundle.path(percentEncoded: false))"
            )
        }

        let payload = snapshot.payload
        lines.append(
            "state payload staged=\(payload.present)/\(payload.expected) "
                + "overlayShim=\(payload.overlayShimPresent) "
                + "iconmaker=\(payload.iconmakerPresent) "
                + "appinfo=\(payload.appinfoPresent) "
                + "signatures=\(payload.signatureDatabase ?? "none") "
                + "legacycompat=\(payload.legacyCompatPresent)/\(payload.legacyCompatExpected)"
        )
        for entry in payload.missing {
            lines.append("state payload missing \(entry.origin) \(entry.path)")
        }
        if let problem = payload.manifestProblem {
            lines.append("state payload manifest problem: \(problem)")
        }

        for line in lines { note(line) }
    }

    private static func describe(_ steam: SteamDeployment) -> String {
        switch steam {
        case .steamMissing: "no Steam.app"
        case .notInstalled: "not installed"
        case .installed(let version): "installed \(version ?? "version unknown")"
        case .outdated(let deployed, let bundled): "outdated deployed=\(deployed) bundled=\(bundled)"
        case .foreign(let insert): "foreign insert \(insert)"
        }
    }

    private static func describe(_ runner: RunnerState) -> String {
        switch runner {
        case .none: "not set up"
        case .ready(let builds): "ready \(builds.joined(separator: ", "))"
        case .unpatched(_, let problems):
            "unpatched: \(problems.joined(separator: ", "))"
        }
    }

    private static func describe(_ support: CrossOverSupport) -> String {
        switch support {
        case .supported(let build): "supported \(build.id)"
        case .unsupportedBuild(let version): "unsupported build \(version)"
        case .unreadable: "unreadable"
        }
    }

    private static func append(_ line: String) {
        guard isOn else { return }
        let fm = FileManager.default
        guard makesFolder || fm.fileExists(atPath: SupportPaths.support.path(percentEncoded: false)) else { return }
        try? fm.createDirectory(at: SupportPaths.support, withIntermediateDirectories: true)

        let path = file.path(percentEncoded: false)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > sizeLimit {
            try? fm.removeItem(at: file)
        }

        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? data.write(to: file)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
