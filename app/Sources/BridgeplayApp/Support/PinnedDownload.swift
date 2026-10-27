// Download one hash pinned file from a list of CDN hosts

import BridgeplayUI
import Foundation
import Network
import Observation

enum PinnedDownload {

    enum Progress: Sendable {
        case reusing
        case fetching(host: String)
        case receiving(host: String, received: Int64, total: Int64, remaining: TimeInterval?, speed: Double? = nil)

        var label: String {
            switch self {
            case .reusing: String(localized: "Preparing")
            case .fetching(let host): String(localized: "Downloading from \(host)")
            case .receiving(let host, let received, let total, let remaining, let speed):
                Self.label(host: host, received: received, total: total, remaining: remaining, speed: speed)
            }
        }

        static func label(host: String, received: Int64, total: Int64, remaining: TimeInterval?, speed: Double? = nil) -> String {
            let amount = DownloadRate.amount(received: received, total: total, speed: speed)
            guard let left = remaining.flatMap(duration) else {
                return String(localized: "Downloading from \(host): \(amount)")
            }
            return String(localized: "Downloading from \(host): \(amount), about \(left) left")
        }

        // "2 minutes"; seconds only near the end, so the estimate doesn't tick every second.
        static func duration(_ remaining: TimeInterval) -> String? {
            let time = DateComponentsFormatter()
            time.unitsStyle = .full
            time.maximumUnitCount = 1
            time.allowedUnits = [.hour, .minute, .second]
            let rounded = remaining < 60 ? remaining : (remaining / 60).rounded(.up) * 60
            return time.string(from: max(rounded, 1))
        }
    }

    // The engine is about 440 MB: three hours still finishes it at about 42 KB/s. Stalls
    // fail sooner on the 60 second idle timeout.
    static let session = session(deadline: 3 * 60 * 60)

    static func session(deadline: TimeInterval, protocols: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = deadline
        config.protocolClasses = protocols + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    static func obtain(
        file: String,
        sha256: String,
        bases: [URL],
        into downloads: URL,
        step: String,
        from source: String = "Valve",
        session: URLSession = PinnedDownload.session,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let archive = downloads.appending(path: file)
        if Digest.sha256IfPresent(archive) == sha256 {
            report(.reusing)
            return archive
        }

        var refusals: [String] = []
        var kinds: Set<Refusal> = []
        for base in bases {
            let host = base.host() ?? base.absoluteString
            report(.fetching(host: host))
            let body: URL, response: URLResponse
            do {
                (body, response) = try await withoutActuallyEscaping(report) { report in
                    // A dropped connection (or one the server closed during a pause) resumes
                    // where it stopped rather than starting the 440 MB over.
                    defer { Task { @MainActor in DownloadMeter.shared.clear() } }
                    var resumeData: Data?
                    for attempt in 1... {
                        let relay = ProgressRelay(host: host, report: report)
                        defer { relay.finish() }
                        do {
                            if let resumeData { return try await session.download(resumeFrom: resumeData, delegate: relay) }
                            return try await session.download(from: base.appending(path: file), delegate: relay)
                        } catch let error as URLError where attempt < 4 && error.downloadTaskResumeData != nil {
                            resumeData = error.downloadTaskResumeData
                            AppLog.note("\(file) from \(host) interrupted (\(error.localizedDescription)), resuming")
                            // #279: a Wi-Fi drop spent every try within one second.
                            await networkBack(within: .seconds(120))
                            try await Task.sleep(for: .seconds(2 * attempt))
                        }
                    }
                    fatalError("unreachable")
                }
            } catch {
                refusals.append("\(host): \(error.localizedDescription)")
                kinds.insert(.unreachable)
                continue
            }
            defer { try? FileManager.default.removeItem(at: body) }

            // 206: resumed after a dropped connection.
            if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
                refusals.append("\(host) answered \(http.statusCode)")
                kinds.insert(.answered)
                continue
            }

            let got = try Digest.sha256(of: body)
            guard got == sha256 else {
                refusals.append("\(host) served \(got.prefix(16)) rather than \(sha256.prefix(16))")
                kinds.insert(.mismatch)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: downloads, withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: body, to: archive)
            } catch {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(downloads.path(percentEncoded: false)) could not be written. ")
                        + error.localizedDescription
                )
            }
            return archive
        }

        AppLog.note("\(file) refused by all \(bases.count) hosts: \(refusals.joined(separator: ". "))")
        throw StepFailure(step: step, detail: reason(kinds, from: source))
    }

    /// Returns once macOS reports a usable network, or after `limit`.
    static func networkBack(within limit: Duration) async {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let online = AsyncStream<Void> { stream in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { stream.yield(); stream.finish() }
            }
            monitor.start(queue: .global(qos: .utility))
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in online { return } }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
        if monitor.currentPath.status != .satisfied {
            AppLog.note("network still down after \(limit), trying anyway")
        }
    }

    private enum Refusal {
        case unreachable
        case mismatch
        case answered
    }

    private static func reason(_ kinds: Set<Refusal>, from source: String) -> String {
        if kinds == [.mismatch] {
            return String(localized: "Something is wrong with the downloaded files. Please check for a Bridgeplay update.")
        }
        if kinds == [.unreachable] {
            return String(localized: "Bridgeplay could not reach \(source)'s servers. Please check your internet connection and try again.")
        }
        return String(localized: "Bridgeplay could not download the files it needs from \(source). Please try again later.")
    }
}

/// The running download, for the bar with its amount, speed and Pause button. Downloads run one at a time.
@MainActor @Observable
final class DownloadMeter {
    static let shared = DownloadMeter()
    private(set) var host: String?
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var speed: Double?
    private(set) var remaining: TimeInterval?
    private(set) var paused = false
    @ObservationIgnored fileprivate weak var relay: ProgressRelay?

    var fraction: Double? { host != nil && total > 0 ? Double(received) / Double(total) : nil }
    // "Downloading from github.com", for the row above the bar.
    var title: String? { host.map { PinnedDownload.Progress.fetching(host: $0).label } }

    func update(host: String, received: Int64, total: Int64, speed: Double?, remaining: TimeInterval?) {
        self.host = host
        self.received = received
        self.total = total
        self.speed = speed
        self.remaining = remaining
    }

    func clear() {
        host = nil
        paused = false
        relay = nil
    }

    func togglePause() {
        guard host != nil else { return }
        paused.toggle()
        paused ? relay?.suspend() : relay?.resume()
        AppLog.note("download \(paused ? "paused" : "resumed") at \(received) of \(total) bytes")
    }
}

// Turns the task's byte count into .receiving reports, once per percent, and DownloadMeter's bar.
final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    // Dropped by finish(): the caller's closure only lives as long as the download.
    private var report: (@Sendable (PinnedDownload.Progress) -> Void)?
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var task: URLSessionTask?
    private var shown = -1
    private var rate = DownloadRate()

    init(host: String, report: @escaping @Sendable (PinnedDownload.Progress) -> Void) {
        self.host = host
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // The task's own byte counts: on macOS 27 task.progress counts 100 units, not bytes, and
        // sits at 5 until the body is done, so the bar read "5 bytes / 100 bytes" for the whole engine.
        let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.update(received: task.countOfBytesReceived, total: task.countOfBytesExpectedToReceive)
        }
        lock.withLock { self.observation = observation; self.task = task }
        Task { @MainActor in
            let meter = DownloadMeter.shared
            meter.relay = self
            // Paused between a dropped connection and its resume: stay paused.
            if meter.paused { self.suspend() }
        }
    }

    func suspend() { lock.withLock { task?.suspend() } }
    func resume() { lock.withLock { task?.resume() } }

    func finish() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
            report = nil
            task = nil
        }
    }

    private func update(received: Int64, total: Int64) {
        guard total > 0, received <= total else { return }
        let percent = Int(received * 100 / total)
        // Reported under the lock, so finish() can't drop the closure mid-call.
        lock.withLock {
            guard percent != shown, let report else { return }
            shown = percent
            let speed = rate.add(received)
            // From the recent speed, so a pause doesn't stretch the estimate.
            let remaining = speed.flatMap { $0 > 0 ? Double(total - received) / $0 : nil }
            report(.receiving(host: host, received: received, total: total, remaining: remaining, speed: speed))
            let host = host
            Task { @MainActor in
                DownloadMeter.shared.update(host: host, received: received, total: total, speed: speed, remaining: remaining)
            }
        }
    }
}
