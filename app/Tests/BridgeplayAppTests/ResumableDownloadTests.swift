import Foundation
import Testing

@testable import BridgeplayApp

// F1a: downloads keep their bytes in <file>.part and ask for the rest with Range, two callers
// share one download, and Set Up's files run side by side. Hosts are URLProtocol stubs.
@Suite("Resumable download")
struct ResumableDownloadTests {

    // https://ranged.invalid/<key>/<mode>/package.tar serves `body` with Range, an ETag and
    // Accept-Ranges. Modes: "ranges" (plain), "drop" (the first request ends halfway),
    // "ignore" (always 200, whole body), "slow" (1 KB every 5 ms), "stall" (16 KB of it, then nothing).
    private final class Ranged: URLProtocol, @unchecked Sendable {
        static let body = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 8) })
        static let etag = "\"v1\""
        private static let lock = NSLock()
        nonisolated(unsafe) private static var seen: [String: [(range: String, ifRange: String)]] = [:]
        static func asked(_ key: String) -> [(range: String, ifRange: String)] { lock.withLock { seen[key] ?? [] } }
        private var timer: DispatchSourceTimer?

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "ranged.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!, key = url.pathComponents[1], mode = url.pathComponents[2]
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let count = Self.lock.withLock {
                Self.seen[key, default: []].append((range, request.value(forHTTPHeaderField: "If-Range") ?? ""))
                return Self.seen[key]!.count
            }
            var start = 0
            if mode != "ignore", range.hasPrefix("bytes="), range.hasSuffix("-") { start = Int(range.dropFirst(6).dropLast()) ?? 0 }
            let slice = Data(Self.body[start...])
            var headers = ["Accept-Ranges": "bytes", "ETag": Self.etag, "Content-Length": "\(slice.count)"]
            if start > 0 { headers["Content-Range"] = "bytes \(start)-\(Self.body.count - 1)/\(Self.body.count)" }
            let response = HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            switch mode {
            case "drop" where count == 1:
                client?.urlProtocol(self, didLoad: slice.prefix(slice.count / 2))
                // After the bytes have landed, as a real drop would be.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
            case "slow", "stall":
                // "stall" stops after 16 KB and waits to be cancelled.
                let stop = mode == "stall" ? 16_384 : slice.count
                var sent = 0
                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now(), repeating: .milliseconds(5))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    guard sent < stop else { return }
                    let end = min(sent + 1024, stop)
                    self.client?.urlProtocol(self, didLoad: slice.subdata(in: sent..<end))
                    sent = end
                    if sent >= slice.count {
                        self.timer?.cancel()
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
                timer.resume()
                self.timer = timer
            default:
                client?.urlProtocol(self, didLoad: slice)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() { timer?.cancel() }
    }

    private let sha = Digest.sha256(of: Ranged.body)

    private func obtain(_ mode: String, key: String, into downloads: URL, sha256: String? = nil) async throws -> URL {
        try await PinnedDownload.obtain(
            file: "package.tar", sha256: sha256 ?? sha,
            bases: [URL(string: "https://ranged.invalid/\(key)/\(mode)/")!],
            into: downloads, step: "test",
            session: PinnedDownload.session(deadline: 30, protocols: [Ranged.self]), backoff: .zero)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    // Not URL.resourceValues, which keeps the first answer.
    private func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // Bytes left in <downloads>/package.tar.part as a run that quit would leave them.
    private func leavePart(_ bytes: Data, in downloads: URL, pin: String) async throws {
        let part = try await PartFile.open(for: downloads.appending(path: "package.tar"), sha256: pin)
        try part.append(bytes)
        try part.record(validator: Ranged.etag)
        part.close()
    }

    @Test("A dropped connection asks for the rest with Range, not the whole file again")
    func dropResumesWithRange() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString, downloads = work.appending(path: "downloads")

        let got = try await obtain("drop", key: key, into: downloads)

        #expect(try Data(contentsOf: got) == Ranged.body)
        #expect(Ranged.asked(key).map(\.range) == ["", "bytes=\(Ranged.body.count / 2)-"])
        #expect(Ranged.asked(key).last?.ifRange == Ranged.etag)
        #expect(!exists(PartFile.path(for: got)))
    }

    @Test("A cancelled download keeps its bytes, and the next run resumes them")
    func cancelledDownloadResumesLater() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let downloads = work.appending(path: "downloads")
        let part = PartFile.path(for: downloads.appending(path: "package.tar"))

        let first = Task { try await obtain("stall", key: UUID().uuidString, into: downloads) }
        var have: Int64 = 0
        for _ in 0..<500 where have < 8192 {
            try await Task.sleep(for: .milliseconds(10))
            have = size(part)
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        let kept = size(part)
        #expect(kept >= 8192 && kept < Int64(Ranged.body.count))
        #expect(!exists(downloads.appending(path: "package.tar")), "a partial file was put in place")

        let key = UUID().uuidString
        let got = try await obtain("ranges", key: key, into: downloads)
        #expect(try Data(contentsOf: got) == Ranged.body)
        #expect(Ranged.asked(key).map(\.range) == ["bytes=\(kept)-"])
        #expect(Ranged.asked(key).first?.ifRange == Ranged.etag)
    }

    @Test("Resumed bytes that miss the pin are dropped and the file is fetched whole")
    func badPartIsFetchedWhole() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString, downloads = work.appending(path: "downloads")
        try await leavePart(Data(repeating: 0, count: 32_768), in: downloads, pin: sha)

        let got = try await obtain("ranges", key: key, into: downloads)

        #expect(try Data(contentsOf: got) == Ranged.body)
        #expect(Ranged.asked(key).map(\.range) == ["bytes=32768-", ""])
    }

    @Test("A server that ignores Range sends the whole file, which replaces the part")
    func ignoredRangeStartsOver() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString, downloads = work.appending(path: "downloads")
        try await leavePart(Ranged.body.prefix(1000), in: downloads, pin: sha)

        let got = try await obtain("ignore", key: key, into: downloads)

        #expect(try Data(contentsOf: got) == Ranged.body)
        #expect(Ranged.asked(key).map(\.range) == ["bytes=1000-"])
    }

    @Test("Bytes kept for another pin are not resumed")
    func partForAnotherPinIsDropped() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString, downloads = work.appending(path: "downloads")
        try await leavePart(Ranged.body.prefix(1000), in: downloads, pin: String(repeating: "a", count: 64))

        _ = try await obtain("ranges", key: key, into: downloads)

        #expect(Ranged.asked(key).map(\.range) == [""])
    }

    @Test("A whole file that misses its pin leaves neither the file nor a part")
    func mismatchLeavesNothing() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let downloads = work.appending(path: "downloads")

        await #expect(throws: StepFailure.self) {
            _ = try await obtain("ranges", key: UUID().uuidString, into: downloads, sha256: String(repeating: "0", count: 64))
        }
        let archive = downloads.appending(path: "package.tar")
        #expect(!exists(archive))
        #expect(!exists(PartFile.path(for: archive)))
    }

    @Test("Two callers of one file share one download")
    func twoCallersOneDownload() async throws {
        let work = try scratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString, downloads = work.appending(path: "downloads")

        async let first = obtain("slow", key: key, into: downloads)
        async let second = obtain("slow", key: key, into: downloads)
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(try Data(contentsOf: a) == Ranged.body)
        #expect(Ranged.asked(key).count == 1)
    }

    private func pinned(_ name: String) -> SetupPrefetch.Pinned {
        .init(file: name, sha256: "", bases: [], into: URL(filePath: "/nonexistent"), step: "test", source: "test")
    }

    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, most = 0, ended = 0
        func enter() { lock.withLock { now += 1; most = max(most, now) } }
        func leave() { lock.withLock { now -= 1; ended += 1 } }
        var peak: Int { lock.withLock { most } }
        var finished: Int { lock.withLock { ended } }
    }

    @Test("Set Up's files download side by side, no more than the limit at once")
    func prefetchRunsInParallel() async throws {
        let running = Running()
        try await SetupPrefetch.run(["a", "b", "c", "d", "e"].map(pinned), limit: 3) { _ in
            running.enter()
            defer { running.leave() }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(running.peak == 3)
        #expect(running.finished == 5)
    }

    @Test("A failed file stops the others instead of waiting for them")
    func prefetchFailureCancelsTheRest() async throws {
        struct Refused: Error {}
        let stopped = Running()
        await #expect(throws: Refused.self) {
            try await SetupPrefetch.run(["a", "b", "c"].map(pinned)) { file in
                if file.file == "a" { throw Refused() }
                do { try await Task.sleep(for: .seconds(60)) } catch is CancellationError { stopped.enter(); throw CancellationError() }
            }
        }
        #expect(stopped.peak >= 1, "the other files ran on after the failure")
    }

    @MainActor @Test("The bar counts every file of a batch, and shows a total only once each size is known")
    func meterCombinesFiles() {
        let meter = DownloadMeter()
        meter.begin(batch: ["/c/engine", "/c/dxmt", "/c/valve"])
        meter.reused("/c/valve", bytes: 50)
        meter.start("/c/engine", host: "github.com")
        meter.track("/c/engine", host: "github.com", received: 100, total: 400)
        #expect(meter.fraction == nil, "a total without the DXMT file's size")

        meter.start("/c/dxmt", host: "github.com")
        meter.track("/c/dxmt", host: "github.com", received: 10, total: 50)
        #expect(meter.received == 160)
        #expect(meter.total == 500)
        #expect(meter.title == "Downloading from github.com")

        meter.end("/c/dxmt", completed: true)
        #expect(meter.received == 200)
        // A late report from a finished file does not move it back.
        meter.track("/c/dxmt", host: "github.com", received: 20, total: 50)
        #expect(meter.received == 200)

        meter.end("/c/engine", completed: true)
        meter.endBatch()
        #expect(meter.fraction == nil)
        #expect(meter.host == nil)
    }

    @MainActor @Test("Files from two hosts name both")
    func meterNamesEveryHost() {
        let meter = DownloadMeter()
        meter.start("/c/engine", host: "github.com")
        meter.start("/c/valve", host: "steamcdn-a.akamaihd.net")
        meter.track("/c/engine", host: "github.com", received: 1, total: 10)
        meter.track("/c/valve", host: "steamcdn-a.akamaihd.net", received: 1, total: 10)
        #expect(meter.host?.contains("github.com") == true)
        #expect(meter.host?.contains("steamcdn-a.akamaihd.net") == true)
        #expect(meter.total == 20)
        meter.end("/c/engine", completed: true)
        meter.end("/c/valve", completed: true)
        #expect(meter.host == nil)
    }

    @Test("Content-Range is read for its start and total")
    func readsContentRange() {
        #expect(PartWriter.contentRange("bytes 100-199/200").map { [$0.start, $0.total ?? -1] } == [100, 200])
        #expect(PartWriter.contentRange("bytes 5-9/*").map { [$0.start, $0.total ?? -1] } == [5, -1])
        #expect(PartWriter.contentRange("items 1-2/3") == nil)
        #expect(PartWriter.contentRange(nil) == nil)
    }
}
