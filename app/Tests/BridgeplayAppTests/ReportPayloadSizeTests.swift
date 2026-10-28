import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Report uploads fit the endpoint's byte limit")
struct ReportPayloadSizeTests {
    private func payload(log: String?, wineLog: String?) -> ReportPayload {
        let machine = GameReport.Machine(chip: "Apple M1", memoryBytes: 8 * 1_073_741_824,
                                         macOS: "macOS 27.0", bridgeplay: "0.7.51")
        return ReportPayload.make(name: "Fixture Game", appID: "123", status: .borked, source: .tap,
                                  session: .byHand(), log: log, wineLog: wineLog, machine: machine,
                                  install: "fixture-install", note: "Game crashed")
    }

    @Test("Small reports keep their original encoding")
    func smallReport() throws {
        let report = payload(log: "recent run\n", wineLog: nil)
        let decoded = try JSONDecoder().decode(ReportPayload.self, from: report.encoded())
        #expect(decoded == report)
    }

    @Test("Unicode and JSON escapes fit with recent logs and earlier crash details", arguments: ["界", "\\", "\u{1}", "👨‍👩‍👧‍👦"])
    func boundedLogs(unit: String) throws {
        let filler = String(repeating: unit, count: unit.utf8.count > 4 ? 30_000 : 300_000)
        let error = "wine: could not load missing.dll\n"
        let report = payload(log: "SteamUser=private_player\n" + filler + "\nnewest run line\n",
                             wineLog: error + filler + "\nnewest Wine line\n")
        #expect(report.log?.contains("private_player") == false, "redacted before trimming, not by it")
        #expect(try JSONEncoder().encode(report).count > ReportPayload.maximumEncodedSize)
        let body = try report.encoded()
        let sent = try JSONDecoder().decode(ReportPayload.self, from: body)
        #expect(body.count <= ReportPayload.maximumEncodedSize)
        #expect(sent.log?.hasSuffix("newest run line\n") == true)
        #expect(sent.wineLog?.hasSuffix("newest Wine line\n") == true)
        #expect(sent.wineLog?.contains(error) == true)
        #expect(sent.log?.contains("private_player") == false)
        #expect(sent.name == report.name && sent.note == report.note && sent.status == report.status)
    }

    @Test("An oversized Wine log fits without a run log")
    func wineOnly() throws {
        var oversized = payload(log: nil, wineLog: nil)
        oversized.wineLog = String(repeating: "界", count: 600_000) + "last Wine line\n"
        let body = try oversized.encoded()
        let sent = try JSONDecoder().decode(ReportPayload.self, from: body)
        #expect(body.count <= ReportPayload.maximumEncodedSize)
        #expect(sent.log == nil)
        #expect(sent.wineLog?.hasSuffix("last Wine line\n") == true)
    }

    @Test("Oversized metadata cannot produce an oversized upload")
    func oversizedMetadata() throws {
        var report = payload(log: nil, wineLog: nil)
        report.name = String(repeating: "x", count: ReportPayload.maximumEncodedSize + 1)
        #expect(throws: EncodingError.self) { try report.encoded() }
    }

    @Test("Offline reports are bounded before they enter the queue")
    func queuedReport() async throws {
        let queue = try scratchDirectory("report-size")
        defer { try? FileManager.default.removeItem(at: queue) }
        let report = payload(log: String(repeating: "界", count: 400_000), wineLog: nil)
        #expect(await FakeEndpoint.sender("offline", queue: queue).submit(report) == .retryLater)
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let body = try Data(contentsOf: file)
        #expect(files.count == 1)
        #expect(body.count <= ReportPayload.maximumEncodedSize)
        #expect(try JSONDecoder().decode(ReportPayload.self, from: body).appid == report.appid)
    }

    @Test("A size-limited endpoint accepts a new report and an older oversized queued report")
    func endpointAndLegacyQueue() async throws {
        let queue = try scratchDirectory("report-size")
        defer { try? FileManager.default.removeItem(at: queue) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SizeLimitedReportEndpoint.self]
        let sender = ReportSender(endpoint: URL(string: "https://report-size.invalid/upload")!, queue: queue,
                                  session: URLSession(configuration: config))
        let report = payload(log: String(repeating: "界", count: 400_000), wineLog: nil)
        let original = try JSONEncoder().encode(report)
        #expect(original.count > ReportPayload.maximumEncodedSize)
        var request = URLRequest(url: sender.endpoint)
        request.httpMethod = "POST"
        request.httpBody = original
        let (_, response) = try await sender.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 413)
        #expect(await sender.submit(report) == .sent)
        let old = queue.appending(path: "older-report.json")
        try original.write(to: old)
        await sender.retryPending(now: Date().addingTimeInterval(16 * 60))
        #expect(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
    }
}

private final class SizeLimitedReportEndpoint: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "report-size.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var bytes = request.httpBody?.count ?? 0
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes += count
            }
        }
        let status = bytes == 0 ? 400 : bytes > ReportPayload.maximumEncodedSize ? 413 : 201
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
