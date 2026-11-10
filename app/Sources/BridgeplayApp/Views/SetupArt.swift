import AppKit
import SwiftUI
import BridgeplayUI

// The Setup Assistant's art rail, in bridgeplay.dev's motifs: an aurora of the brand gradient
// over a faint grid, the hero line, and one illustration per step (the checker's scan line,
// the DirectX to Metal flow, the controller's rings, the bridge drawing itself in, the
// spinning gradient edge). Reduce Motion freezes all of it on a still frame.
struct SetupArt: View {
    let step: SetupAssistant.Step
    var progress: Double = 0
    var running = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Aurora(t: t, lean: Float(step.rawValue) / 4)
                GridLines()
                illustration(t: t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 70)
                    .id(step)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                            removal: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text("Windows games.")
                        .foregroundStyle(BP.fg)
                    Text("In your Mac's Steam.")
                        .foregroundStyle(BP.iridescent)
                }
                .font(BP.sans(19, .semibold))
                .tracking(-0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .background(BP.bg)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func illustration(t: Double) -> some View {
        switch step {
        case .mac: GameWall(t: t)
        case .graphics: HUDArt(t: t)
        case .steam: SteamArt(t: t)
        case .finish: LightUpArt(t: t, progress: progress, running: running)
        case .done: DoneArt(t: t)
        }
    }
}

// MARK: - Backdrop

// The brand gradient as a slow aurora. `lean` (0...1) moves the bright pool along the
// bottom edge; the Setup Assistant shifts it per step so moving on is felt.
struct Aurora: View {
    let t: Double
    var lean: Float = 0.5

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.45 + wave(1, 0.31)], [0.5 + wave(2, 0.27), 0.5 + wave(3, 0.23)], [1, 0.55 + wave(4, 0.29)],
                [0, 1], [0.35 + 0.3 * lean + wave(5, 0.21), 1], [1, 1],
            ],
            colors: [
                .black, .black, .black,
                BP.violet.opacity(0.42), .black, BP.blue.opacity(0.30),
                BP.violet.opacity(0.18), BP.pink.opacity(0.34), BP.blue.opacity(0.16),
            ],
            smoothsColors: true
        )
        .blur(radius: 20)
        // The mesh and its blur in one offscreen Metal pass: measured 50% → 19% CPU on Status
        .drawingGroup()
        .animation(.easeInOut(duration: 0.9), value: lean)
    }

    private func wave(_ seed: Double, _ speed: Double) -> Float {
        Float(sin(t * speed + seed) * 0.09)
    }
}

struct GridLines: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            context.stroke(path, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
        }
        .mask(RadialGradient(colors: [.white, .clear], center: .init(x: 0.5, y: 0.4), startRadius: 10, endRadius: 260))
    }
}

// MARK: - Steps

// Check your Mac: the hero's games marquee, turned on its side. Two columns of covers drift
// in opposite directions under the aurora.
struct GameWall: View {
    let t: Double
    @State private var covers = GameCovers.shared

    var body: some View {
        let images = covers.images
        GeometryReader { proxy in
            // Wider and taller than the rail, so the tilt never shows an empty corner.
            let wallWidth = proxy.size.width * 1.5
            let wallHeight = proxy.size.height * 1.5
            let columns = 4
            let gap: CGFloat = 8
            let cardWidth = (wallWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<columns, id: \.self) { column in
                    let picks = images.enumerated().filter { $0.offset % columns == column }.map(\.element)
                    self.column(picks.isEmpty ? images : picks, width: cardWidth, gap: gap, visible: wallHeight,
                                speed: column % 2 == 0 ? 12 + Double(column) : -(10 + Double(column)),
                                phase: Double(column) * 0.37)
                }
            }
            .frame(width: wallWidth, height: wallHeight, alignment: .top)
            .clipped()
            .rotationEffect(.degrees(-10))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.15), location: 0.22),
                                   .init(color: .black.opacity(0.1), location: 0.55), .init(color: .black.opacity(0.95), location: 0.86)],
                           startPoint: .top, endPoint: .bottom)
        }
        .padding(.bottom, -70)
        .opacity(images.isEmpty ? 0 : 1)
        .animation(.easeOut(duration: 0.6), value: images.count)
        .task { await covers.load() }
    }

    private func column(_ images: [NSImage], width: CGFloat, gap: CGFloat, visible: CGFloat, speed: Double, phase: Double) -> some View {
        let height = width * 1.5
        let span = CGFloat(max(images.count, 1)) * (height + gap)
        // Enough copies that a full span of scrolling still fills the wall.
        let copies = images.isEmpty ? 0 : Int((visible / span).rounded(.up)) + 2
        let travel = (t * speed + phase * Double(span)).truncatingRemainder(dividingBy: Double(span))
        let shift = CGFloat(travel < 0 ? travel + Double(span) : travel)
        return VStack(spacing: gap) {
            ForEach(0..<(images.count * copies), id: \.self) { index in
                Image(nsImage: images[index % images.count])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            }
        }
        .offset(y: -shift)
        .frame(width: width, alignment: .top)
    }
}

// Covers for the wall: the games installed in this Mac's Steam, from Steam's own library
// cache. A Mac without them gets a fixed set from Steam's CDN, so no game art ships with
// Bridgeplay.
@MainActor
@Observable
final class GameCovers {
    static let shared = GameCovers()

    struct Cover {
        let image: NSImage
        let name: String?
    }

    private(set) var covers: [Cover] = []
    var images: [NSImage] { covers.map(\.image) }
    @ObservationIgnored private var started = false

    // Windows-only games shown on bridgeplay.dev.
    static let fallback = [1139900, 1151640, 1222700, 1364780, 1426210, 1778820, 1850570, 1888930,
                           1971870, 2001120, 2138710, 2651280, 292030, 2968420, 3405340, 3669870]

    func load() async {
        guard !started else { return }
        started = true
        let local = await Task.detached(priority: .utility) { Self.localCovers(limit: 16) }.value
        if local.count >= 6 {
            covers = local
            return
        }
        var fetched: [Cover] = local
        await withTaskGroup(of: NSImage?.self) { group in
            for id in Self.fallback {
                group.addTask {
                    guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return NSImage(data: data)
                }
            }
            for await image in group { if let image { fetched.append(Cover(image: image, name: nil)) } }
        }
        covers = fetched
    }

    nonisolated static func localCovers(limit: Int) -> [Cover] {
        let cache = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
        let fm = FileManager.default
        var titles: [String: String?] = [:]
        for library in PrefixStore.libraries() {
            let names = (try? fm.contentsOfDirectory(atPath: library.steamapps.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                let id = String(name.dropFirst("appmanifest_".count).dropLast(".acf".count))
                let text = try? String(contentsOf: library.steamapps.appending(path: name), encoding: .utf8)
                titles[id] = text.flatMap(Self.title(inManifest:))
            }
        }
        var images: [Cover] = []
        for id in titles.keys.sorted() {
            let folder = cache.appending(path: id)
            let direct = folder.appending(path: "library_600x900.jpg")
            var file: URL? = fm.fileExists(atPath: direct.path(percentEncoded: false)) ? direct : nil
            if file == nil, let subfolders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                file = subfolders.lazy.map { $0.appending(path: "library_600x900.jpg") }
                    .first { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
            }
            if let file, let image = NSImage(contentsOf: file) { images.append(Cover(image: image, name: titles[id] ?? nil)) }
            if images.count == limit { break }
        }
        return images
    }

    // The "name" value of a Steam appmanifest_<id>.acf.
    nonisolated static func title(inManifest text: String) -> String? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\"", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if fields.count >= 2, fields[0] == "name" { return fields[1] }
        }
        return nil
    }
}

// Graphics: the hero's look, a game on screen with the Metal HUD over it. Covers cycle from
// the same set as the wall; the frame rate hovers around 90 like the site's demo.
private struct HUDArt: View {
    let t: Double
    @State private var covers = GameCovers.shared

    private static let fpsGreen = Color(hex: 0x7DFF8A)

    var body: some View {
        let images = covers.images
        let index = images.isEmpty ? 0 : Int(t / 4).quotientAndRemainder(dividingBy: images.count).remainder
        ZStack(alignment: .bottom) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BP.raise)
                if !images.isEmpty {
                    Image(nsImage: images[index])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .id(index)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.8), value: index)
                }
            }
            .frame(width: 172, height: 258)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BP.lineStrong, lineWidth: 1))
            .shadow(color: BP.violet.opacity(0.35), radius: 36, y: 12)

            hud
                .offset(x: 26, y: 34)
        }
        .padding(.trailing, 20)
        .task { await covers.load() }
    }

    private var fps: Int {
        Int((90 + sin(t * 1.7) * 3 + sin(t * 4.3) * 1.8).rounded())
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(SetupChecks.chipName, "D3DMetal")
            row("Direct3D 12", "Metal")
            row("MetalFX upscale", "On")
            row("Frame generation", "2x")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(fps)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.fpsGreen)
                    .contentTransition(.numericText(value: Double(fps)))
                Text(verbatim: "FPS").foregroundStyle(BP.fg3)
            }
            .padding(.top, 3)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<22, id: \.self) { bar in
                    let past = t - Double(22 - bar) * 0.18
                    let value = 0.62 + sin(past * 1.7) * 0.12 + sin(past * 4.3) * 0.08
                    RoundedRectangle(cornerRadius: 1).fill(Self.fpsGreen.opacity(0.7))
                        .frame(height: 16 * value)
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(hex: 0xE8E8EA))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 168)
        .background(Color(hex: 0x0A0A0C).opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: key).foregroundStyle(Color(hex: 0x9A9AA0)).lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: value).lineLimit(1)
        }
    }
}

// Steam: the landing page's library demo. The cursor goes to Play, presses it, and the button
// turns into Running, with "Runs with Bridgeplay" beside it.
private struct SteamArt: View {
    let t: Double
    @State private var covers = GameCovers.shared

    private static let green = Color(hex: 0x59BF40)
    private static let blue = Color(hex: 0x1A9FFF)
    private static let ink = Color(hex: 0xE6ECF2)
    private static let muted = Color(hex: 0x8F98A0)

    var body: some View {
        let cycle = 4.2
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let list = Array(covers.covers.prefix(4))
        let featured = list.first
        let running = phase > 0.49 && phase < 0.92
        let pressed = phase > 0.47 && phase < 0.51
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let featured {
                            Image(nsImage: featured.image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: [Color(hex: 0x2C2F4A), Color(hex: 0x12131F)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(width: 204, height: 96, alignment: .top)
                    .clipped()
                    LinearGradient(colors: [.clear, Color(hex: 0x131B26)], startPoint: .center, endPoint: .bottom)
                    Text(verbatim: featured?.name ?? "Windows game")
                        .font(BP.sans(13, .semibold))
                        .foregroundStyle(Self.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 7)
                }
                .frame(width: 204, height: 96)

                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        Text(verbatim: running ? "RUNNING" : "PLAY")
                            .font(BP.sans(10, .bold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 24)
                    .background(running ? Self.blue : Self.green, in: RoundedRectangle(cornerRadius: 2))
                    .scaleEffect(pressed ? 0.95 : 1)
                    .animation(.easeOut(duration: 0.15), value: running)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "RUNS WITH").font(BP.sans(8, .semibold)).tracking(0.4).foregroundStyle(Self.muted)
                        Text(verbatim: "Bridgeplay").font(BP.sans(11, .semibold)).foregroundStyle(BP.iridescent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)

                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "LIBRARY")
                        .font(BP.sans(8, .semibold)).tracking(0.5).foregroundStyle(Self.muted)
                        .padding(.horizontal, 6).padding(.bottom, 3)
                    ForEach(Array(list.enumerated()), id: \.offset) { index, cover in
                        HStack(spacing: 8) {
                            Image(nsImage: cover.image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 2))
                            Text(verbatim: cover.name ?? " ")
                                .font(BP.sans(10, .medium))
                                .foregroundStyle(index == 0 ? Self.ink : Self.muted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(index == 0 ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(8)
            }
            .frame(width: 204)
            .background(LinearGradient(colors: [Color(hex: 0x1B2838), Color(hex: 0x131B26)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: BP.blue.opacity(running ? 0.45 : 0.2), radius: 36, y: 12)
            .animation(.easeOut(duration: 0.4), value: running)

            cursor(phase: phase)
        }
        .frame(width: 204)
        .task { await covers.load() }
    }

    // cursor-go: in from the top right, onto Play, a press, a pause, then gone.
    private func cursor(phase: Double) -> some View {
        let start = CGPoint(x: 170, y: 40)
        let end = CGPoint(x: 52, y: 112)
        let travel = min(1, phase / 0.42)
        let eased = 1 - pow(1 - travel, 3)
        let x = start.x + (end.x - start.x) * eased
        let y = start.y + (end.y - start.y) * eased
        let opacity = phase < 0.1 ? phase / 0.1 : (phase > 0.9 ? max(0, (1 - phase) / 0.1) : 1)
        return CursorShape()
            .fill(.white)
            .overlay(CursorShape().stroke(.black, lineWidth: 1))
            .frame(width: 16, height: 16)
            .scaleEffect(phase > 0.47 && phase < 0.52 ? 0.82 : 1)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

private struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(5, 3.2)); path.addLine(to: p(5, 18.8)); path.addLine(to: p(9.3, 14.7))
        path.addLine(to: p(12, 20.8)); path.addLine(to: p(14.6, 19.7)); path.addLine(to: p(11.9, 13.7))
        path.addLine(to: p(17.9, 13.7)); path.closeSubpath()
        return path
    }
}

// Set Up: a tilted grid of the library's covers, dimmed. Each finished task lights its share
// of them in colour; a band of light sweeps across while setup works.
private struct LightUpArt: View {
    let t: Double
    let progress: Double
    let running: Bool
    @State private var covers = GameCovers.shared

    private let columns = 4
    private let rows = 5
    // A fixed scatter, so tiles light across the grid rather than row by row.
    private static let order = [7, 2, 13, 18, 4, 11, 0, 16, 9, 14, 6, 19, 1, 12, 17, 3, 10, 15, 5, 8]

    var body: some View {
        let images = covers.images
        let count = columns * rows
        let lit = Int((progress * Double(count)).rounded())
        GeometryReader { proxy in
            let width = proxy.size.width * 1.45
            let gap: CGFloat = 8
            let tile = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack {
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                let on = (Self.order.firstIndex(of: index) ?? count) < lit
                                cover(images, index: index, on: on, size: CGSize(width: tile, height: tile * 1.5))
                            }
                        }
                        .offset(x: row.isMultiple(of: 2) ? 0 : tile * 0.35)
                    }
                }
                if running {
                    let sweep = (t / 2.2).truncatingRemainder(dividingBy: 1)
                    LinearGradient(colors: [.clear, .white.opacity(0.16), BP.blue.opacity(0.12), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 120)
                        .blendMode(.plusLighter)
                        .offset(x: (sweep * 2 - 1) * width * 0.7)
                }
            }
            .frame(width: width)
            .rotationEffect(.degrees(-10))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2 - 20)
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.1), location: 0.22),
                                   .init(color: .black.opacity(0.1), location: 0.55), .init(color: .black.opacity(0.95), location: 0.86)],
                           startPoint: .top, endPoint: .bottom)
        }
        .padding(.bottom, -70)
        .animation(.easeOut(duration: 0.7), value: lit)
        .task { await covers.load() }
    }

    @ViewBuilder
    private func cover(_ images: [NSImage], index: Int, on: Bool, size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BP.raise2)
            if !images.isEmpty {
                Image(nsImage: images[index % images.count])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(on ? 1 : 0)
                    .opacity(on ? 1 : 0.28)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(on ? AnyShapeStyle(BP.iridescentDiagonal) : AnyShapeStyle(Color.white.opacity(0.06)), lineWidth: on ? 1.2 : 1))
        .shadow(color: on ? BP.violet.opacity(0.35) : .clear, radius: 10)
        .scaleEffect(on ? 1 : 0.96)
    }
}

// Done: the app icon's glass mark over a soft violet glow. The bridge itself stays white.
private struct DoneArt: View {
    let t: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [BP.violet.opacity(0.45), BP.blue.opacity(0.15), .clear], center: .center, startRadius: 0, endRadius: 120))
                .frame(width: 260, height: 260)
                .scaleEffect(1 + sin(t * 1.2) * 0.04)
            GlassMark(size: 124)
                .offset(y: sin(t * 1.1) * 4)
        }
    }
}
