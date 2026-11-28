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
        backoff: Duration = .seconds(3),
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let archive = downloads.appending(path: file)
        let key = archive.path(percentEncoded: false)
        // Two callers of one file (Set Up's prefetch and an install) share one download.
        await DownloadGate.shared.enter(key)
        do {
            let got = try await fetch(file: file, sha256: sha256, bases: bases, archive: archive, step: step,
                                      from: source, session: session, backoff: backoff, report: report)
            await MainActor.run { DownloadMeter.shared.end(key, completed: true) }
            await DownloadGate.shared.leave(key)
            return got
        } catch {
            await MainActor.run { DownloadMeter.shared.end(key, completed: false) }
            await DownloadGate.shared.leave(key)
            throw error
        }
    }

    private static func fetch(
        file: String, sha256: String, bases: [URL], archive: URL, step: String, from source: String,
        session: URLSession, backoff: Duration, report: @Sendable (Progress) -> Void
    ) async throws -> URL {
        let key = archive.path(percentEncoded: false)
        if Digest.sha256IfPresent(archive) == sha256 {
            report(.reusing)
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            await MainActor.run { DownloadMeter.shared.reused(key, bytes: size) }
            return archive
        }

        var refusals: [String] = []
        var kinds: Set<Refusal> = []
        var opened: PartFile?
        defer { opened?.close() }
        hosts: for base in bases {
            var host = base.host() ?? base.absoluteString
            var request = URLRequest(url: base.appending(path: file))
            // Used once: a busy github.com release link is asked for through the API.
            var lookup = githubReleaseLookup(base)
            var busy = 0
            // Set once resumed bytes failed the pin: the same host is asked for the whole file.
            var whole = false
            while true {
                report(.fetching(host: host))
                let part: PartFile
                do {
                    if opened == nil { opened = try await PartFile.open(for: archive, sha256: sha256) }
                    part = opened!
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw writeFailure(error, archive: archive, step: step)
                }
                await MainActor.run { DownloadMeter.shared.start(key, host: host) }
                let outcome: PartOutcome
                do {
                    outcome = try await withoutActuallyEscaping(report) { report in
                        try await body(request, file: file, host: host, sha256: sha256, part: part,
                                       session: session, backoff: backoff, key: key, report: report)
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    refusals.append("\(host): \(error.localizedDescription)")
                    // Another host has no more room on this disk than the first.
                    if Self.outOfSpace(error) {
                        AppLog.note("\(file) from \(host): out of space")
                        throw StepFailure(step: step, detail: outOfSpaceDetail)
                    }
                    kinds.insert(Self.connectionFailed(error) ? .unreachable : .failed)
                    continue hosts
                }

                guard case .done(let resumedFrom) = outcome else {
                    guard case .refused(let http) = outcome else { continue hosts }
                    // #2727: github.com answers a passing 504 now and then, and the engine has
                    // only that one host. Ask it again before giving up on it.
                    let isBusy = http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)
                    if busy < 2, isBusy {
                        busy += 1
                        AppLog.note("\(file) from \(host) answered \(http.statusCode), asking again")
                        try await Task.sleep(for: backoff * busy)
                        continue
                    }
                    refusals.append("\(host) answered \(http.statusCode)")
                    kinds.insert(.answered)
                    // #3059: github.com's download route can stay down for hours while the API
                    // serves the same asset. The pin still decides what is kept.
                    if isBusy, let tags = lookup {
                        lookup = nil
                        AppLog.note("\(file) from \(host) answered \(http.statusCode), trying api.github.com")
                        if let asset = await githubAsset(file, lookup: tags, session: session) {
                            (request, host, busy) = (asset, "api.github.com", 0)
                            continue
                        }
                    }
                    continue hosts
                }

                let got = try Digest.sha256(of: part.url)
                guard got == sha256 else {
                    try? part.reset()
                    if resumedFrom > 0, !whole {
                        whole = true
                        AppLog.note("\(file) from \(host): resumed bytes miss the pin, fetching it whole")
                        continue
                    }
                    refusals.append("\(host) served \(got.prefix(16)) rather than \(sha256.prefix(16))")
                    kinds.insert(.mismatch)
                    continue hosts
                }

                do {
                    try part.install(as: archive)
                } catch {
                    throw writeFailure(error, archive: archive, step: step)
                }
                if resumedFrom > 0 { AppLog.note("\(file) from \(host): resumed at \(resumedFrom) bytes") }
                return archive
            }
        }

        // Bytes that arrived before a drop or a refusal are still good: Try Again resumes them.
        // Only bytes that missed the pin (reset already) leave nothing worth keeping.
        if kinds.isSubset(of: [.mismatch]) { opened?.discard() }
        AppLog.note("\(file) refused by all \(bases.count) hosts: \(refusals.joined(separator: ". "))")
        throw StepFailure(step: step, detail: reason(kinds, from: source))
    }

    // The body from one host into `part`. A dropped connection (or one the server closed
    // during a pause) asks for the rest with Range rather than starting the 440 MB over.
    private static func body(
        _ request: URLRequest, file: String, host: String, sha256: String, part: PartFile,
        session: URLSession, backoff: Duration, key: String, report: @escaping @Sendable (Progress) -> Void
    ) async throws -> PartOutcome {
        let relay = ProgressRelay(host: host, key: key, report: report)
        defer { relay.finish() }
        var attempt = 0
        while true {
            attempt += 1
            let from = part.size
            if from > 0 { AppLog.note("\(file) from \(host): asking for the bytes after \(from)") }
            switch try await PartWriter.fetch(request, into: part, session: session, relay: relay) {
            case .restart:
                // 416: the part may already be whole, from a run that quit before the move.
                if from > 0, (try? Digest.sha256(of: part.url)) == sha256 { return .done(from: from) }
                AppLog.note("\(file) from \(host) can't serve the bytes after \(from), starting again")
                try part.reset()
                guard attempt < 4 else { return .restart }
            case .dropped(let error, let resumable) where resumable && attempt < 4:
                AppLog.note("\(file) from \(host) interrupted (\(error.localizedDescription)), resuming")
                // #279: a Wi-Fi drop spent every try within one second.
                await networkBack(within: .seconds(120))
                try await Task.sleep(for: backoff * attempt)
            case .dropped(let error, _):
                throw error
            case let outcome:
                return outcome
            }
        }
    }

    private static func writeFailure(_ error: Error, archive: URL, step: String) -> StepFailure {
        if outOfSpace(error) { return StepFailure(step: step, detail: outOfSpaceDetail) }
        let downloads = archive.deletingLastPathComponent()
        return StepFailure(
            step: step,
            detail: String(localized: "\(downloads.path(percentEncoded: false)) could not be written. ")
                + error.localizedDescription
        )
    }

    /// The API lookup for a github.com/<owner>/<repo>/releases/download/<tag> base, nil for any other.
    static func githubReleaseLookup(_ base: URL) -> URL? {
        let parts = base.pathComponents
        guard base.scheme == "https", base.host() == "github.com", parts.count == 6,
              parts[3] == "releases", parts[4] == "download" else { return nil }
        return URL(string: "https://api.github.com/repos")!
            .appending(components: parts[1], parts[2], "releases", "tags", parts[5])
    }

    // The asset's API URL, asked for as bytes. Nil when the lookup is refused (a 403 when the
    // 60 an hour unauthenticated limit is spent) or the release has no such file.
    private static func githubAsset(_ file: String, lookup: URL, session: URLSession) async -> URLRequest? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let url: URL }
            let assets: [Asset]
        }
        var ask = URLRequest(url: lookup)
        ask.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: ask)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                AppLog.note("api.github.com answered \(status) to \(lookup.path())")
                return nil
            }
            guard let asset = try JSONDecoder().decode(Release.self, from: data).assets.first(where: { $0.name == file }) else {
                AppLog.note("api.github.com lists no \(file) at \(lookup.path())")
                return nil
            }
            var request = URLRequest(url: asset.url)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            return request
        } catch {
            AppLog.note("api.github.com lookup of \(file) failed: \(error.localizedDescription)")
            return nil
        }
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

    static var outOfSpaceDetail: String {
        let free = SetupChecks.freeBytes().map(SetupChecks.size) ?? "0"
        return String(localized: "Out of space (\(free) free). Free some up and retry.")
    }

    // ENOSPC or Foundation's out-of-space error anywhere in the chain, or the download task's
    // "cannot write to file", which is how a full disk shows up mid-download.
    static func outOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            switch (error.domain, error.code) {
            case (NSPOSIXErrorDomain, Int(ENOSPC)), (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSURLErrorDomain, NSURLErrorCannotWriteToFile):
                return true
            default:
                current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return false
    }

    private enum Refusal {
        case unreachable
        case mismatch
        case answered
        case failed
    }

    // Only these point at the network, a firewall, VPN or proxy. A cancel, a full disk or a
    // file error is not, and must not get that advice.
    static func connectionFailed(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .timedOut, .networkConnectionLost, .secureConnectionFailed, .internationalRoamingOff,
             .dataNotAllowed, .cannotLoadFromNetwork,
             // A proxy that inspects TLS shows its own certificate for every host.
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return true
        default:
            return false
        }
    }

    private static func reason(_ kinds: Set<Refusal>, from source: String) -> String {
        if kinds == [.mismatch] {
            return String(localized: "Something is wrong with the downloaded files. Please check for a Bridgeplay update.")
        }
        if kinds == [.unreachable] {
            return String(localized: """
                Bridgeplay could not reach \(source)'s servers. Check your internet connection. A firewall app \
                (such as LuLu or Little Snitch), VPN or proxy may also be blocking Bridgeplay. Allow it and try again.
                """)
        }
        return String(localized: "Bridgeplay could not download the files it needs from \(source). Please try again later.")
    }
}

/// The running downloads as one bar, with their amount, speed and Pause button. Pinned
/// downloads report per file; a batch (Set Up's prefetch) counts its finished files too, and
/// shows a total only once every file's size is known.
@MainActor @Observable
final class DownloadMeter {
    static let shared = DownloadMeter()
    private(set) var host: String?
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var speed: Double?
    private(set) var remaining: TimeInterval?
    private(set) var paused = false
    // Pauses a download that has no ProgressRelay (the installer components' own session).
    @ObservationIgnored var pauseControl: ((Bool) -> Void)?

    private struct Entry {
        var host: String?
        var received: Int64 = 0
        var total: Int64 = 0
        var live = true
        var finished = false
    }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var batch: [String]?
    @ObservationIgnored private var relays: [String: WeakRelay] = [:]
    @ObservationIgnored private var rate = DownloadRate()

    private struct WeakRelay { weak var relay: ProgressRelay? }

    init() {}

    var fraction: Double? { host != nil && total > 0 ? Double(received) / Double(total) : nil }
    // "Downloading from github.com", for the row above the bar.
    var title: String? { host.map { PinnedDownload.Progress.fetching(host: $0).label } }

    /// One download reported as a whole (the installer components, the Setup preview).
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
        pauseControl = nil
        entries = [:]
        order = []
        batch = nil
        relays = [:]
        rate = DownloadRate()
        (received, total, speed, remaining) = (0, 0, nil, nil)
    }

    /// The files about to download together, by archive path.
    func begin(batch keys: [String]) {
        batch = keys
        for key in keys where entries[key] == nil { entries[key] = Entry(host: nil, live: false); order.append(key) }
        publish()
    }

    func endBatch() {
        batch = nil
        for (key, entry) in entries where !entry.live { entries[key] = nil }
        order.removeAll { entries[$0] == nil }
        publish()
    }

    func start(_ key: String, host: String) {
        if entries[key] == nil { order.append(key) }
        entries[key, default: Entry()].host = host
        entries[key]?.live = true
        entries[key]?.finished = false
        publish()
    }

    func track(_ key: String, host: String, received: Int64, total: Int64) {
        guard var entry = entries[key], !entry.finished else { return }
        (entry.host, entry.received, entry.total, entry.live) = (host, received, total, true)
        entries[key] = entry
        publish()
    }

    /// A file already in the cache, counted as done in the batch.
    func reused(_ key: String, bytes: Int64) {
        guard batch?.contains(key) == true else { return }
        entries[key] = Entry(host: nil, received: bytes, total: bytes, live: false, finished: true)
        publish()
    }

    func end(_ key: String, completed: Bool) {
        relays[key] = nil
        guard var entry = entries[key] else { return }
        if batch?.contains(key) == true {
            entry.live = false
            if completed {
                entry.finished = true
                if entry.total > 0 { entry.received = entry.total }
            }
            entries[key] = entry
        } else {
            entries[key] = nil
            order.removeAll { $0 == key }
        }
        publish()
    }

    fileprivate func attach(_ relay: ProgressRelay, key: String) {
        relays[key] = WeakRelay(relay: relay)
        // Paused between a dropped connection and its resume: stay paused.
        if paused { relay.suspend() }
    }

    func togglePause() {
        guard host != nil else { return }
        paused.toggle()
        if let pauseControl {
            pauseControl(paused)
        } else {
            for relay in relays.values.compactMap(\.relay) { paused ? relay.suspend() : relay.resume() }
        }
        AppLog.note("download \(paused ? "paused" : "resumed") at \(received) of \(total) bytes")
    }

    private func publish() {
        guard !entries.isEmpty else {
            if pauseControl == nil { (host, received, total, speed, remaining, paused) = (nil, 0, 0, nil, nil, false) }
            return
        }
        let shown = order.compactMap { key in entries[key].map { (key, $0) } }
        let hosts = shown.filter { $0.1.live }.compactMap(\.1.host).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        host = hosts.isEmpty ? nil : ListFormatter.localizedString(byJoining: hosts)
        received = shown.reduce(0) { $0 + $1.1.received }
        // Honest only when every file's size is known; until then there is no bar.
        total = shown.allSatisfy({ $0.1.total > 0 }) ? shown.reduce(0) { $0 + $1.1.total } : 0
        speed = paused ? nil : rate.add(received)
        remaining = total > 0 ? speed.flatMap { $0 > 0 ? Double(total - received) / $0 : nil } : nil
        if host == nil && batch == nil { clear() }
    }
}

// Turns a download's byte count into .receiving reports, once per percent, and the meter's
// entry for its file.
final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let key: String
    // A relay with no pinned file opens its own meter entry (Valve's Steam installer).
    private let opensEntry: Bool
    // Dropped by finish(): the caller's closure only lives as long as the download.
    private var report: (@Sendable (PinnedDownload.Progress) -> Void)?
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var task: URLSessionTask?
    private var shown = -1
    private var rate = DownloadRate()

    init(host: String, key: String? = nil, report: @escaping @Sendable (PinnedDownload.Progress) -> Void) {
        self.host = host
        self.key = key ?? "relay-\(UUID().uuidString)"
        opensEntry = key == nil
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // The task's own byte counts: on macOS 27 task.progress counts 100 units, not bytes, and
        // sits at 5 until the body is done, so the bar read "5 bytes / 100 bytes" for the whole engine.
        let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
            self?.progress(received: task.countOfBytesReceived, total: task.countOfBytesExpectedToReceive)
        }
        lock.withLock { self.observation = observation }
        attach(task)
    }

    /// The task Pause suspends.
    func attach(_ task: URLSessionTask) {
        lock.withLock { self.task = task }
        let (key, host, opens) = (key, host, opensEntry)
        Task { @MainActor in
            let meter = DownloadMeter.shared
            if opens { meter.start(key, host: host) }
            meter.attach(self, key: key)
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

    func progress(received: Int64, total: Int64) {
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
            let (host, key) = (host, key)
            Task { @MainActor in
                DownloadMeter.shared.track(key, host: host, received: received, total: total)
            }
        }
    }
}
