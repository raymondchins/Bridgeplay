import Foundation

extension String {
    /// Keep a short closing phrase together in narrow rows and native confirmation sheets.
    var keepingLastWordsTogether: String {
        let words = split(separator: " ")
        guard words.count > 3, let first = words.suffix(3).first else { return self }
        let ending = self[first.startIndex...]
        guard ending.count <= 32, !ending.contains(where: \.isNewline),
              ending.range(of: #"\p{Han}"#, options: .regularExpression) == nil else { return self }
        return self[..<first.startIndex] + ending.replacingOccurrences(of: " ", with: "\u{00a0}")
    }
}
