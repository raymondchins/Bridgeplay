// Logic for Prefix menu, not great, could use some improvements

import Foundation

struct SteamLibrary: Sendable, Hashable {
    let root: URL

    var volume: String?

    var steamapps: URL { root.appending(path: "steamapps") }
    var compatdata: URL { steamapps.appending(path: "compatdata") }

    var displayName: String {
        guard let volume else { return root.lastPathComponent }
        return volume
    }
}

enum PrefixArch: Sendable, Equatable {
    case arm64
    case x86_64
    case i386

    init?(machine: UInt16) {
        switch machine {
        case 0xaa64: self = .arm64
        case 0x8664: self = .x86_64
        case 0x014c: self = .i386
        default: return nil
        }
    }
}

struct WinePrefix: Sendable, Hashable, Identifiable {
    let appID: String
    let name: String?
    let library: SteamLibrary
    let lastUsed: Date?

    var root: URL { library.compatdata.appending(path: appID) }
    var pfx: URL { root.appending(path: "pfx") }

    var id: String { "\(library.root.path(percentEncoded: false))#\(appID)" }

    var title: String { name ?? String(localized: "App \(appID)") }
}

struct PrefixUsage: Sendable {
    let bytes: Int64
}

struct PrefixBackup: Sendable, Hashable, Identifiable {
    let prefix: WinePrefix
    let url: URL
    let taken: Date?
    let bytes: Int64

    var id: String { url.path(percentEncoded: false) }
    var title: String { prefix.title }
}

enum PrefixStore {

    static func libraries(vdf: URL = SupportPaths.Steam.libraryFoldersVDF) -> [SteamLibrary] {
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else {
            return [library(at: SupportPaths.Steam.userData)]
        }

        var roots = libraryPaths(in: text).map { URL(filePath: $0) }
        if roots.isEmpty { roots = [SupportPaths.Steam.userData] }

        var seen: Set<String> = []
        return roots.compactMap { root in
            guard seen.insert(root.path(percentEncoded: false)).inserted else { return nil }
            return library(at: root)
        }
    }

    // Every "path" in libraryfolders.vdf, with Steam's \\ and \" escapes undone. The one
    // reader for this file, so Uninstall, Prefixes and the 3.0 migration see the same paths.
    static func libraryPaths(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let (key, value, _) = BrandMigration.keyValue(line),
                  key.caseInsensitiveCompare("path") == .orderedSame
            else { return nil }
            return value.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        }
    }

    static func library(at root: URL) -> SteamLibrary {
        SteamLibrary(root: root, volume: volumeName(of: root))
    }

    static func volumeName(of root: URL) -> String? {
        guard
            let values = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeIsRootFileSystemKey]),
            values.volumeIsRootFileSystem != true,
            let name = values.volumeName
        else { return nil }
        return name
    }

    // Every appid under compatdata that actually has a prefix.
    static func all(
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")
    ) -> [WinePrefix] {
        var shortcuts: [String: String]?
        var found: [WinePrefix] = []
        for library in libraries {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: library.compatdata,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let appID = entry.lastPathComponent
                let pfx = entry.appending(path: "pfx")
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: pfx.path(percentEncoded: false), isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }

                var name = appName(appID: appID, in: library)
                if name == nil, let id = UInt32(appID), id & 0x8000_0000 != 0 {
                    if shortcuts == nil { shortcuts = shortcutNames(userdata: userdata) }
                    name = shortcuts?[appID]
                }

                found.append(
                    WinePrefix(
                        appID: appID,
                        name: name,
                        library: library,
                        lastUsed: (try? pfx.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
                    )
                )
            }
        }

        return found.sorted {
            ($0.lastUsed ?? .distantPast, $0.appID) > ($1.lastUsed ?? .distantPast, $1.appID)
        }
    }

    static func appName(appID: String, in library: SteamLibrary) -> String? {
        manifestValue("name", appID: appID, in: library)
    }

    static func shortcutNames(userdata: URL) -> [String: String] {
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: userdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var names: [String: String] = [:]
        for account in accounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let vdf = account.appending(path: "config/shortcuts.vdf")
            guard let data = try? Data(contentsOf: vdf) else { continue }
            names.merge(shortcutNames(vdf: data)) { first, _ in first }
        }
        return names
    }

    static func shortcutNames(vdf data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var names: [String: String] = [:]
        var offset = 0

        func cString() -> String? {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }

        func skip(_ count: Int) -> Bool {
            guard bytes.count - offset >= count else { return false }
            offset += count
            return true
        }

        // Binary KeyValues: type byte, key, value; 0x08 closes a map.
        func map(depth: Int) -> Bool {
            guard depth < 16 else { return false }
            var appID: UInt32?
            var appName: String?
            while offset < bytes.count {
                let type = bytes[offset]
                offset += 1
                if type == 0x08 { break }
                guard let key = cString()?.lowercased() else { return false }
                switch type {
                case 0x00:
                    guard map(depth: depth + 1) else { return false }
                case 0x01:
                    guard let value = cString() else { return false }
                    if key == "appname" { appName = value }
                case 0x02:
                    guard bytes.count - offset >= 4 else { return false }
                    if key == "appid" {
                        appID = bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
                    }
                    offset += 4
                case 0x03, 0x04, 0x06:
                    guard skip(4) else { return false }
                case 0x07, 0x0a:
                    guard skip(8) else { return false }
                default:
                    return false
                }
            }
            if let appID, let appName, !appName.isEmpty { names[String(appID)] = appName }
            return true
        }

        _ = map(depth: 0)
        return names
    }

    static func installDirectory(of prefix: WinePrefix) -> URL? {
        guard let folder = manifestValue("installdir", appID: prefix.appID, in: prefix.library)
        else { return nil }
        let url = prefix.library.steamapps.appending(path: "common").appending(path: folder)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private static func manifestValue(_ key: String, appID: String, in library: SteamLibrary) -> String? {
        let manifest = library.steamapps.appending(path: "appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            // Steam escapes \" \\ \n and \t inside quoted values.
            let fields = line.matches(of: #/"((?:[^"\\]|\\.)*)"/#)
                .map {
                    String($0.1).replacing(#/\\(.)/#) { escape -> String in
                        switch escape.1 {
                        case "n": "\n"
                        case "t": "\t"
                        case "\\", "\"": String(escape.1)
                        default: String(escape.0)
                        }
                    }
                }
            if fields.count >= 2, fields[0] == key { return fields[1] }
        }
        return nil
    }

    static let backupPrefix = "pfx.previous"

    static func backupClock() -> DateFormatter {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyyMMdd-HHmmss"
        return clock
    }

    static func backupDate(of backup: URL) -> Date? {
        let name = backup.lastPathComponent
        guard name.hasPrefix("\(backupPrefix)-") else { return nil }
        let stamp = name.dropFirst(backupPrefix.count + 1).prefix(15)
        return backupClock().date(from: String(stamp))
    }

    static func backupDetails(of prefix: WinePrefix) -> [PrefixBackup] {
        backups(of: prefix).map { url in
            PrefixBackup(
                prefix: prefix,
                url: url,
                taken: backupDate(of: url),
                bytes: directoryBytes(url)
            )
        }
    }

    static func backups(of prefix: WinePrefix) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: prefix.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
            .filter { entry in
                var isDirectory: ObjCBool = false
                let found = fm.fileExists(
                    atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory)
                return found && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func usage(of prefix: WinePrefix) -> PrefixUsage {
        PrefixUsage(bytes: directoryBytes(prefix.pfx))
    }

    enum SizeMetric {
        case privateSize, allocated
    }

    static func directoryBytes(_ url: URL, metric: SizeMetric = .privateSize) -> Int64 {
        struct FileID: Hashable {
            let device: dev_t
            let inode: ino_t
        }
        var seen: Set<FileID> = []
        var total: Int64 = 0
        var root = url.path(percentEncoded: false)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        var paths = [root]
        while let path = paths.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0,
                seen.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
            else { continue }
            total += metric == .allocated ? Int64(info.st_blocks) * 512 : privateBytes(path)
            guard info.st_mode & S_IFMT == S_IFDIR,
                let children = try? FileManager.default.contentsOfDirectory(atPath: path)
            else { continue }
            paths += children.map { path + "/" + $0 }
        }
        return total
    }

    // st_blocks * 512 is the fallback when ATTR_CMNEXT_PRIVATESIZE is unavailable.
    static func privateBytes(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        let allocated = Int64(info.st_blocks) * 512

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        // getattrlist fills in a header, then the private size.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attribute_set_t>.size + 8)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &request, &buffer, buffer.count, options) == 0 else { return allocated }

        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return allocated }
            return raw.loadUnaligned(
                fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }


    static func arch(of prefix: WinePrefix) -> PrefixArch? {
        let dll = prefix.pfx.appending(path: "drive_c/windows/system32/ntdll.dll")
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return nil }
        defer { try? handle.close() }

        guard let dos = try? handle.read(upToCount: 0x40), dos.count == 0x40 else { return nil }
        let lfanew = dos.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x3c, as: UInt32.self))
        }
        do { try handle.seek(toOffset: UInt64(lfanew)) } catch { return nil }

        guard let head = try? handle.read(upToCount: 6), head.count == 6,
            Array(head.prefix(4)) == [0x50, 0x45, 0x00, 0x00]
        else { return nil }

        return PrefixArch(
            machine: head.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
            }
        )
    }

    static var serverRoot: URL { URL(filePath: "/tmp/.wine-\(getuid())") }

    static func serverDirectory(of prefix: WinePrefix, root: URL = serverRoot) -> URL? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: prefix.pfx.path(percentEncoded: false)
            ),
            let device = attributes[.systemNumber] as? Int,
            let inode = attributes[.systemFileNumber] as? Int
        else { return nil }

        return root.appending(
            path: "server-\(String(device, radix: 16))-\(String(inode, radix: 16))")
    }

    static func isInUse(
        _ prefix: WinePrefix, root: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2)
    ) -> Bool {
        let lock = open(lockPath(of: prefix), O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if lock >= 0 {
            defer { FileLock.release(lock) }
            guard locked(lock) else { return true }
        } else if errno != ENOENT {
            return true
        }
        return serverIsBusy(prefix, root: root, lsof: lsof, drainTimeout: drainTimeout)
    }

    // A launch takes this lock while it sets the prefix up. Holding it stops a launch from
    // starting partway through a rebuild/delete.
    static func claim(
        _ prefix: WinePrefix, root: URL = serverRoot, lsof: String = "/usr/sbin/lsof",
        drainTimeout: DispatchTimeInterval = .seconds(2)
    ) -> PrefixClaim? {
        let lock = open(lockPath(of: prefix), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            guard errno == ENOENT,
                !serverIsBusy(prefix, root: root, lsof: lsof, drainTimeout: drainTimeout)
            else { return nil }
            return PrefixClaim(fd: -1)
        }
        guard locked(lock), !serverIsBusy(prefix, root: root, lsof: lsof, drainTimeout: drainTimeout)
        else {
            FileLock.release(lock)
            return nil
        }
        return PrefixClaim(fd: lock)
    }

    private static func lockPath(of prefix: WinePrefix) -> String {
        prefix.root.appending(path: ".notproton-prefix.lock").path(percentEncoded: false)
    }

    private static func locked(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    private static func serverIsBusy(
        _ prefix: WinePrefix, root: URL, lsof: String, drainTimeout: DispatchTimeInterval
    ) -> Bool {
        guard let dir = serverDirectory(of: prefix, root: root),
            FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        else { return false }

        guard let result = try? Shell.run(
            lsof, ["-t", "+D", dir.path(percentEncoded: false)], drainTimeout: drainTimeout)
        else { return true }

        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }

        return result.outputLost || !result.stderr.isEmpty
    }
}

struct PrefixClaim {
    fileprivate let fd: Int32

    func release() {
        if fd >= 0 { FileLock.release(fd) }
    }
}
