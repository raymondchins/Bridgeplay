// The bytes of one pinned download kept on disk as <file>.part, so a drop or a relaunch asks
// for the rest with HTTP Range instead of starting over. Only a whole file that matches its
// pin is moved to <file>; nothing reads a .part as an archive.

import Darwin
import Foundation

/// <file>.part and its <file>.part.pin sidecar: the pin the bytes are for and the server's
/// validator, sent back as If-Range so a changed file is not stitched onto old bytes.
final class PartFile: @unchecked Sendable {
    let url: URL
    private let pin: URL
    private let sha256: String
    private let handle: FileHandle
    private let lock = NSLock()
    // Another process holds <file>.part: this one downloads into its own, without resuming.
    let isPrivate: Bool

    static func path(for archive: URL) -> URL { archive.appendingPathExtension("part") }

    /// The part for `archive`. Another process holding it is waited for a second, then this
    /// download goes to a part of its own.
    static func open(for archive: URL, sha256: String) async throws -> PartFile {
        for _ in 0..<20 {
            if let part = try PartFile(for: archive, sha256: sha256, ownIfBusy: false) { return part }
            try await Task.sleep(for: .milliseconds(50))
        }
        AppLog.note("\(archive.lastPathComponent).part is held by another process, downloading it without resume")
        return try PartFile(for: archive, sha256: sha256, ownIfBusy: true)!
    }

    private init?(for archive: URL, sha256: String, ownIfBusy: Bool) throws {
        let shared = Self.path(for: archive)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = Self.openLocked(shared) {
            (url, self.handle, isPrivate) = (shared, handle, false)
        } else {
            guard ownIfBusy else { return nil }
            let own = archive.deletingLastPathComponent()
                .appending(path: ".\(archive.lastPathComponent).\(UUID().uuidString).part")
            guard let handle = Self.openLocked(own) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: own.path]) }
            (url, self.handle, isPrivate) = (own, handle, true)
        }
        pin = url.appendingPathExtension("pin")
        self.sha256 = sha256
        // Bytes for another pin, or with no record of which pin, are not resumed.
        if stored.first != sha256 { try reset() }
    }

    // O_EXLOCK: one writer per part across processes (the app and its CLI), released on close.
    // Nil only when another process holds it; a volume without locks opens it unlocked.
    private static func openLocked(_ url: URL) -> FileHandle? {
        let path = url.path(percentEncoded: false)
        var fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
        if fd < 0, errno == ENOTSUP || errno == EOPNOTSUPP { fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) }
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private var stored: [String] {
        (try? String(contentsOf: pin, encoding: .utf8))?.components(separatedBy: "\n") ?? []
    }

    /// The bytes already on disk.
    var size: Int64 { lock.withLock { Int64((try? handle.seekToEnd()) ?? 0) } }

    /// ETag or Last-Modified from the response that wrote these bytes.
    var validator: String? {
        let lines = stored
        return lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
    }

    func reset() throws {
        try lock.withLock { try handle.truncate(atOffset: 0) }
        try record(validator: nil)
    }

    func record(validator: String?) throws {
        try Data("\(sha256)\n\(validator ?? "")\n".utf8).write(to: pin, options: .atomic)
    }

    func append(_ data: Data) throws {
        try lock.withLock {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    /// Moves the checked bytes to `archive`; the part is gone after.
    func install(as archive: URL) throws {
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: url, to: archive)
        try? FileManager.default.removeItem(at: pin)
    }

    func discard() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: pin)
    }

    // A private part is never resumed, so it does not outlive this download.
    func close() {
        try? handle.close()
        if isPrivate { discard() }
    }
}

/// How one request for a part ended.
enum PartOutcome: Sendable {
    // The body is complete; it was asked for from this byte.
    case done(from: Int64)
    // A status other than 200 or 206; nothing was written.
    case refused(HTTPURLResponse)
    // The server can't serve the rest (416, or a range other than the one asked for).
    case restart
    // The connection ended before the body; `resumable` when the server takes ranges.
    case dropped(Error, resumable: Bool)
}

/// One data task writing into a PartFile, from the byte the part ends at.
final class PartWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let part: PartFile
    private let from: Int64
    private let relay: ProgressRelay
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PartOutcome, Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var accepted = false
    private var resumable = false
    private var ended: PartOutcome?
    private var writeError: Error?
    private var written: Int64 = 0
    private var total: Int64 = 0

    private init(part: PartFile, relay: ProgressRelay) {
        self.part = part
        self.relay = relay
        from = part.size
    }

    static func fetch(_ base: URLRequest, into part: PartFile, session: URLSession, relay: ProgressRelay) async throws -> PartOutcome {
        let writer = PartWriter(part: part, relay: relay)
        var request = base
        if writer.from > 0 {
            request.setValue("bytes=\(writer.from)-", forHTTPHeaderField: "Range")
            if let validator = part.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = writer
                writer.lock.withLock {
                    writer.continuation = continuation
                    writer.task = task
                }
                relay.attach(task)
                if writer.lock.withLock({ writer.cancelled }) { task.cancel() }
                task.resume()
            }
        } onCancel: {
            writer.lock.withLock {
                writer.cancelled = true
                return writer.task
            }?.cancel()
        }
    }

    // "bytes 100-199/200" -> (100, 200); the total may be "*".
    static func contentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard spec.count == 2, let start = spec[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
        return (start, Int64(spec[1]))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let expected = response.expectedContentLength
        var disposition = URLSession.ResponseDisposition.allow
        lock.withLock {
            // file: and other non-HTTP hosts send the whole file and ignore Range.
            guard let http = response as? HTTPURLResponse else {
                start(fromZero: true, total: expected, validator: nil)
                return
            }
            let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
            let etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
            let validator = etag ?? http.value(forHTTPHeaderField: "Last-Modified")
            switch http.statusCode {
            case 206:
                guard from > 0, let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")), range.start == from else {
                    ended = .restart
                    disposition = .cancel
                    return
                }
                resumable = true
                isRanged = true
                start(fromZero: false, total: range.total ?? (expected > 0 ? from + expected : -1), validator: validator)
            case 200:
                resumable = ranges
                start(fromZero: true, total: expected, validator: validator)
            case 416 where from > 0:
                ended = .restart
                disposition = .cancel
            default:
                ended = .refused(http)
                disposition = .cancel
            }
        }
        completionHandler(disposition)
    }

    // Under the lock.
    private func start(fromZero: Bool, total: Int64, validator: String?) {
        do {
            if fromZero, from > 0 { try part.reset() }
            try part.record(validator: validator)
            accepted = true
            self.total = total
        } catch {
            writeError = error
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard accepted, writeError == nil else { return }
            do {
                try part.append(data)
                written += Int64(data.count)
            } catch {
                writeError = error
                task?.cancel()
            }
        }
        let (received, total) = lock.withLock { (offset + written, self.total) }
        relay.progress(received: received, total: total)
    }

    // A 206 for the bytes after `from`; otherwise the body is the whole file.
    private var isRanged = false
    private var offset: Int64 { isRanged ? from : 0 }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome): (CheckedContinuation<PartOutcome, Error>?, Result<PartOutcome, Error>) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            if let ended { return (continuation, .success(ended)) }
            if let writeError { return (continuation, .failure(writeError)) }
            if let error {
                if cancelled { return (continuation, .failure(CancellationError())) }
                return (continuation, .success(.dropped(error, resumable: resumable && part.size > 0)))
            }
            return (continuation, .success(.done(from: isRanged ? from : 0)))
        }
        continuation?.resume(with: outcome)
    }
}

/// One download per archive at a time in this process: a second caller waits, then finds
/// the first one's file by its pin.
actor DownloadGate {
    static let shared = DownloadGate()
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func enter(_ key: String) async {
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    func leave(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(key)
        }
    }
}
