import Foundation
import Testing

@testable import BridgeplayApp

// The pin is the only thing between a substituted download and code that gets unpacked and
// run, and it had no test of its own. Hosts are file URLs, so none of this needs the network.
@Suite("Pinned download")
struct PinnedDownloadTests {

    // The progress closure is Sendable, so what it records has to be too.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ s: String) { lock.lock(); seen.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    // A host directory holding one file under the name the download asks for.
    private func host(_ root: URL, named: String, serving bytes: String) throws -> URL {
        let dir = root.appending(path: "host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: dir.appending(path: named))
        return dir
    }

    private func obtain(
        bases: [URL], into downloads: URL, sha256: String, file: String = "package.tar"
    ) async throws -> URL {
        try await PinnedDownload.obtain(
            file: file, sha256: sha256, bases: bases, into: downloads, step: "test"
        )
    }

    @Test("Bytes that match the pin are kept")
    func keepsMatchingBytes() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let serving = try host(work, named: "package.tar", serving: body)
        let downloads = work.appending(path: "downloads")

        let got = try await obtain(
            bases: [serving], into: downloads, sha256: Digest.sha256(of: Data(body.utf8))
        )

        #expect(try String(contentsOf: got, encoding: .utf8) == body)
    }

    @Test("Bytes that do not match the pin are refused and nothing is left behind")
    func refusesMismatchedBytes() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let serving = try host(work, named: "package.tar", serving: "a substituted package")
        let downloads = work.appending(path: "downloads")
        let wanted = Digest.sha256(of: Data("the real package".utf8))

        await #expect(throws: StepFailure.self) {
            _ = try await obtain(bases: [serving], into: downloads, sha256: wanted)
        }

        // The point is not only that it threw. Bytes left in the downloads directory
        // would be picked up as cached and reused by the next run.
        #expect(
            FileManager.default.fileExists(
                atPath: downloads.appending(path: "package.tar").path(percentEncoded: false)
            ) == false,
            "the rejected body was kept and would be reused as a cached download"
        )
    }

    @Test("A host serving the wrong bytes is passed over for one that does not")
    func fallsThroughToAHonestHost() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let liar = try host(work, named: "package.tar", serving: "a substituted package")
        let honest = try host(work, named: "package.tar", serving: body)
        let downloads = work.appending(path: "downloads")

        let got = try await obtain(
            bases: [liar, honest], into: downloads, sha256: Digest.sha256(of: Data(body.utf8))
        )

        #expect(try String(contentsOf: got, encoding: .utf8) == body)
    }

    @Test("A download that cannot be saved is not blamed on the network")
    func saveFailureIsNotUnreachable() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let first = try host(work, named: "package.tar", serving: body)
        let second = try host(work, named: "package.tar", serving: body)
        let downloads = work.appending(path: "downloads")
        try Data("not a folder".utf8).write(to: downloads)
        let reported = Reports()

        let failure = try await #require(throws: StepFailure.self) {
            _ = try await PinnedDownload.obtain(
                file: "package.tar", sha256: Digest.sha256(of: Data(body.utf8)),
                bases: [first, second], into: downloads, step: "test",
                report: { reported.add($0.label) })
        }

        #expect(!failure.detail.contains("could not reach"))
        #expect(failure.detail.contains(downloads.path(percentEncoded: false)))
        // One host tried; byte counts (" / ") follow it.
        #expect(reported.all.filter { !$0.contains(" / ") }.count == 1)
    }

    @Test("A download has an overall deadline, not only an idle one")
    func downloadsHaveADeadline() {
        #expect(PinnedDownload.session.configuration.timeoutIntervalForResource <= 4 * 60 * 60)
    }

    private final class Trickle: URLProtocol, @unchecked Sendable {
        private var timer: DispatchSourceTimer?

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "trickle.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: Data("x".utf8))
            }
            timer.resume()
            self.timer = timer
        }

        override func stopLoading() { timer?.cancel() }
    }

    // 64 KB with a Content-Length, sent in eight pieces, so progress has something between 0 and done.
    private final class Chunked: URLProtocol, @unchecked Sendable {
        static let body = Data(repeating: 0x61, count: 64 * 1024)
        private var timer: DispatchSourceTimer?

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "chunked.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var sent = 0
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let piece = Self.body.count / 8
                self.client?.urlProtocol(self, didLoad: Self.body.subdata(in: sent..<sent + piece))
                sent += piece
                if sent >= Self.body.count {
                    self.timer?.cancel()
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
            timer.resume()
            self.timer = timer
        }

        override func stopLoading() { timer?.cancel() }
    }

    // macOS 27's task.progress counts 100 units and stays at 5 until the end; the bar showed
    // "5 bytes / 100 bytes" for the whole engine download.
    @Test("Progress counts the bytes received, and moves before the download ends")
    func progressCountsBytes() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        final class Counts: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [(received: Int64, total: Int64)] = []
            func add(_ p: PinnedDownload.Progress) {
                guard case .receiving(_, let received, let total, _, _) = p else { return }
                lock.withLock { seen.append((received, total)) }
            }
            var all: [(received: Int64, total: Int64)] { lock.withLock { seen } }
        }
        let counts = Counts()
        let size = Int64(Chunked.body.count)

        _ = try await PinnedDownload.obtain(
            file: "package.tar", sha256: Digest.sha256(of: Chunked.body),
            bases: [URL(string: "https://chunked.invalid/")!],
            into: work.appending(path: "downloads"), step: "test",
            session: PinnedDownload.session(deadline: 30, protocols: [Chunked.self]),
            report: { counts.add($0) })

        #expect(!counts.all.isEmpty)
        #expect(counts.all.allSatisfy { $0.total == size })
        #expect(counts.all.contains { $0.received > 0 && $0.received < size })
    }

    @Test("A host that never finishes is given up on for the next one")
    func stalledHostIsPassedOver() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let honest = try host(work, named: "package.tar", serving: body)
        let got = try await PinnedDownload.obtain(
            file: "package.tar", sha256: Digest.sha256(of: Data(body.utf8)),
            bases: [URL(string: "https://trickle.invalid/")!, honest],
            into: work.appending(path: "downloads"), step: "test",
            session: PinnedDownload.session(deadline: 1, protocols: [Trickle.self]))

        #expect(try String(contentsOf: got, encoding: .utf8) == body)
    }

    @Test("An archive already on disk that matches is not fetched again")
    func reusesMatchingArchive() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let downloads = work.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: downloads.appending(path: "package.tar"))

        // No hosts at all, so anything that reaches the network cannot succeed.
        let reported = Reports()
        let got = try await PinnedDownload.obtain(
            file: "package.tar",
            sha256: Digest.sha256(of: Data(body.utf8)),
            bases: [],
            into: downloads,
            step: "test",
            report: { reported.add($0.label) }
        )

        #expect(reported.all == ["Preparing"])
        #expect(try String(contentsOf: got, encoding: .utf8) == body)
    }

    // Two phase enums show this wording, so one copy is what both depend on. The host has to
    // survive into the label: a fallthrough to a second host is only visible through it.
    @Test("A fetch reports the host the bytes came from")
    func reportsTheHostFetchedFrom() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let serving = try host(work, named: "package.tar", serving: body)
        let reported = Reports()

        _ = try await PinnedDownload.obtain(
            file: "package.tar",
            sha256: Digest.sha256(of: Data(body.utf8)),
            bases: [serving],
            into: work.appending(path: "downloads"),
            step: "test",
            report: { reported.add($0.label) }
        )

        let label = try #require(reported.all.first)
        // One host tried; byte counts (" / ") follow it.
        #expect(reported.all.filter { !$0.contains(" / ") }.count == 1)
        #expect(label.hasPrefix("Downloading from "))
        #expect(label.contains(serving.lastPathComponent))
    }
}
