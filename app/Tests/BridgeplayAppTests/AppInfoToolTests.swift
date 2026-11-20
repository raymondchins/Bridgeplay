import CryptoKit
import Foundation
import Testing

@testable import BridgeplayApp

// The launcher builds a game's bundle name and icon from what this tool prints, so a parse
// that reads the wrong key mislabels a bundle. All caches here are synthetic.
@Suite("appinfo tool")
struct AppInfoToolTests {

    private struct Cache {
        var bytes: [UInt8] = []

        mutating func u32(_ v: UInt32) {
            for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
        }

        mutating func u64(_ v: UInt64) {
            for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
        }

        mutating func cstring(_ s: String) {
            bytes.append(contentsOf: Array(s.utf8))
            bytes.append(0)
        }
    }

    private static let fields = [
        ("name", "Dark Messiah of Might & Magic"),
        ("icon", "5a08cd17d14ccb07a14f316dfa222b18a20960fd"),
        ("clienticon", "0d652160dff1ab3d1352aa83c9cf14a20146519e"),
    ]

    // Key data is identical in both formats apart from how a key is named, so the
    // caller decides that and the section nesting stays shared.
    private static func keyData(_ key: (String) -> [UInt8]) -> [UInt8] {
        var kv = Cache()
        kv.bytes.append(0x00)
        kv.bytes.append(contentsOf: key("appinfo"))
        kv.bytes.append(0x00)
        kv.bytes.append(contentsOf: key("common"))
        for (name, value) in fields {
            kv.bytes.append(0x01)
            kv.bytes.append(contentsOf: key(name))
            kv.cstring(value)
        }
        // One terminator closes common, one closes appinfo, and one closes the root
        // section the tool starts reading at. A real entry ends 08 08 08 for that reason.
        kv.bytes.append(contentsOf: [0x08, 0x08, 0x08])
        return kv.bytes
    }

    private static func entry(appID: UInt32, keyData: [UInt8]) -> [UInt8] {
        var e = Cache()
        e.u32(appID)
        // The size counts everything after itself, and the 60 byte header in between
        // is what the tool has to skip to reach the keys.
        e.u32(UInt32(60 + keyData.count))
        e.bytes.append(contentsOf: [UInt8](repeating: 0, count: 60))
        e.bytes.append(contentsOf: keyData)
        return e.bytes
    }

    private static func v29(appID: UInt32) -> Data {
        let table = ["appinfo", "common"] + fields.map(\.0)
        let index = { (key: String) -> [UInt8] in
            var c = Cache()
            c.u32(UInt32(table.firstIndex(of: key)!))
            return c.bytes
        }
        let body = entry(appID: appID, keyData: keyData(index))

        var file = Cache()
        file.u32(0x0756_4429)
        file.u32(1)
        // Header, entry and the zero appid that ends the list all precede the table.
        file.u64(UInt64(16 + body.count + 4))
        file.bytes.append(contentsOf: body)
        file.u32(0)
        file.u32(UInt32(table.count))
        for s in table { file.cstring(s) }
        return Data(file.bytes)
    }

    private static func v28(appID: UInt32) -> Data {
        let inline = { (key: String) -> [UInt8] in
            var c = Cache()
            c.cstring(key)
            return c.bytes
        }
        var file = Cache()
        file.u32(0x0756_4428)
        file.u32(1)
        file.bytes.append(contentsOf: entry(appID: appID, keyData: keyData(inline)))
        file.u32(0)
        return Data(file.bytes)
    }

    private static func platformEntry(
        _ appID: UInt32, _ oslist: String?, common: Bool = true, table: [String]? = nil
    ) -> [UInt8] {
        var kv = Cache()
        func key(_ name: String) {
            if let table { kv.u32(UInt32(table.firstIndex(of: name)!)) }
            else { kv.cstring(name) }
        }
        kv.bytes.append(0x00)
        key("appinfo")
        if common {
            kv.bytes.append(0x00)
            key("common")
            kv.bytes.append(0x01)
            key("name")
            kv.cstring("App \(appID)")
            if let oslist {
                kv.bytes.append(0x01)
                key("oslist")
                kv.cstring(oslist)
            }
            kv.bytes.append(0x08)
        }
        kv.bytes.append(contentsOf: [0x08, 0x08])
        return entry(appID: appID, keyData: kv.bytes)
    }

    private static func platforms(
        ended: Bool = true, firstSize: UInt32? = nil, stringTable: Bool = false
    ) -> Data {
        let table = stringTable ? ["appinfo", "common", "name", "oslist"] : nil
        var entries = Cache()
        var first = platformEntry(10, "windows,macos", table: table)
        if let firstSize {
            var size = Cache()
            size.u32(firstSize)
            first.replaceSubrange(4..<8, with: size.bytes)
        }
        entries.bytes.append(contentsOf: first)
        entries.bytes.append(contentsOf: platformEntry(20, "windows", table: table))
        entries.bytes.append(contentsOf: platformEntry(30, nil, table: table))
        entries.bytes.append(contentsOf: platformEntry(40, "linux", table: table))
        entries.bytes.append(contentsOf: platformEntry(50, "macos", table: table))
        entries.bytes.append(contentsOf: platformEntry(60, nil, common: false, table: table))
        if ended { entries.u32(0) }
        var file = Cache()
        file.u32(stringTable ? 0x0756_4429 : 0x0756_4428)
        file.u32(1)
        if let table {
            file.u64(UInt64(16 + entries.bytes.count))
            file.bytes.append(contentsOf: entries.bytes)
            file.u32(UInt32(table.count))
            for key in table { file.cstring(key) }
        } else {
            file.bytes.append(contentsOf: entries.bytes)
        }
        return Data(file.bytes)
    }

    private func read(_ cache: Data, _ appID: String) throws -> CommandResult {
        let tool = try InstallPayload.locate().appinfo
        let path = URL.temporaryDirectory.appending(path: "np-appinfo-\(UUID().uuidString).vdf")
        try cache.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let result = try Shell.run(
            tool.path(percentEncoded: false), [path.path(percentEncoded: false), appID])
        #expect(
            !result.outputLost,
            "appinfo ran but its output was never collected, so every field below reads as absent")
        return result
    }

    private func values(_ result: CommandResult) -> [String: String] {
        var out: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let split = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<split])] = String(line[line.index(after: split)...])
        }
        return out
    }

    // shortTable drops the last key, so the payloads keep valid hashes but name a key
    // the table does not have.
    private static func shard(_ index: Int, apps: [UInt32], shortTable: Bool = false) -> Data {
        let keys = index == 0 ? ["appinfo", "common", "name", "oslist"] : ["oslist", "name", "common", "appinfo"]
        let written = shortTable ? Array(keys.dropLast()) : keys
        var entries = Cache(), strings = Cache(), blobs = Cache()
        for key in written { strings.cstring(key) }
        for id in apps {
            let os = index == 0 ? "windows" : "windows,macos"
            let kv = platformEntry(id, os, table: keys).dropFirst(68)
            entries.u32(id)
            entries.u32(UInt32(blobs.bytes.count))
            entries.u32(UInt32(20 + kv.count))
            entries.bytes += Array(repeating: 0, count: 50)
            entries.u32(1)
            entries.u32(42)
            entries.u32(4)
            entries.u32(2)
            entries.u32(1)
            entries.bytes.append(0)
            entries.cstring("JP")
            blobs.bytes += Array(Insecure.SHA1.hash(data: kv))
            blobs.bytes += kv
        }
        var h = Cache()
        for word in [0x0756442a, 1, index, 256, apps.count, entries.bytes.count,
                     written.count, strings.bytes.count, blobs.bytes.count, 0, 0] { h.u32(UInt32(word)) }
        return Data(h.bytes + entries.bytes + strings.bytes + blobs.bytes)
    }

    @Test("Shards use local keys and variable index records, and coexist with the legacy file")
    func readsShards() throws {
        let fm = FileManager.default
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let dir = root.appending(path: "appinfo")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appending(path: "appinfo.vdf")
        let tool = try InstallPayload.locate().appinfo
        func run(_ query: String) throws -> CommandResult {
            try Shell.run(tool.path, [legacy.path, query])
        }
        for i in 0..<256 {
            let ids: [UInt32] = i == 0 ? [17, 29] : (i == 255 ? [68] : [])
            try Self.shard(i, apps: ids).write(to: dir.appending(path: String(format: "appinfo_%02x.vdf", i)))
        }
        let expected = "mac=68\nwindows=17,29,68\n"
        #expect(try run("--platforms").stdout == expected)
        #expect(try run("29").stdout == "name=App 29\n")
        try Self.v28(appID: 2100).write(to: legacy)
        try fm.setAttributes([.modificationDate: Date.distantFuture], ofItemAtPath: legacy.path)
        #expect(try run("2100").status == 0)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: legacy.path)
        #expect(try run("--platforms").stdout == expected)
        let last = dir.appending(path: "appinfo_ff.vdf")
        try Data(Self.shard(255, apps: [68]).dropLast()).write(to: last)
        // A newer shard Steam left half written, or whose payload no longer matches its
        // SHA-1, falls back to the older legacy file rather than failing.
        let truncated = try run("--platforms")
        #expect(truncated.status == 0 && truncated.stdout != expected)
        #expect(try run("2100").status == 0)
        var corrupt = [UInt8](Self.shard(255, apps: [68]))
        corrupt[corrupt.count - 3] ^= 1
        try Data(corrupt).write(to: last)
        #expect(try run("68").status != 0)
        #expect(try run("2100").status == 0)
        // A shard that only fails while its apps are decoded still falls back cleanly, with
        // nothing the earlier shards gave mixed into the legacy answer.
        try Self.shard(255, apps: [68], shortTable: true).write(to: last)
        let decoded = try run("--platforms")
        #expect(decoded.status == 0 && decoded.stdout == truncated.stdout)
        try Data(corrupt).write(to: last)
        try fm.removeItem(at: legacy)
        let mismatch = try run("--platforms")
        #expect(mismatch.status != 0 && mismatch.stdout.isEmpty)
        try Self.v28(appID: 2100).write(to: legacy)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: legacy.path)
        try fm.removeItem(at: last)
        #expect(try run("2100").status == 0)
        try fm.removeItem(at: legacy)
        let incomplete = try run("--platforms")
        #expect(incomplete.status != 0 && incomplete.stdout.isEmpty)
    }

    @Test("A v29 cache resolves the client icon, which is not the icon we used to guess")
    func readsStringTableFormat() throws {
        let result = try read(Self.v29(appID: 2100), "2100")
        let fields = values(result)

        #expect(result.status == 0)
        #expect(fields["clienticon"] == "0d652160dff1ab3d1352aa83c9cf14a20146519e")
        #expect(fields["icon"] == "5a08cd17d14ccb07a14f316dfa222b18a20960fd")
        // A name carrying an ampersand is what broke the generated plist before, so it
        // has to survive the parse intact for the caller to escape it.
        #expect(fields["name"] == "Dark Messiah of Might & Magic")
    }

    @Test("A v28 cache with inline keys resolves the same values")
    func readsInlineKeyFormat() throws {
        let result = try read(Self.v28(appID: 42700), "42700")
        let fields = values(result)

        #expect(result.status == 0)
        #expect(fields["clienticon"] == "0d652160dff1ab3d1352aa83c9cf14a20146519e")
        #expect(fields["name"] == "Dark Messiah of Might & Magic")
    }

    @Test("An app the cache does not carry prints nothing and fails")
    func refusesUnknownApp() throws {
        let result = try read(Self.v29(appID: 2100), "10180")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, "a caller reading key=value lines must get none")
    }

    @Test("--platforms lists Mac games, and Windows games including those with no oslist or a Mac build too",
          arguments: [false, true])
    func listsPlatforms(stringTable: Bool) throws {
        let result = try read(Self.platforms(stringTable: stringTable), "--platforms")

        #expect(result.status == 0)
        #expect(result.stdout == "mac=10,50\nwindows=10,20,30\n")
    }

    @Test("--platforms on a cache that stops early prints nothing and fails", arguments: [false, true])
    func refusesTruncatedPlatforms(stringTable: Bool) throws {
        let result = try read(Self.platforms(ended: false, stringTable: stringTable), "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, "a half list would hide the rest of the library")
    }

    @Test("--platforms rejects invalid entry sizes", arguments: [UInt32(1), 59, UInt32.max], [false, true])
    func refusesInvalidPlatformEntrySize(_ size: UInt32, stringTable: Bool) throws {
        let result = try read(Self.platforms(firstSize: size, stringTable: stringTable), "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("An app cannot borrow its section terminator from outside its entry")
    func refusesKeysOutsideEntry() throws {
        var cache = Self.v28(appID: 2100)
        var size = Cache()
        size.u32(UInt32(cache.count - 8 - 8 - 4 - 1))
        cache.replaceSubrange(12..<16, with: size.bytes)
        let result = try read(cache, "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("Deeply nested appinfo sections fail without crashing the helper", arguments: [false, true])
    func refusesExcessiveNesting(stringTable: Bool) throws {
        let depth = 32_768
        var keys = Cache()
        for _ in 0..<depth {
            keys.bytes.append(0x00)
            if stringTable { keys.u32(0) }
            else { keys.cstring("nested") }
        }
        keys.bytes.append(contentsOf: repeatElement(UInt8(0x08), count: depth + 1))
        let body = Self.entry(appID: 2100, keyData: keys.bytes)
        var file = Cache()
        file.u32(stringTable ? 0x0756_4429 : 0x0756_4428)
        file.u32(1)
        if stringTable { file.u64(UInt64(16 + body.count + 4)) }
        file.bytes.append(contentsOf: body)
        file.u32(0)
        if stringTable {
            file.u32(1)
            file.cstring("nested")
        }

        let result = try read(Data(file.bytes), "--platforms")
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("cannot parse"))
    }

    @Test("A cache that is not a cache fails instead of printing garbage")
    func refusesUnparsableFile() throws {
        let result = try read(Data(repeating: 0xab, count: 4096), "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }
}
