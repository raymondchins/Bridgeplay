import AppKit
import Foundation
import Observation
import BridgeplayInstallerCore
import BridgeplayUI

@MainActor
@Observable
final class InstallerModel {
    enum Stage: Int { case checking, review, downloading, installing, done, failed }
    var stage: Stage = .checking
    var version = ""
    var installedVersion: String?
    var isCurrent = false
    var progress: Double?
    var received: Int64 = 0
    var total: Int64?
    var speed: Double?
    var paused = false
    @ObservationIgnored private var control = InstallerDownloadControl()
    @ObservationIgnored private var rate = DownloadRate()
    // Steam downloading during the components step, from curl's meter.
    var scriptDownload: InstallerDownloadProgress?
    var failure: String?
    var openBridgeplay = true
    var removeInstaller = true
    var finishing = false
    // Steam, GPTK and the engine, when this Mac lacks them (InstallerComponents).
    var components: InstallerComponents?
    var settingUp = false
    var componentStatus: String?
    // Bytes already downloaded in earlier steps, so progress counts toward one total.
    private var downloadedBefore: Int64 = 0
    let preview: String?
    private var release: InstallerRelease?
    private var operation: Task<Void, Never>?
    private let service: InstallerService
    var destination: URL { service.destination }
    private(set) var cleanupSource: InstallerCleanup.Source?

    static var previewArgument: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--preview"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static var destinationArgument: URL {
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--test-destination"), args.indices.contains(index + 1) {
            let value = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            if value.lastPathComponent == "Bridgeplay.app",
               value.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(temp + "/") { return value }
            fatalError("Test destination must be Bridgeplay.app inside the temporary directory.")
        }
        #endif
        return URL(fileURLWithPath: "/Applications/Bridgeplay.app")
    }

    init(preview: String? = InstallerModel.previewArgument) {
        self.preview = preview
        self.service = InstallerService(destination: Self.destinationArgument)
        if let preview {
            version = "3.4.1"
            switch preview {
            case "update": installedVersion = "3.3.0"; stage = .review
            case "current": installedVersion = version; isCurrent = true; stage = .done
            case "download": stage = .downloading; received = 31_659_404; total = 79_148_511; progress = 0.4; speed = 2_412_000
            case "paused": stage = .downloading; received = 31_659_404; total = 79_148_511; progress = 0.4; paused = true
            case "components": stage = .downloading; settingUp = true; received = 214_958_080; total = 504_399_923; progress = 0.43; speed = 6_815_744
            case "install": stage = .installing
            case "steam":
                stage = .installing; settingUp = true; componentStatus = tr("Installing Steam from Valve")
                scriptDownload = InstallerDownloadProgress(received: 2_202_009, total: 4_404_019, speed: 1_310_720)
            case "done": stage = .done
            case "error": stage = .failed; failure = tr("The download could not be verified. Your installed application has been kept.")
            default: stage = .review
            }
        } else {
            cleanupSource = try? InstallerCleanup.source()
        }
    }

    var busy: Bool { stage == .checking || stage == .downloading || stage == .installing || finishing }
    var updating: Bool { installedVersion != nil }
    var step: Int {
        switch stage { case .checking: 0; case .review, .failed: 1; case .downloading, .installing: 2; case .done: 3 }
    }

    func check() async {
        guard preview == nil else { return }
        stage = .checking
        failure = nil
        InstallerLog.write("Check on \(InstallerLog.system)")
        do {
            let service = self.service
            try await Task.detached(priority: .userInitiated) { try service.recoverIfNeeded() }.value
            try Task.checkCancellation()
            let fetched = try await InstallerRelease.latest()
            try Task.checkCancellation()
            release = fetched
            version = fetched.shortVersion
            components = InstallerComponents.needed() ? try await InstallerComponents.latest() : nil
            try Task.checkCancellation()
            let state = try service.state(for: fetched)
            isCurrent = state.isCurrent
            total = (state.isCurrent ? 0 : fetched.archiveLength) + (components?.length ?? 0)
            InstallerLog.write("Release \(fetched.shortVersion), installed \(state.installedVersion ?? "none"), components \(components == nil ? "present" : "needed")")
            switch state {
            case .notInstalled: installedVersion = nil; stage = .review
            case .updateAvailable(_, let current, _): installedVersion = current; stage = .review
            case .upToDate(_, let current):
                installedVersion = current; version = current
                stage = components == nil ? .done : .review
            }
        } catch is CancellationError {
            stage = .review
        } catch { fail(error) }
    }

    func start() {
        guard operation == nil, let release, preview == nil else { return }
        operation = Task {
            defer { operation = nil }
            stage = .downloading
            settingUp = false
            failure = nil
            InstallerLog.write("Install \(release.shortVersion) to \(destination.path)")
            received = 0
            downloadedBefore = 0
            progress = nil
            speed = nil
            rate = DownloadRate()
            paused = false
            control = InstallerDownloadControl()
            let control = self.control
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeplay-install-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let report: @Sendable (InstallerDownloadProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.stage == .downloading else { return }
                        self.received = self.downloadedBefore + value.received
                        if !self.paused { self.speed = self.rate.add(self.received) ?? self.speed }
                        self.progress = self.total.flatMap { $0 > 0 ? Double(self.received) / Double($0) : nil }
                    }
                }
                if !isCurrent {
                    let archive = try await release.download(to: work, control: control, progress: report)
                    try Task.checkCancellation()
                    stage = .installing
                    progress = nil
                    let service = self.service
                    _ = try await Task.detached(priority: .userInitiated) {
                        try service.install(release: release, archive: archive)
                    }.value
                }
                if let components {
                    settingUp = true
                    downloadedBefore = isCurrent ? 0 : release.archiveLength
                    stage = .downloading
                    let archive = try await components.downloadAcrossRelease(to: work, control: control, progress: report)
                    try Task.checkCancellation()
                    stage = .installing
                    progress = nil
                    componentStatus = nil
                    try await Task.detached(priority: .userInitiated) {
                        try InstallerComponents.install(archive: archive, work: work, status: { line in
                            InstallerLog.write("Components: \(line)")
                            Task { @MainActor [weak self] in self?.componentStatus = Self.status(line); self?.scriptDownload = nil }
                        }, download: { meter in
                            Task { @MainActor [weak self] in self?.scriptDownload = meter }
                        })
                    }.value
                    self.components = nil
                }
                isCurrent = false
                stage = .done
                InstallerLog.write("Done")
            } catch is CancellationError {
                stage = .review
            } catch { fail(error) }
        }
    }

    func togglePause() {
        guard stage == .downloading, preview == nil else { paused.toggle(); return }
        if paused {
            control.resume()
            // Count the speed afresh rather than averaging in the pause.
            rate = DownloadRate()
            speed = nil
            InstallerLog.write("Download resumed")
        } else {
            control.pause()
            InstallerLog.write("Download paused at \(received) bytes")
        }
        paused = control.isPaused
    }

    func cancel() {
        guard stage != .installing else { return }
        operation?.cancel()
    }

    func retry() {
        guard !busy else { return }
        operation = Task { await check(); operation = nil }
    }

    func finish() {
        guard preview == nil, stage == .done, !finishing else { return }
        finishing = true
        if openBridgeplay {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
                Task { @MainActor in
                    if let error { self.failure = error.localizedDescription; self.finishing = false }
                    else { self.finishCleanup() }
                }
            }
        } else { finishCleanup() }
    }

    private func finishCleanup() {
        do {
            if removeInstaller, let cleanupSource { try InstallerCleanup.schedule(cleanupSource) }
            NSApplication.shared.terminate(nil)
        } catch { failure = error.localizedDescription; finishing = false }
    }

    // The components steps (ComponentsPlacement), in the installer's words.
    nonisolated static func status(_ line: String) -> String? {
        if line.contains("Steam") { return tr("Installing Steam from Valve") }
        if line.contains("Game Porting Toolkit") { return tr("Copying Apple's graphics, the engine and settings") }
        return nil
    }

    private func fail(_ error: Error) {
        InstallerLog.write("Failed: \(String(reflecting: error))")
        failure = InstallerMessage.describe(error)
        stage = .failed
    }

    func report() {
        guard let failure, let url = InstallerReport.issueURL(failure: failure, version: version, installed: installedVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([InstallerLog.url])
    }
}
