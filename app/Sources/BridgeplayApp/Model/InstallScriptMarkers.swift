// Steam runs a game's installscript.vdf "Run Process" entries (redistributables such as
// the PlayStation PC SDK) only while the entry's HasRunKey value is missing. A rebuild
// carries user.reg into a fresh prefix but none of what those installers put in
// drive_c, so a carried HKCU marker would make Steam skip an installer whose files are
// gone. Dropping the marker makes Steam run it again on the next launch.

import Foundation

enum InstallScriptMarkers {

    struct Marker: Equatable {
        let key: String
        let value: String
    }

    // "Run Process" entries whose HasRunKey lives in HKEY_CURRENT_USER, with the key
    // given relative to it, as user.reg names it.
    static func markers(inScript text: String) -> [Marker] {
        var markers: [Marker] = []
        var path: [String] = []
        var pending: String?
        // isNewline, as "\r\n" is one Character and a CRLF script would read as one line.
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                if let name = pending { path.append(name) }
                pending = nil
                continue
            }
            if line == "}" {
                if !path.isEmpty { path.removeLast() }
                pending = nil
                continue
            }
            let fields = quoted(line)
            if fields.count == 1 {
                pending = fields[0]
            } else if fields.count >= 2, fields[0].caseInsensitiveCompare("HasRunKey") == .orderedSame,
                path.count >= 3, path[path.count - 2].caseInsensitiveCompare("Run Process") == .orderedSame
            {
                let key = fields[1].replacingOccurrences(of: "\\\\", with: "\\")
                let hive = "HKEY_CURRENT_USER\\"
                guard key.uppercased().hasPrefix(hive) else { continue }
                markers.append(Marker(key: String(key.dropFirst(hive.count)), value: path[path.count - 1]))
            }
        }
        return markers
    }

    // Returns the markers removed from the registry text.
    static func clear(_ markers: [Marker], in registry: String) -> (text: String, removed: [Marker]) {
        guard !markers.isEmpty else { return (registry, []) }
        var removed: [Marker] = []
        var section: String?
        var out: [Substring] = []
        for line in registry.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                section = line.dropFirst().split(separator: "]", maxSplits: 1).first
                    .map { $0.replacingOccurrences(of: "\\\\", with: "\\") }
            } else if let section, line.hasPrefix("\""),
                let hit = markers.first(where: {
                    $0.key.caseInsensitiveCompare(section) == .orderedSame
                        && line.hasPrefix("\"\(escaped($0.value))\"=")
                })
            {
                removed.append(hit)
                continue
            }
            out.append(line)
        }
        return (out.joined(separator: "\n"), removed)
    }

    // Clears the markers of the app's install script from userReg. Returns the names of
    // the entries Steam will run again.
    @discardableResult
    static func clear(userReg: URL, installDirectory: URL?) -> [String] {
        guard let installDirectory,
            let script = try? String(
                contentsOf: installDirectory.appending(path: "installscript.vdf"), encoding: .utf8),
            let registry = try? String(contentsOf: userReg, encoding: .utf8)
        else { return [] }
        let result = clear(markers(inScript: script), in: registry)
        guard !result.removed.isEmpty else { return [] }
        do {
            try Data(result.text.utf8).write(to: userReg, options: .atomic)
        } catch {
            return []
        }
        return result.removed.map(\.value)
    }

    private static func quoted(_ line: String) -> [String] {
        line.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
