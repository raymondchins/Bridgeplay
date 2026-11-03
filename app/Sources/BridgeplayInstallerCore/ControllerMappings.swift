import Foundation

/// The user's gamecontrollerdb.txt is seeded from the shipped one. When they already have a
/// file, only the shipped mappings whose GUID it lacks are appended, so new pads reach
/// existing installs while the user's own lines stay as they are.
public enum ControllerMappings {
    /// The text with the missing mappings appended, or nil when there is nothing to add.
    public static func merged(_ existing: String, shipped: String) -> String? {
        func guid(_ line: Substring) -> String? {
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#") ? nil : String(line.prefix { $0 != "," })
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
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + added.joined(separator: "\n") + "\n"
    }

    /// Appends what `shipped` has and `file` lacks. A file that cannot be read is left alone.
    public static func update(_ file: URL, from shipped: URL) throws {
        guard let existing = try? String(contentsOf: file, encoding: .utf8),
              let shippedText = try? String(contentsOf: shipped, encoding: .utf8),
              let text = merged(existing, shipped: shippedText) else { return }
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
