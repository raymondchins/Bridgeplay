// The appinfo.vdf path selects the newer of the legacy file and its sibling
// shard set. Pass the appinfo directory directly to read only the shards.
// With --platforms instead of an appid it prints mac= and windows= appid lists.
//
// common/icon is a 32x32 thumbnail. common/clienticon is the real multi-res
// icon, and the two hashes differ for most apps, so the icon cannot be
// inferred from the filesystem. Exits non-zero without printing on read
// failure.

import Foundation

let args = CommandLine.arguments
let platforms = args.count == 3 && args[2] == "--platforms"
guard args.count == 3, platforms || UInt32(args[2]) != nil else {
    fputs("usage: appinfo <appinfo.vdf|appinfo-directory> <appid>|--platforms\n", stderr)
    exit(2)
}

enum VDFError: Error {
    case truncated
    case incompleteShardSet
    case unknownType(UInt8)
    case unknownMagic(UInt32)
    case badStringIndex(UInt32)
    case excessiveNesting
}

indirect enum Value {
    case string(String)
    case number(Int64)
    case section([String: Value])
}

struct Cursor {
    let b: [UInt8]
    var p: Int
    let end: Int

    init(b: [UInt8], p: Int, end: Int? = nil) {
        self.b = b
        self.p = p
        self.end = end ?? b.count
    }

    mutating func u8() throws -> UInt8 {
        guard p < end else { throw VDFError.truncated }
        defer { p += 1 }
        return b[p]
    }

    mutating func u32() throws -> UInt32 {
        guard p + 4 <= end else { throw VDFError.truncated }
        defer { p += 4 }
        return UInt32(b[p]) | UInt32(b[p + 1]) << 8
            | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            guard p + i < end else { throw VDFError.truncated }
            v |= UInt64(b[p + i]) << (8 * UInt64(i))
        }
        p += 8
        return v
    }

    // Values and, before the string table existed, keys are NUL terminated.
    mutating func cstring() throws -> String {
        var end = p
        while end < self.end && b[end] != 0 { end += 1 }
        guard end < self.end else { throw VDFError.truncated }
        let s = String(decoding: b[p..<end], as: UTF8.self)
        p = end + 1
        return s
    }

    // A wide string ends at a NUL pair, not a single NUL.
    mutating func wcstring() throws -> String {
        var end = p
        while end + 1 < self.end && !(b[end] == 0 && b[end + 1] == 0) { end += 2 }
        guard end + 1 < self.end else { throw VDFError.truncated }
        var units: [UInt16] = []
        var i = p
        while i < end {
            units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8)
            i += 2
        }
        p = end + 2
        return String(decoding: units, as: UTF16.self)
    }

    mutating func skip(_ n: Int) throws {
        guard p + n <= end else { throw VDFError.truncated }
        p += n
    }
}

// v29 moved every key into one table at the end of the file and left an index
// in its place, so the table has to be read before any app can be parsed.
func readStringTable(_ c: inout Cursor, count: UInt32) throws -> [String] {
    guard Int(count) <= c.end - c.p else { throw VDFError.truncated }
    var out: [String] = []
    out.reserveCapacity(Int(count))
    for _ in 0..<count { out.append(try c.cstring()) }
    return out
}

func readSection(_ c: inout Cursor, _ table: [String]?, depth: Int = 0) throws -> [String: Value] {
    guard depth < 64 else { throw VDFError.excessiveNesting }
    var out: [String: Value] = [:]
    while true {
        let type = try c.u8()
        // 0x0b is the alternate section terminator the format also allows.
        if type == 0x08 || type == 0x0b { return out }
        let key: String
        if let table = table {
            let i = try c.u32()
            guard Int(i) < table.count else { throw VDFError.badStringIndex(i) }
            key = table[Int(i)]
        } else {
            key = try c.cstring()
        }
        switch type {
        // Handles every type the format defines. An unused-but-legal type inside
        // an app entry would otherwise drop the whole entry and its name.
        case 0x00: out[key] = .section(try readSection(&c, table, depth: depth + 1))
        case 0x01: out[key] = .string(try c.cstring())
        case 0x02: out[key] = .number(Int64(Int32(bitPattern: try c.u32())))
        case 0x03: try c.skip(4)
        case 0x04: try c.skip(4)
        case 0x05: out[key] = .string(try c.wcstring())
        case 0x06: try c.skip(4)
        case 0x07: out[key] = .number(Int64(bitPattern: try c.u64()))
        case 0x0a: out[key] = .number(Int64(bitPattern: try c.u64()))
        default: throw VDFError.unknownType(type)
        }
    }
}

typealias Visitor = (UInt32, () throws -> [String: Value]) throws -> Bool

func appKeys(_ b: [UInt8], _ start: Int, _ end: Int, _ table: [String]?) throws -> [String: Value] {
    var kv = Cursor(b: b, p: start, end: end)
    let root = try readSection(&kv, table)
    if case .section(let inner)? = root["appinfo"] { return inner }
    return root
}

// A false visitor result stops the scan, including all remaining shards.
func scanShard(_ b: [UInt8], index: Int, visit: Visitor) throws -> Bool {
    var h = Cursor(b: b, p: 0)
    let magic = try h.u32()
    guard magic == 0x0756_442a else { throw VDFError.unknownMagic(magic) }
    try h.skip(4) // universe
    guard try h.u32() == index, try h.u32() == 256 else { throw VDFError.incompleteShardSet }
    let count = try h.u32()
    let indexSize = Int(try h.u32())
    let keyCount = try h.u32()
    let keySize = Int(try h.u32())
    let dataSize = Int(try h.u32())
    try h.skip(8)
    let keyStart = h.p + indexSize
    let dataStart = keyStart + keySize
    guard dataStart + dataSize == b.count else { throw VDFError.truncated }
    var keys = Cursor(b: b, p: keyStart, end: dataStart)
    let table = try readStringTable(&keys, count: keyCount)
    guard keys.p == keys.end else { throw VDFError.truncated }

    var entries = Cursor(b: b, p: h.p, end: keyStart)
    for _ in 0..<count {
        let id = try entries.u32()
        let offset = Int(try entries.u32())
        let size = Int(try entries.u32())
        guard size >= 20, offset + size <= dataSize else { throw VDFError.truncated }
        try entries.skip(50)
        let extraIDs = Int(try entries.u32())
        try entries.skip(extraIDs * 4 + 13)
        _ = try entries.cstring() // Usually empty, "JP" in the observed cache.
        let start = dataStart + offset
        if try !visit(id, { try appKeys(b, start + 20, start + size, table) }) { return false }
    }
    guard entries.p == entries.end else { throw VDFError.truncated }
    return true
}

func scanLegacy(_ b: [UInt8], _ visit: Visitor) throws {
    var head = Cursor(b: b, p: 0)
    let magic = try head.u32()
    _ = try head.u32()

    var table: [String]? = nil
    var pos: Int
    var entriesEnd = b.count
    // The sha1 of the entry's own binary vdf arrived in v28, which moves the
    // start of the key data 20 bytes further into every app entry.
    var entryHeader = 60
    switch magic {
    case 0x0756_4429:
        let offset = try head.u64()
        guard offset >= 16, offset < UInt64(b.count) else { throw VDFError.truncated }
        var keys = Cursor(b: b, p: Int(offset))
        let count = try keys.u32()
        table = try readStringTable(&keys, count: count)
        entriesEnd = Int(offset)
        pos = 16
    case 0x0756_4428:
        pos = 8
    case 0x0756_4427:
        pos = 8
        entryHeader = 40
    default:
        throw VDFError.unknownMagic(magic)
    }

    while pos + 4 <= entriesEnd {
        var e = Cursor(b: b, p: pos, end: entriesEnd)
        let id = try e.u32()
        if id == 0 { return }
        let size = Int(try e.u32())
        guard size >= entryHeader, size <= entriesEnd - pos - 8 else { throw VDFError.truncated }
        let entryEnd = pos + 8 + size
        let start = pos + 8 + entryHeader
        if try !visit(id, { try appKeys(b, start, entryEnd, table) }) { return }
        pos = entryEnd
    }
    throw VDFError.truncated
}

func forEachApp(_ path: URL, _ visit: Visitor) throws {
    let files = FileManager.default
    let direct = path.hasDirectoryPath
    let dir = direct ? path : path.deletingPathExtension()
    if direct || (path.lastPathComponent == "appinfo.vdf" && files.fileExists(atPath: dir.path)) {
        let legacyDate = direct ? nil : try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var shards: [URL] = []
        var newest = Date.distantPast
        for index in 0..<256 {
            let shard = dir.appendingPathComponent(String(format: "appinfo_%02x.vdf", index))
            guard let date = try? shard.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { break }
            newest = max(newest, date)
            shards.append(shard)
        }
        if shards.count == 256 && newest >= (legacyDate ?? .distantPast) {
            for (index, shard) in shards.enumerated() {
                if try !scanShard([UInt8](Data(contentsOf: shard)), index: index, visit: visit) { break }
            }
            return
        }
        if legacyDate == nil { throw VDFError.incompleteShardSet }
    }
    try scanLegacy([UInt8](Data(contentsOf: path)), visit)
}

func findApp(_ path: URL, _ appID: UInt32) throws -> [String: Value]? {
    var found: [String: Value]?
    try forEachApp(path) { id, keys in
        guard id == appID else { return true }
        found = try keys()
        return false
    }
    return found
}

// Steam treats an app without an oslist as Windows only.
// oslist can still say macos for a 32-bit build that no longer runs.
func printPlatforms(_ path: URL) throws {
    var mac: [UInt32] = []
    var windows: [UInt32] = []
    try forEachApp(path) { id, keys in
        guard case .section(let common)? = try keys()["common"] else { return true }
        guard case .string(let oslist)? = common["oslist"] else {
            windows.append(id)
            return true
        }
        let systems = oslist.split(separator: ",")
        if systems.contains("macos") { mac.append(id) }
        if systems.contains("windows") { windows.append(id) }
        return true
    }
    print("mac=" + mac.map(String.init).joined(separator: ","))
    print("windows=" + windows.map(String.init).joined(separator: ","))
}

do {
    let path = URL(fileURLWithPath: args[1])
    if platforms {
        try printPlatforms(path)
        exit(0)
    }
    let wantAppID = UInt32(args[2])!
    guard let app = try findApp(path, wantAppID) else {
        fputs("appinfo: no entry for appid \(wantAppID)\n", stderr)
        exit(1)
    }
    guard case .section(let common)? = app["common"] else {
        fputs("appinfo: appid \(wantAppID) has no common section\n", stderr)
        exit(1)
    }
    // A newline in a value would break the key=value framing the caller reads.
    for key in ["name", "icon", "clienticon", "logo"] {
        guard case .string(let v)? = common[key], !v.isEmpty else { continue }
        let flat = v.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        print("\(key)=\(flat)")
    }
} catch {
    fputs("appinfo: cannot parse \(args[1]): \(error)\n", stderr)
    exit(1)
}
