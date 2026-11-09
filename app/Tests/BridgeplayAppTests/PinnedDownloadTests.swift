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

    // Fails every request with the URLError code named by the host, e.g. https://refused.invalid/.
    private final class Failing: URLProtocol, @unchecked Sendable {
        static let codes: [String: URLError.Code] = [
            "refused.invalid": .cannotConnectToHost, "untrusted.invalid": .serverCertificateUntrusted,
            "cancelled.invalid": .cancelled,
        ]

        override class func canInit(with request: URLRequest) -> Bool { codes[request.url?.host() ?? ""] != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(Self.codes[request.url!.host()!]!))
        }
        override func stopLoading() {}
    }

    private func failure(from host: String) async throws -> StepFailure {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        return try await #require(throws: StepFailure.self) {
            _ = try await PinnedDownload.obtain(
                file: "package.tar", sha256: String(repeating: "0", count: 64),
                bases: [URL(string: "https://\(host)/")!],
                into: work.appending(path: "downloads"), step: "test",
                session: PinnedDownload.session(deadline: 30, protocols: [Failing.self]))
        }
    }

    @Test("A host that can't be reached points at the connection, a firewall, VPN or proxy",
          arguments: ["refused.invalid", "untrusted.invalid"])
    func unreachableNamesAFirewall(host: String) async throws {
        let detail = try await failure(from: host).detail
        #expect(detail.contains("could not reach"))
        #expect(detail.contains("firewall"))
    }

    @Test("A failure that isn't the network is not blamed on a firewall")
    func otherFailureIsNotAFirewall() async throws {
        let detail = try await failure(from: "cancelled.invalid").detail
        #expect(!detail.contains("could not reach"))
        #expect(!detail.contains("firewall"))
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

    @Test("A cached archive that fails its pin is fetched again and replaced")
    func replacesBadCache() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let body = "the real package"
        let serving = try host(work, named: "package.tar", serving: body)
        let downloads = work.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("the real pack".utf8).write(to: downloads.appending(path: "package.tar"))

        let got = try await obtain(
            bases: [serving], into: downloads, sha256: Digest.sha256(of: Data(body.utf8))
        )

        #expect(try String(contentsOf: got, encoding: .utf8) == body)
    }

    @Test("A cached archive that fails its pin is refused when no host can replace it")
    func refusesBadCacheWithNoHost() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }

        let downloads = work.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("the real pack".utf8).write(to: downloads.appending(path: "package.tar"))

        await #expect(throws: StepFailure.self) {
            try await obtain(
                bases: [], into: downloads, sha256: Digest.sha256(of: Data("the real package".utf8))
            )
        }
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

    // Answers the status in the host name ("504.busy.invalid") to the first requests, then
    // 200 with the body. How many times it says no is the first path component.
    private final class Busy: URLProtocol, @unchecked Sendable {
        static let body = Data("the real package".utf8)
        private static let lock = NSLock()
        nonisolated(unsafe) private static var asked: [String: Int] = [:]
        static func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return asked[key] ?? 0 }

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasSuffix("busy.invalid") == true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let key = url.pathComponents[1]
            Self.lock.lock(); Self.asked[key, default: 0] += 1; let n = Self.asked[key]!; Self.lock.unlock()
            let status = n <= Int(url.pathComponents[2])! ? Int(url.host()!.split(separator: ".")[0])! : 200
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: status == 200 ? Self.body : Data("busy".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func busy(_ status: Int, refusals: Int) async throws -> (Result<URL, StepFailure>, asked: Int) {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString
        let result: Result<URL, StepFailure>
        do {
            let got = try await PinnedDownload.obtain(
                file: "package.tar", sha256: Digest.sha256(of: Busy.body),
                bases: [URL(string: "https://\(status).busy.invalid/\(key)/\(refusals)/")!],
                into: work.appending(path: "downloads"), step: "test",
                session: PinnedDownload.session(deadline: 30, protocols: [Busy.self]), backoff: .zero)
            result = .success(got)
        } catch let failure as StepFailure {
            result = .failure(failure)
        }
        return (result, Busy.count(key))
    }

    @Test("A host that answers a passing 5xx is asked again (#2727)", arguments: [502, 503, 504, 429])
    func passingBusyIsAskedAgain(status: Int) async throws {
        let (result, asked) = try await busy(status, refusals: 2)
        #expect((try? result.get()) != nil)
        #expect(asked == 3)
    }

    @Test("A host that stays busy is given up on after three asks")
    func busyHostIsGivenUpOn() async throws {
        let (result, asked) = try await busy(504, refusals: 99)
        guard case .failure(let failure) = result else { Issue.record("downloaded from a busy host"); return }
        #expect(failure.detail.contains("try again later"))
        #expect(asked == 3)
    }

    @Test("A host given up on hands over to the next, which gets its own asks")
    func busyHostFallsThroughToNextHost() async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        let (first, second) = (UUID().uuidString, UUID().uuidString)

        let got = try await PinnedDownload.obtain(
            file: "package.tar", sha256: Digest.sha256(of: Busy.body),
            bases: [
                URL(string: "https://504.busy.invalid/\(first)/99/")!,
                URL(string: "https://503.busy.invalid/\(second)/2/")!,
            ],
            into: work.appending(path: "downloads"), step: "test",
            session: PinnedDownload.session(deadline: 30, protocols: [Busy.self]), backoff: .zero)

        #expect(try Data(contentsOf: got) == Busy.body)
        #expect(Busy.count(first) == 3)
        #expect(Busy.count(second) == 3)
    }

    @Test("A 404 is not asked again")
    func notFoundIsNotRetried() async throws {
        let (result, asked) = try await busy(404, refusals: 99)
        #expect((try? result.get()) == nil)
        #expect(asked == 1)
    }

    // github.com/<key>/<mode>/releases/download/v1/ answers 504 for good (#3059), as does
    // mirror.invalid with the same path; the API route serves the file unless <mode> says not.
    private final class GitHub: URLProtocol, @unchecked Sendable {
        static let body = Data("the real package".utf8)
        private static let lock = NSLock()
        nonisolated(unsafe) private static var seen: [String: [String]] = [:]
        static func asked(_ key: String) -> [String] { lock.withLock { seen[key] ?? [] } }

        override class func canInit(with request: URLRequest) -> Bool {
            ["github.com", "mirror.invalid", "api.github.com", "assets.invalid"].contains(request.url?.host() ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!, host = url.host()!, path = url.pathComponents
            let (key, mode) = host == "api.github.com" ? (path[2], path[3]) : (path[1], path[2])
            let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
            let what: String, status: Int, body: Data
            switch host {
            case "api.github.com" where path[5] == "tags":
                what = "lookup"
                status = ["lookup403": 403, "lookup404": 404][mode] ?? 200
                let name = mode == "noasset" ? "other.tar" : "package.tar"
                body = Data("""
                    {"assets": [{"name": "\(name).sha256", "url": "https://api.github.com/repos/\(key)/\(mode)/releases/assets/2"},
                                {"name": "\(name)", "url": "https://api.github.com/repos/\(key)/\(mode)/releases/assets/1"}]}
                    """.utf8)
            case "api.github.com" where accept == "application/octet-stream":
                what = "asset \(path[6])"
                guard mode != "assetdown" else { (status, body) = (504, Data()); break }
                let blob = URL(string: "https://assets.invalid/\(key)/\(mode)/\(path[6])")!
                Self.lock.withLock { Self.seen[key, default: []].append(what) }
                client?.urlProtocol(
                    self, wasRedirectedTo: URLRequest(url: blob),
                    redirectResponse: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": blob.absoluteString])!)
                return
            case "assets.invalid":
                (what, status, body) = ("blob \(path[3])", 200, Self.body)
            default:
                (what, status, body) = (host, 504, Data("<h1>504 Gateway Time-out</h1>".utf8))
            }
            Self.lock.withLock { Self.seen[key, default: []].append(what) }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func github(_ mode: String, host: String = "github.com", then next: [URL] = [])
        async throws -> (Result<Data, StepFailure>, asked: [String])
    {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        let key = UUID().uuidString
        do {
            let got = try await PinnedDownload.obtain(
                file: "package.tar", sha256: Digest.sha256(of: GitHub.body),
                bases: [URL(string: "https://\(host)/\(key)/\(mode)/releases/download/v1")!] + next,
                into: work.appending(path: "downloads"), step: "test", from: "GitHub",
                session: PinnedDownload.session(deadline: 30, protocols: [GitHub.self]), backoff: .zero)
            return (.success(try Data(contentsOf: got)), GitHub.asked(key))
        } catch let failure as StepFailure {
            return (.failure(failure), GitHub.asked(key))
        }
    }

    @Test("A github.com download that stays down is fetched through api.github.com (#3059)")
    func githubDownTriesTheAPI() async throws {
        let (result, asked) = try await github("up")
        #expect(try result.get() == GitHub.body)
        #expect(asked == ["github.com", "github.com", "github.com", "lookup", "asset 1", "blob 1"])
    }

    @Test("A host that is not github.com never goes to api.github.com")
    func otherHostSkipsTheAPI() async throws {
        let (result, asked) = try await github("up", host: "mirror.invalid")
        #expect((try? result.get()) == nil)
        #expect(asked == ["mirror.invalid", "mirror.invalid", "mirror.invalid"])
    }

    @Test("An API lookup that is refused falls through to the next host",
          arguments: ["lookup403", "lookup404", "noasset"])
    func refusedLookupFallsThrough(mode: String) async throws {
        let work = try scratchDirectory("pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        let honest = try host(work, named: "package.tar", serving: "the real package")

        let (result, asked) = try await github(mode, then: [honest])
        #expect(try result.get() == GitHub.body)
        #expect(asked == ["github.com", "github.com", "github.com", "lookup"])
    }

    @Test("With no host left, a refused API lookup keeps the usual refusal")
    func refusedLookupKeepsTheRefusal() async throws {
        let (result, asked) = try await github("lookup403")
        guard case .failure(let failure) = result else { Issue.record("downloaded with the API refusing"); return }
        #expect(failure.detail.contains("could not download the files it needs from GitHub"))
        #expect(asked.count == 4)
    }

    @Test("An API asset route that is down too is asked again, then given up on")
    func apiDownIsGivenUpOn() async throws {
        let (result, asked) = try await github("assetdown")
        #expect((try? result.get()) == nil)
        #expect(asked == ["github.com", "github.com", "github.com", "lookup", "asset 1", "asset 1", "asset 1"])
    }

    @Test("Only github.com release download links have an API lookup")
    func releaseLookupURL() {
        let lookup = PinnedDownload.githubReleaseLookup(
            URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3")!)
        #expect(lookup?.absoluteString == "https://api.github.com/repos/dappermint/winecx-gptk/releases/tags/runtime-v4.7.3")
        for other in [
            "https://mirror.invalid/dappermint/winecx-gptk/releases/download/runtime-v4.7.3",
            "http://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3",
            "https://github.com/dappermint/winecx-gptk/archive/refs/tags/v1.tar.gz",
            "https://github.com/dappermint/winecx-gptk/releases/download/a/b",
        ] {
            #expect(PinnedDownload.githubReleaseLookup(URL(string: other)!) == nil, "\(other)")
        }
    }
}
