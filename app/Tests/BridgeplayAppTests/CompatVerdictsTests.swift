import Foundation
import Testing
@testable import BridgeplayApp

// compat-index.json as the export writes it (scripts/compat-export.py), with lines a reader skips.
final class FakeIndexOK: URLProtocol, @unchecked Sendable {
    static let body = """
        {"schema":1,"rule":1,"updated":"2026-11-27T12:00:00.000Z","games":{
         "105":{"v":"broken_since","n":5,"p":3,"i":0,"b":2,"since":"0.7.66","build":83,"date":"2026-11-26"},
         "101":{"v":"playable","n":9,"p":8,"i":1,"b":0,"build":83,"date":"2026-11-26"},
         "102":{"v":"broken_since","n":4,"p":2,"i":0,"b":2,"since":"Steam build 1764000000","build":83,"date":"2026-11-26"},
         "103":{"v":"one_report","n":1,"p":0,"i":0,"b":1,"since":"0.7.66; rm -rf","build":83,"date":"2026-11-26"},
         "104":{"v":"doesnt_run","n":5000000,"p":-3,"i":0,"b":4,"build":83,"date":"2026-11-26"},
         "106":{"v":"mixed","n":3,"p":1,"i":1,"b":1,"build":83,"date":"2026-11-26"},
         "0":{"v":"playable","n":2,"p":2,"i":0,"b":0},
         "abc":{"v":"playable","n":2,"p":2,"i":0,"b":0},
         "107":{"v":"great","n":2,"p":2,"i":0,"b":0}},
         "anticheat":{"1962663":["ricochet"],"101":["eac","javelin"],"108":["evil<script>"]}}
        """
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// The compat-data branch before its first export.
final class FakeIndexMissing: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("404: Not Found".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Players' verdicts and anti-cheat names are written for the panel in Steam")
struct CompatVerdictsTests {

    static let games = Data("""
        [{"appid": 101, "anticheat": "Easy Anti-Cheat"},
         {"appid": 1245620, "anticheat": "none known"},
         {"appid": 2000, "anticheat": "GuardingPearSoftware's Anti Cheat Pro"},
         {"appid": 2001, "anticheat": "VAC, BattlEye"},
         {"appid": "2002", "anticheat": "Anti-Cheat Expert"},
         {"appid": 0, "anticheat": "VAC"},
         {"appid": 2003}]
        """.utf8)

    private func session(_ type: URLProtocol.Type) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [type]
        return URLSession(configuration: config)
    }

    @Test("Maintainers' names map to the panel's ids")
    func names() {
        #expect(CompatVerdicts.anticheatID("Easy Anti-Cheat") == "eac")
        #expect(CompatVerdicts.anticheatID("Anti-Cheat Expert") == "ace")
        #expect(CompatVerdicts.anticheatID(" VAC ") == "vac")
        #expect(CompatVerdicts.anticheatID("EA Javelin") == "javelin")
        #expect(CompatVerdicts.anticheatID("nProtect GameGuard") == "nprotect")
        #expect(CompatVerdicts.anticheatID("GuardingPearSoftware's Anti Cheat Pro") == "other")
        #expect(CompatVerdicts.anticheatID("none known") == nil)
        #expect(CompatVerdicts.anticheatID("") == nil)
    }

    @Test("Since is a version, a Steam build or nothing")
    func since() {
        #expect(CompatVerdicts.since("0.7.66") == "0.7.66")
        #expect(CompatVerdicts.since("Steam build 1764000000") == "s1764000000")
        #expect(CompatVerdicts.since("0.7.66; rm -rf") == "-")
        #expect(CompatVerdicts.since(nil) == "-")
        #expect(CompatVerdicts.since(12) == "-")
    }

    @Test("The file holds only what the dylib reads, sorted by AppID")
    func file() throws {
        let text = try #require(CompatVerdicts.tsv(index: Data(FakeIndexOK.body.utf8), games: Self.games))
        #expect(text == """
            bridgeplay-compat-verdicts\t1\t1795780800
            101\tp\t9\t8\t1\t0\t-\teac,javelin
            102\ts\t4\t2\t0\t2\ts1764000000\t-
            103\to\t1\t0\t0\t1\t-\t-
            104\td\t999999\t0\t0\t4\t-\t-
            105\ts\t5\t3\t0\t2\t0.7.66\t-
            106\tm\t3\t1\t1\t1\t-\t-
            2000\t-\t0\t0\t0\t0\t-\tother
            2001\t-\t0\t0\t0\t0\t-\tvac,battleye
            2002\t-\t0\t0\t0\t0\t-\tace
            1962663\t-\t0\t0\t0\t0\t-\tricochet

            """)
    }

    @Test("Before the first export only the maintainers' names are written, with no export time")
    func gamesOnly() throws {
        let text = try #require(CompatVerdicts.tsv(index: Data("404: Not Found".utf8), games: Self.games))
        #expect(text.hasPrefix("bridgeplay-compat-verdicts\t1\t0\n101\t-\t0\t0\t0\t0\t-\teac\n"))
        #expect(CompatVerdicts.tsv(index: nil, games: nil) == nil)
        #expect(CompatVerdicts.tsv(index: Data(#"{"schema":2,"games":{"101":{"v":"playable","n":2,"p":2}}}"#.utf8), games: nil) == nil)
    }

    @Test("The dylib's folder: the current one, the old one while only it exists, none before install")
    func folder() throws {
        let dir = try scratchDirectory("verdict-folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appending(path: "bridgeplay"), legacy = dir.appending(path: "notproton")
        #expect(CompatVerdicts.folder(support: current, legacy: legacy) == nil)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(CompatVerdicts.folder(support: current, legacy: legacy) == legacy)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        #expect(CompatVerdicts.folder(support: current, legacy: legacy) == current)
    }

    @Test("Fetched once a day, written when it changed, the old copy kept offline and before the branch exists")
    func refresh() async throws {
        let dir = try scratchDirectory("verdicts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appending(path: "support"), cache = dir.appending(path: "caches/compat-index.json")
        let games = dir.appending(path: "compat-games.json"), file = support.appending(path: CompatVerdicts.fileName)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        // No branch yet and no maintainer list: nothing is written.
        await CompatVerdicts.refresh(cache: cache, games: games, folder: support, session: session(FakeIndexMissing.self))
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))

        try Self.games.write(to: games)
        await CompatVerdicts.refresh(cache: cache, games: games, folder: support, session: session(FakeIndexOK.self))
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(first.hasPrefix("bridgeplay-compat-verdicts\t1\t1795780800\n101\tp\t"))

        // Fresh: not fetched again, so a dead network changes nothing.
        await CompatVerdicts.refresh(cache: cache, games: games, folder: support, session: session(FakeRawDown.self))
        #expect(try String(contentsOf: file, encoding: .utf8) == first)
        // A day old and the branch is gone: the old copy is used and kept another day.
        let later = Date().addingTimeInterval(2 * 86400)
        await CompatVerdicts.refresh(cache: cache, games: games, folder: support, session: session(FakeIndexMissing.self), now: later)
        #expect(try String(contentsOf: file, encoding: .utf8) == first)
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: cache.path(percentEncoded: false))[.modificationDate] as? Date)
        #expect(abs(touched.timeIntervalSince(later)) < 2)

        // Not installed: no folder, nothing fetched or written.
        let elsewhere = dir.appending(path: "elsewhere-cache.json")
        await CompatVerdicts.refresh(cache: elsewhere, games: games, folder: nil, session: session(FakeIndexOK.self))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path(percentEncoded: false)))
    }

    @Test("A file the dylib would refuse is not written")
    func tooLarge() throws {
        let dir = try scratchDirectory("verdicts-large")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!CompatVerdicts.write(String(repeating: "x", count: CompatVerdicts.maxBytes + 1), into: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: CompatVerdicts.fileName).path(percentEncoded: false)))
        #expect(CompatVerdicts.write("bridgeplay-compat-verdicts\t1\t0\n", into: dir))
    }
}
