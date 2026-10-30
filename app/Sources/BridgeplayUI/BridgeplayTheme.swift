import CoreText
import SwiftUI

// The look of bridgeplay.dev (styles.css :root) for the app's own surfaces: black canvas,
// near-white type in Geist, hairline borders, small radii, and the violet-blue-pink
// gradient kept for emphasis only (progress, the last step, one word of a headline).
public enum BP {
    public static let bg = Color(hex: 0x000000)
    public static let raise = Color(hex: 0x0D0D0F)
    public static let raise2 = Color(hex: 0x161618)
    public static let fg = Color(hex: 0xF5F5F7)
    public static let fg2 = Color(hex: 0xA1A1A6)
    public static let fg3 = Color(hex: 0x86868B)
    public static let line = Color.white.opacity(0.08)
    public static let lineStrong = Color.white.opacity(0.18)
    public static let violet = Color(hex: 0x8B7BFF)
    public static let blue = Color(hex: 0x4FB3FF)
    public static let pink = Color(hex: 0xFF7AC6)
    public static let green = Color(hex: 0x30D158)
    public static let orange = Color(hex: 0xFF9F0A)
    public static let red = Color(hex: 0xFF453A)

    public static let iridescent = LinearGradient(colors: [violet, blue, pink], startPoint: .leading, endPoint: .trailing)
    public static let iridescentDiagonal = LinearGradient(colors: [violet, blue, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    public static let radius: CGFloat = 12

    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts()
        return .custom("Geist", size: size).weight(weight)
    }

    public static func display(_ size: CGFloat) -> Font {
        registerFonts()
        return .custom("Unbounded", size: size).weight(.semibold)
    }

    // Process-scoped, so nothing is installed on the Mac. Missing glyphs (Chinese) fall
    // back to the system font.
    private static let registered: Void = {
        let resources = Bundle.main.resourceURL.flatMap { resourceURL in
            Bundle(url: resourceURL.appendingPathComponent(
                "BridgeplayApp_BridgeplayUI.bundle", isDirectory: true
            ))
        } ?? .module
        for name in ["geist", "unbounded"] {
            guard let url = resources.url(forResource: name, withExtension: "woff2", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    public static func registerFonts() { _ = registered }
}

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// .pill on the site: white with black text, fully round. The secondary kind is a
// hairline capsule in the foreground colour.
public struct PillButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, plain }
    public var kind: Kind = .primary
    public var large = false

    public init(kind: Kind = .primary, large: Bool = false) {
        self.kind = kind
        self.large = large
    }

    @Environment(\.isEnabled) private var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BP.sans(large ? 14 : 13, .semibold))
            .tracking(-0.15)
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 4 : (large ? 18 : 13))
            .frame(height: large ? 34 : 28)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(configuration.isPressed ? Color.white.opacity(0.85) : (isEnabled ? Color.white : BP.raise2))
                case .secondary:
                    Capsule().fill(configuration.isPressed ? BP.raise2 : Color.clear)
                        .overlay(Capsule().strokeBorder(BP.lineStrong, lineWidth: 1))
                case .plain:
                    Color.clear
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? .black : BP.fg3
        case .secondary: isEnabled ? BP.fg : BP.fg3
        case .plain: isEnabled ? BP.fg2 : BP.fg3.opacity(0.6)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static var pill: PillButtonStyle { PillButtonStyle() }
    public static var pillLarge: PillButtonStyle { PillButtonStyle(large: true) }
    public static var pillSecondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    public static var pillSecondaryLarge: PillButtonStyle { PillButtonStyle(kind: .secondary, large: true) }
    public static var pillPlain: PillButtonStyle { PillButtonStyle(kind: .plain, large: true) }
}

// The Bridgeplay mark (helpers/icon/bridgeplay-mark.svg) as shapes in a 24-unit box, so the
// art can draw it in stroke by stroke: the deck and towers, the suspension cable, and the
// cable's reflection.
public enum BridgePart: Sendable { case deck, cable, echo }

public struct BridgeShape: Shape {
    public let part: BridgePart

    public init(part: BridgePart) {
        self.part = part
    }

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        // 2.04, not 2.4, puts the drawn mark (strokes included) in the middle of the box.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (2.4 + x * 0.8) * s, y: rect.minY + (2.04 + y * 0.8) * s)
        }
        var path = Path()
        switch part {
        case .deck:
            // The towers stop at 4.6, under the cable, so no cap shows around its peaks.
            path.move(to: p(2, 14)); path.addLine(to: p(22, 14))
            path.move(to: p(6.5, 4.6)); path.addLine(to: p(6.5, 14))
            path.move(to: p(17.5, 4.6)); path.addLine(to: p(17.5, 14))
        case .cable:
            path.move(to: p(2, 7))
            path.addCurve(to: p(6.5, 4), control1: p(4.5, 7), control2: p(5.5, 4))
            path.addCurve(to: p(12, 11), control1: p(7.5, 4), control2: p(9.5, 11))
            path.addCurve(to: p(17.5, 4), control1: p(14.5, 11), control2: p(16.5, 4))
            path.addCurve(to: p(22, 7), control1: p(18.5, 4), control2: p(19.5, 7))
        case .echo:
            // One smooth arch: it keeps sloping where it meets the pillars instead of
            // flattening into a step, and the pillars end on it.
            path.move(to: p(6.5, 16.5)); path.addLine(to: p(6.5, 19.4))
            path.move(to: p(17.5, 16.5)); path.addLine(to: p(17.5, 19.4))
            path.move(to: p(2, 21))
            path.addCurve(to: p(6.5, 19.4), control1: p(3.5, 21), control2: p(5, 19.955))
            path.addCurve(to: p(12, 17.3), control1: p(8.33, 18.72), control2: p(10.17, 17.3))
            path.addCurve(to: p(17.5, 19.4), control1: p(13.83, 17.3), control2: p(15.67, 18.72))
            path.addCurve(to: p(22, 21), control1: p(19, 19.955), control2: p(20.5, 21))
        }
        return path
    }

    // Stroke widths from the SVG, scaled to a mark drawn `size` points wide.
    public static func width(_ part: BridgePart, size: CGFloat) -> CGFloat {
        let unit = size / 24 * 0.8
        switch part {
        case .deck: return 1.8 * unit
        case .cable: return 1.4 * unit
        case .echo: return 1.2 * unit
        }
    }
}

// The mark drawn flat on its black tile, as in the nav bar and favicon.
public struct BridgeplayMark: View {
    public var size: CGFloat = 22

    public init(size: CGFloat = 22) {
        self.size = size
    }

    public var body: some View {
        BridgeStrokes(size: size)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(BP.lineStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// The mark on the app icon's glass tile. Shown on its own only, never next to the wordmark.
public struct GlassMark: View {
    public var size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(stops: [.init(color: Color(hex: 0x232326), location: 0),
                                             .init(color: Color(hex: 0x0B0B0D), location: 0.7),
                                             .init(color: Color(hex: 0x060607), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            tile.fill(RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: -0.1),
                                     startRadius: 0, endRadius: size * 0.66))
            BridgeStrokes(size: size)
                .shadow(color: .black.opacity(0.6), radius: size * 0.012, y: size * 0.01)
        }
        .frame(width: size, height: size)
        .overlay(tile.strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: size * 0.08, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

private struct BridgeStrokes: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            BridgeShape(part: .deck)
                .stroke(BP.fg, style: StrokeStyle(lineWidth: BridgeShape.width(.deck, size: size), lineCap: .round))
            BridgeShape(part: .cable)
                .stroke(BP.fg, style: StrokeStyle(lineWidth: BridgeShape.width(.cable, size: size), lineCap: .round, lineJoin: .round))
            BridgeShape(part: .echo)
                .stroke(BP.fg.opacity(0.35), style: StrokeStyle(lineWidth: BridgeShape.width(.echo, size: size), lineCap: .round))
        }
    }
}
