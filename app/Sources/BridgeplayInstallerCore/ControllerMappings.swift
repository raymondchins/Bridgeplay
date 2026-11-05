import Foundation

/// The user's gamecontrollerdb.txt is seeded from the shipped one. When they already have a
/// file, only the shipped mappings whose GUID it lacks are appended, so new pads reach
/// existing installs while the user's own lines stay as they are.
public enum ControllerMappings {
    /// The text to append to `existing` for the missing mappings, or nil when there is nothing to add.
    public static func additions(to existing: String, shipped: String) -> String? {
        func guid(_ line: Substring) -> String? {
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#") ? nil : String(line.prefix { $0 != "," }).lowercased()
        }
        let have = Set(existing.split(whereSeparator: \.isNewline).compactMap(guid))
        let haveComments = Set(existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        var added: [String] = [], comments: [String] = [], seen = have
        for raw in shipped.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { comments = [] }
            else if line.hasPrefix("#") { comments.append(line) }
            else {
                if let id = guid(raw), seen.insert(id).inserted {
                    added += comments.filter { !haveComments.contains($0) } + [line]
                }
                comments = []
            }
        }
        guard !added.isEmpty else { return nil }
        let separator = existing.isEmpty || existing.utf8.last == 0x0A ? "" : "\n"
        return separator + added.joined(separator: "\n") + "\n"
    }

    /// Appends what `shipped` has and `file` lacks, in place so a symlink or the file's mode stays.
    public static func update(_ file: URL, from shipped: URL) throws {
        let existing = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let shippedText = String(decoding: try Data(contentsOf: shipped), as: UTF8.self)
        guard let more = additions(to: existing, shipped: shippedText) else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
    }
}
