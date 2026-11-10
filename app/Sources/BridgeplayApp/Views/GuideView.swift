import SwiftUI
import BridgeplayUI

// How to reach a game's Bridgeplay settings in Steam, and what every one of them does. The
// pictures are drawings of Steam's own screens in Steam's colours (like the ones on
// bridgeplay.dev), not screenshots: the game list is the player's own, read from Steam's
// library cache, so no game art ships with Bridgeplay. The option names and order follow the
// Bridgeplay tab the dylib adds to a game's Steam Properties (dylib/feats/webpatch.c); keep them
// in step.
struct GuideView: View {
    @State private var entries: [LibraryEntry] = LibraryEntry.samples

    private var game: String { entries.count > 1 ? entries[1].name : "Deadlock" }

    private var toolbarSpacer: some View {
        Color.clear.frame(width: 1, height: 28).accessibilityHidden(true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                steps
                compatibilityPage
                tips
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Guide")
        // macOS draws a shorter title bar for a page with no toolbar items; an invisible one
        // keeps Guide's the same height as every other page's.
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { toolbarSpacer }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { toolbarSpacer }
            }
        }
        .task {
            let local = await Task.detached(priority: .utility) { LibraryEntry.local(limit: 6) }.value
            if local.count >= 3 { entries = local }
        }
    }

    // MARK: Header and steps

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guide")
                .font(BP.sans(11, .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(BP.iridescent)
            Text("Bridgeplay lives in Steam")
                .font(BP.sans(30, .semibold))
                .tracking(-1)
            Text("Windows games install and start from your Steam library like Mac games. Each game's Bridgeplay settings are in Steam, on its Properties page, and every one is explained below.")
                .font(BP.sans(14))
                .foregroundStyle(BP.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 18) {
            GuideStep(number: 1, text: String(localized: "In your Steam library, right-click the game and choose Properties…")) {
                SteamLibraryDrawing(entries: entries)
            }
            GuideStep(number: 2, text: String(localized: "Choose Bridgeplay. Steam Play's engine picker is at the top, Bridgeplay's settings below it.")) {
                SteamPropertiesDrawing(game: game)
            }
        }
    }

    // MARK: The Bridgeplay tab, block by block

    private var compatibilityPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Every setting on the Bridgeplay tab")
                    .font(BP.sans(20, .semibold))
                    .tracking(-0.5)
                Text("Drawn the way Steam shows them. Changes apply the next time the game starts. Not sure? Leave a setting as it is: Bridgeplay picks what works for each game.")
                    .font(BP.sans(13))
                    .foregroundStyle(BP.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SteamBlock(title: "Steam Play") {
                SteamRow(.select(String(localized: "Select compatibility tool"), "Default (WineCX 11.17 (msync, D3D…"),
                         note: String(localized: "Which engine runs the game. Default is Bridgeplay's own: WineCX 11.17 with msync and D3DMetal. WineHQ 11.15 is there for games that want DXMT or DXVK. Pick a Proton build only if you know it runs on a Mac."))
                SteamRow(.toggle(String(localized: "Show all compatibility tools"), false),
                         note: String(localized: "Steam's own switch. It also lists tools made for Linux, which do not run on a Mac. Leave it off."))
            }

            SteamBlock(title: String(localized: "Graphics")) {
                SteamRow(.dropdown(nil, String(localized: "Automatic")),
                         note: String(localized: "How the game's DirectX reaches your GPU. Automatic picks per game. D3DMetal (Apple's Game Porting Toolkit) runs DirectX 11 and 12 and is the default. DXMT runs DirectX 10 and 11 directly on Metal. DXVK runs DirectX 9 to 11 through Vulkan. WineD3D is Wine's own translation, for very old games."))
                SteamRow(.check("DLSS", true),
                         note: String(localized: "Lets the game offer NVIDIA DLSS. Apple's MetalFX does the upscaling, and DLSS Frame Generation is experimental and off by default. Turn DLSS on in the game's own settings as well."))
                SteamRow(.check(String(localized: "Advertise AVX2 to Rosetta"), true),
                         note: String(localized: "Tells the game the processor supports AVX2, which some recent games need to start."))
                SteamRow(.check("MSync", true),
                         note: String(localized: "A faster way for the game's threads to wait on each other. Leave it on unless a game hangs."))
                SteamRow(.check(String(localized: "High Resolution"), true),
                         note: String(localized: "Draws at your display's full Retina resolution instead of half. Sharper, heavier on the GPU."))
            }

            SteamBlock(title: String(localized: "Performance Overlay (In game, ⌥⌘P opens quick settings for these controls)")) {
                SteamRow(.dropdown(nil, String(localized: "Off")),
                         note: String(localized: "Bridgeplay's overlay in the top-left corner while you play. FPS shows the frame rate alone, Summary adds frame time, CPU, GPU, memory and battery in one row, and Detailed a panel with a frame-time graph. Apple Metal HUD shows Apple's own overlay instead. Off by default. While a game runs, Option-Command-P opens Bridgeplay's quick settings on the right of the game: the overlay, the frame rate limit and the scaling filter change at once and are saved for that game. Use the arrow keys or click, and Esc to close."))
            }

            SteamBlock(title: String(localized: "Frame Rate Limit (Paced to the display. Its refresh rate stays as it is)")) {
                SteamRow(.slider("60 FPS", 1, true),
                         note: String(localized: "A slider in whole frames per second, from 15 up to your display's refresh rate, as on Steam Deck. The game waits for the display so frames land evenly: smoother pacing and less battery drain. On a game's own display a higher value counts as its refresh rate, and the display's own rate is never changed."))
                SteamRow(.toggle(String(localized: "Enable frame limit"), false),
                         note: String(localized: "Off by default, so there is no limit. Switch it on to apply the slider's value; switched off again, the slider keeps it."))
            }

            SteamBlock(title: String(localized: "Scaling Filter (When the game draws fewer pixels than the screen, as with High Resolution off)")) {
                SteamRow(.dropdown(nil, String(localized: "Automatic (Wine keeps pixels sharp with High Resolution off)")),
                         note: String(localized: "How the game's frames are scaled up to your screen. Automatic keeps what happens today: Wine doubles each pixel sharply with High Resolution off, and Mac games are smoothed. Linear smooths, Nearest keeps every pixel sharp, which suits pixel art, and Integer is sharp only at an exact 2x or 3x. MetalFX upscaling, when on, runs first."))
            }

            SteamBlock(title: String(localized: "MetalFX Upscaling (Samples from the resolution the game is set to)")) {
                SteamRow(.dropdown(nil, String(localized: "Off")),
                         note: String(localized: "Shown with Automatic or DXMT. Renders below your display's resolution and scales up with MetalFX: 1.5×, 1.72×, 2× or 3×. Off keeps the resolution set in the game."))
            }

            SteamBlock(title: String(localized: "Frame Generation (Experimental. Adds input lag)")) {
                SteamRow(.dropdown(String(localized: "Mode"), "2x"),
                         note: String(localized: "Adds generated frames between the game's own: 2x, 3x, or Adaptive, which fills up to your display's refresh rate. Smoother motion, a little more input lag. Works with any game, native Mac games included."))
                SteamRow(.dropdown(String(localized: "Quality"), String(localized: "Balanced")),
                         note: String(localized: "How finely motion is tracked between frames. Performance is the lightest, Quality the most precise, Balanced in between."))
                SteamRow(.check(String(localized: "Protect UI (keeps static HUD and menus sharp)"), true),
                         note: String(localized: "Takes what did not move, like a HUD or a menu, straight from the real frame instead of warping it."))
                SteamRow(.check(String(localized: "Fast-motion fallback (skips frames that would smear)"), true),
                         note: String(localized: "When motion is too fast to track, shows the nearest real frame instead of a smeared one."))
                SteamRow(.dropdown(String(localized: "Engine"), String(localized: "Built-in optical flow")),
                         note: String(localized: "Built-in optical flow follows the mode above. MetalFX uses Apple's frame interpolation and makes one frame per pair."))
            }

            SteamBlock(title: String(localized: "Controllers")) {
                SteamRow(.check(String(localized: "Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)"), true),
                         note: String(localized: "On by default. Mac Steam has no virtual gamepad for Windows games, so games read the pad themselves. Turn it off only to use Steam Input's button remapping."))
                SteamRow(.check(String(localized: "Disable hidraw"), false),
                         note: String(localized: "Hides raw HID devices from the game, so pads only show up through SDL. Try it if a game sees one controller twice or ignores yours."))
            }

            SteamBlock(title: String(localized: "Native Mac games")) {
                SteamRow(.dropdown(String(localized: "Controller layer"), String(localized: "Automatic")),
                         note: String(localized: "Only on native Mac games, next to the Performance Overlay and Frame Generation. Raw HID suits Unity, SDL and Unreal games, GameController uses Apple's framework, and Off leaves controllers alone."))
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Good to know")
                .font(BP.sans(20, .semibold))
                .tracking(-0.5)
            VStack(spacing: 0) {
                ForEach(Array(Self.tips.enumerated()), id: \.offset) { index, tip in
                    if index > 0 { Rectangle().fill(BP.line).frame(height: 1) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.title).font(BP.sans(14, .semibold)).tracking(-0.2)
                        Text(tip.detail).font(BP.sans(13)).foregroundStyle(BP.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(BP.raise, in: RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        }
    }

    static let tips: [(title: String, detail: String)] = [
        (String(localized: "The first launch takes longer"),
         String(localized: "Bridgeplay sets the game up and the game prepares its graphics, which can show a black screen for a few minutes. Later launches are quick.")),
        (String(localized: "Controllers"),
         String(localized: "DualSense, Xbox, GameSir and other pads work without a mapping screen. The first time a game uses one, allow Steam in Input Monitoring.")),
        (String(localized: "Vulkan in a game's own settings"),
         String(localized: "Games that offer Vulkan as a rendering option run it through MoltenVK, without DLSS. Prefer DirectX 11 or 12.")),
        (String(localized: "Games with kernel anti-cheat"),
         String(localized: "Do not run. Their anti-cheat needs a Windows driver.")),
    ]
}

// MARK: - Steam's look

private enum Steam {
    static let window = Color(hex: 0x1B1E24)
    static let sidebar = Color(hex: 0x2A2D33)
    static let sidebarSelected = Color(hex: 0x3D4048)
    static let row = Color(hex: 0x2A2E37)
    static let control = Color(hex: 0x353A44)
    static let text = Color(hex: 0xDCDEDF)
    static let dim = Color(hex: 0x8B929A)
    static let blue = Color(hex: 0x1A9FFF)
    static let library = Color(hex: 0x171D25)
    static let menu = Color(hex: 0x3D4450)
    static let playTop = Color(hex: 0x75B022)
    static let playBottom = Color(hex: 0x588A1B)

    static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size, weight: weight) }
}

private struct GuideStep<Drawing: View>: View {
    let number: Int
    let text: String
    @ViewBuilder let drawing: Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            drawing
                .frame(height: 270)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.lineStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(number)")
                    .font(BP.sans(12, .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(BP.iridescentDiagonal, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(text)
                    .font(BP.sans(13))
                    .foregroundStyle(BP.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The library list with the game's context menu open on Properties….
private struct SteamLibraryDrawing: View {
    let entries: [LibraryEntry]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x1F2733), Steam.library], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "—  FAVORITES (\(entries.count)/\(max(entries.count, 25)))")
                    .font(Steam.font(10, .semibold))
                    .tracking(1)
                    .foregroundStyle(Color(hex: 0x8F98A0))
                    .padding(.bottom, 6)
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 8) {
                        Group {
                            if let icon = entry.icon {
                                Image(nsImage: icon).resizable().interpolation(.high)
                            } else {
                                Color.white.opacity(0.12)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(verbatim: entry.name)
                            .font(Steam.font(12, .regular))
                            .foregroundStyle(Steam.text)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(width: 190, alignment: .leading)
                    .background(index == 1 ? Color(hex: 0x2B3443) : .clear)
                    .overlay(index == 1 ? Rectangle().strokeBorder(Color(hex: 0x4C6B8A), lineWidth: 1) : nil)
                }
            }
            .padding(14)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text(verbatim: "PLAY").font(Steam.font(12, .medium)).tracking(1.5)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(LinearGradient(colors: [Steam.playTop, Steam.playBottom], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 2))
                .padding(4)
                menuItem(String(localized: "Remove from Favorites"))
                menuItem(String(localized: "Add to"), chevron: true)
                menuItem(String(localized: "Manage"), chevron: true)
                menuItem(String(localized: "Properties…"), selected: true)
            }
            .frame(width: 176)
            .background(Steam.menu)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
            .offset(x: 128, y: 66)
        }
    }

    private func menuItem(_ title: String, chevron: Bool = false, selected: Bool = false) -> some View {
        HStack {
            Text(title).font(Steam.font(12, .regular))
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundStyle(selected ? Steam.menu : Steam.text)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(selected ? Color(hex: 0xDCDEDF) : .clear)
    }
}

// The Properties window on the Bridgeplay tab, as Steam draws it.
private struct SteamPropertiesDrawing: View {
    let game: String

    private let tabs: [LocalizedStringKey] = ["General", "Bridgeplay", "Updates", "Installed Files",
                                              "Game Versions & Betas", "Controller", "Game Recording",
                                              "Privacy", "Customization"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 7, height: 7)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 7, height: 7)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 7, height: 7)
                }
                .padding(.bottom, 12)
                Text(verbatim: game.uppercased())
                    .font(Steam.font(13, .bold))
                    .foregroundStyle(Steam.blue)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Text(tab)
                    .font(Steam.font(10.5, .regular))
                    .foregroundStyle(index == 1 ? Color.white : Steam.dim)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
                    .background(index == 1 ? Steam.sidebarSelected : .clear)
                    .padding(.horizontal, -10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .frame(width: 130)
            .background(Steam.sidebar)

            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: "Bridgeplay").font(Steam.font(15, .bold)).foregroundStyle(.white)
                Text(verbatim: "Steam Play").font(Steam.font(11, .semibold)).foregroundStyle(.white).padding(.top, 2)
                HStack {
                    Text("Select compatibility tool").font(Steam.font(9.5, .regular)).foregroundStyle(Steam.text)
                    Spacer()
                    mini("Default (WineCX 11.17…")
                }
                .padding(7).background(Steam.row)
                Text("Graphics").font(Steam.font(11, .semibold)).foregroundStyle(.white).padding(.top, 4)
                mini(String(localized: "Automatic"), wide: true)
                ForEach(["DLSS", "MSync", String(localized: "High Resolution")], id: \.self) { label in
                    HStack(spacing: 7) {
                        checkbox(true)
                        Text(verbatim: label).font(Steam.font(9.5, .regular)).foregroundStyle(Steam.text)
                        Spacer()
                    }
                    .padding(5).background(Steam.row)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Steam.window)
        }
    }

    private func mini(_ value: String, wide: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: value).font(Steam.font(9, .regular)).lineLimit(1)
            if wide { Spacer() }
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(Steam.blue)
        }
        .foregroundStyle(Steam.text)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Steam.control)
    }

    private func checkbox(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x1F2229)).frame(width: 13, height: 13)
            .overlay(on ? Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Steam.blue) : nil)
    }
}

// One block of the Bridgeplay tab at Steam's size, each control followed by what it does.
private struct SteamBlock<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(Steam.font(16, .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) { rows }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Steam.window, in: RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
    }
}

private struct SteamRow: View {
    enum Control {
        case select(String, String)
        case toggle(String, Bool)
        case dropdown(String?, String)
        case check(String, Bool)
        // Steam's slider: its value, where it sits on the track (0 to 1), and whether it is dimmed
        case slider(String, Double, Bool)
    }

    let control: Control
    let note: String

    init(_ control: Control, note: String) {
        self.control = control
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rendered
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(BP.iridescent).frame(width: 2)
                Text(note)
                    .font(BP.sans(12.5))
                    .foregroundStyle(BP.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var rendered: some View {
        switch control {
        case .select(let label, let value):
            HStack {
                Text(verbatim: label).font(Steam.font(13, .regular)).foregroundStyle(Steam.text)
                Spacer()
                dropdownBox(value).frame(width: 260)
            }
            .padding(.horizontal, 14).frame(height: 46).background(Steam.row)
        case .toggle(let label, let on):
            HStack {
                Text(verbatim: label).font(Steam.font(13, .regular)).foregroundStyle(Steam.text)
                Spacer()
                Capsule().fill(on ? Steam.blue : Color(hex: 0x3D4048)).frame(width: 38, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 18, height: 18).padding(1) }
            }
            .padding(.horizontal, 14).frame(height: 46).background(Steam.row)
        case .dropdown(let caption, let value):
            VStack(alignment: .leading, spacing: 6) {
                if let caption {
                    Text(verbatim: caption.uppercased()).font(Steam.font(11, .regular)).foregroundStyle(Steam.dim)
                }
                dropdownBox(value)
            }
        case .check(let label, let on):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x1F2229)).frame(width: 20, height: 20)
                    .overlay(on ? Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Steam.blue) : nil)
                Text(verbatim: label).font(Steam.font(13, .regular)).foregroundStyle(Steam.text)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 38).background(Steam.row)
        case .slider(let value, let at, let dimmed):
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Steam.control).frame(height: 6)
                        Capsule().fill(Steam.blue).frame(width: box.size.width * at, height: 6)
                        Circle().fill(.white).frame(width: 16, height: 16)
                            .offset(x: box.size.width * at - 8)
                    }
                    .frame(height: 16)
                }
                .frame(height: 16)
                Text(verbatim: value).font(Steam.font(12, .regular)).foregroundStyle(Steam.dim)
            }
            .opacity(dimmed ? 0.45 : 1)
        }
    }

    private func dropdownBox(_ value: String) -> some View {
        HStack {
            Text(verbatim: value).font(Steam.font(13, .regular)).foregroundStyle(Steam.text).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Steam.blue)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Steam.control)
    }
}

// MARK: - The player's own games

struct LibraryEntry {
    let name: String
    let icon: NSImage?

    static let samples = ["007 First Light", "Deadlock", "Marvel's Spider-Man 2", "Ravenswatch",
                          "Resident Evil Requiem", "TEKKEN 8"]
        .map { LibraryEntry(name: $0, icon: nil) }

    // Installed games that have run under a compatibility tool, by name, with the small icon
    // Steam keeps at appcache/librarycache/<appid>/<hash>.jpg.
    nonisolated static func local(limit: Int) -> [LibraryEntry] {
        let fm = FileManager.default
        let cache = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
        var found: [LibraryEntry] = []
        for library in PrefixStore.libraries() {
            let steamapps = library.steamapps
            let names = (try? fm.contentsOfDirectory(atPath: steamapps.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                let id = String(name.dropFirst("appmanifest_".count).dropLast(".acf".count))
                guard fm.fileExists(atPath: steamapps.appending(path: "compatdata/\(id)").path(percentEncoded: false)),
                      let text = try? String(contentsOf: steamapps.appending(path: name), encoding: .utf8),
                      let title = GameCovers.title(inManifest: text) else { continue }
                let folder = cache.appending(path: id)
                let icon = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .first { $0.pathExtension.lowercased() == "jpg" }
                    .flatMap { NSImage(contentsOf: $0) }
                found.append(LibraryEntry(name: title, icon: icon))
            }
        }
        return Array(found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { $0.icon != nil }.prefix(limit))
    }
}
