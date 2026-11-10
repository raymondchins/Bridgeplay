import AppKit

enum TextWidth {

    static let cellPadding: CGFloat = 24
    static let maxTitle: CGFloat = 320

    // Table bodies ask for the same widths on every redraw; measuring text through AppKit each
    // time showed up as the main cost of opening Prefixes. Only the main thread measures.
    @MainActor private static var measured: [String: CGFloat] = [:]

    @MainActor static func of(_ text: String, size: CGFloat = NSFont.systemFontSize) -> CGFloat {
        let key = "\(size)\u{0}\(text)"
        if let width = measured[key] { return width }
        let font = NSFont.systemFont(ofSize: size)
        let width = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        if measured.count > 4000 { measured.removeAll() }
        measured[key] = width
        return width
    }

    @MainActor static func widest(_ texts: [String], padding: CGFloat = cellPadding) -> CGFloat? {
        guard let widest = texts.map({ of($0) }).max() else { return nil }
        return widest + padding
    }
}
