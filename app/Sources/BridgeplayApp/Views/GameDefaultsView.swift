// 'Game Defaults' view: the settings every game gets unless it has its own, see GameDefaults
import AppKit
import BridgeplayUI
import SwiftUI

struct GameDefaultsView: View {
    @Environment(SystemStatus.self) private var status
    // gamefixes/default.conf and gamefixes-default/default.conf, read when the page opens;
    // every change writes the user's file straight away.
    @State private var user = ""
    @State private var shipped = ""
    @State private var dllDraft = ""
    @State private var overrides: [GameDefaults.Override] = []
    @State private var defaultTool: String?
    @State private var failure: String?
    @State private var confirmsReset = false
    @State private var clearing: GameDefaults.Override?
    // The frame rate limit while its slider is dragged; written when the drag ends
    @State private var limitDraft: Double?
    @State private var showsAdvanced = false
    // Steam's small library icon per app id, for the per-game list
    @State private var icons: [String: NSImage] = [:]

    private var hasD3DMetal: Bool { status.snapshot?.gptkSource != nil }

    var body: some View {
        Form {
            Section {
                choiceRow(.backend)
                toggleRow(.metalFX)
                toggleRow(.highResolution)
            } header: {
                header("Graphics")
            } footer: {
                footer("Changes apply the next time a game starts. Per-game settings in Steam win.")
            }
            Section {
                overlayRow
                frameLimitRow
                choiceRow(.frameGen)
                if frameGenOn {
                    choiceRow(.frameGenQuality)
                }
            } header: {
                header("Performance")
            }
            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    toggleRow(.vsync)
                    choiceRow(.scalingFilter)
                    if frameGenOn {
                        toggleRow(.frameGenUI)
                        toggleRow(.frameGenFallback)
                        choiceRow(.frameGenEngine)
                    }
                    toggleRow(.dlssFrameGen)
                    toggleRow(.nvapi)
                    choiceRow(.msync)
                    toggleRow(.advertiseAVX)
                    dllRow
                    ForEach(Array(GameDefaults.problems(in: user).enumerated()), id: \.offset) { _, problem in
                        StatusRow(title: Self.title(problem.setting),
                                  value: String(localized: "Ignored: \(problem.reason)"), tone: .warning)
                    }
                    row(String(localized: "Default Compatibility Tool"), "", changed: false, reset: {}) {
                        Text(defaultTool ?? String(localized: "Not set"))
                            .foregroundStyle(BP.fg2)
                    }
                } label: {
                    Text("Advanced")
                        .font(BP.sans(13, .semibold))
                        .tracking(-0.1)
                }
            }
            if !overrides.isEmpty {
                overridesSection
            }
            if let failure {
                Section {
                    StatusRow(title: String(localized: "Something went wrong"), value: failure, tone: .bad,
                              menu: ErrorReport.actions(failure, in: "Game Defaults"))
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            DefaultsHero(customized: GameDefaults.resettingAll(in: user) != user, chips: heroChips)
        }
        // One readable column: on a wide window the controls stay near their labels.
        .frame(maxWidth: 680, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Game Defaults")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset All") { confirmsReset = true }
                    .disabled(GameDefaults.resettingAll(in: user) == user)
            }
        }
        .confirmationDialog(String(localized: "Reset every game default?"), isPresented: $confirmsReset,
                            titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every setting on this page goes back to Bridgeplay's default.")
        }
        .confirmationDialog(String(localized: "Use the defaults for this game?"),
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
                            titleVisibility: .visible, presenting: clearing) { item in
            Button("Use Defaults", role: .destructive) { clear(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Bridgeplay removes these settings from the game's conf and keeps a copy in its backups folder.")
        }
        .task { await load() }
    }

    // What every game gets right now, in a few words: the backend and whatever is switched on.
    private var heroChips: [String] {
        var chips = [Self.optionLabel(resolved(.backend).value ?? "", for: .backend)]
        if chips[0].isEmpty { chips[0] = hasD3DMetal ? "D3DMetal" : "DXMT" }
        if resolved(.highResolution).value == "1" { chips.append(Self.title(.highResolution)) }
        if overlayChoice != "0" { chips.append(Self.optionLabel(overlayChoice, for: .perfOverlay)) }
        if !limitOff { chips.append("\(limitValue) FPS") }
        if frameGenOn { chips.append(Self.title(.frameGen)) }
        return chips
    }

    // MARK: Rows
    //
    // Each row is a title, at most one short line under it, and its control. A setting you
    // changed shows a small reset arrow; Bridgeplay's own defaults show nothing.

    private func resolved(_ setting: GameDefaults.Setting) -> GameDefaults.Resolved {
        GameDefaults.resolve(setting, user: user, shipped: shipped)
    }

    private var frameGenOn: Bool { (resolved(.frameGen).value ?? "0") != "0" }

    private func caption(_ setting: GameDefaults.Setting) -> String {
        let needsD3DMetal = setting.requirement == .d3dmetal || (setting == .backend && resolved(setting).value == "d3dmetal")
        if needsD3DMetal, !hasD3DMetal {
            return String(localized: "Needs the Game Porting Toolkit. Without it, games use DXMT.")
        }
        return Self.summary(setting)
    }

    private func resetActions(_ setting: GameDefaults.Setting) -> [StatusAction] {
        guard resolved(setting).source == .user else { return [] }
        return [StatusAction(label: String(localized: "Reset to Bridgeplay's Default")) { save(setting, nil) }]
    }

    private func row(_ title: String, _ caption: String, changed: Bool,
                     reset: @escaping () -> Void, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 8) {
            label(title, caption)
            Spacer(minLength: 12)
            if changed { resetButton(reset) }
            control()
        }
        .contextMenu {
            if changed {
                Button(String(localized: "Reset to Bridgeplay's Default"), action: reset)
            }
        }
    }

    private func resetButton(_ reset: @escaping () -> Void) -> some View {
        ResetButton(action: reset)
    }

    private func row(_ setting: GameDefaults.Setting, @ViewBuilder control: () -> some View) -> some View {
        row(Self.title(setting), caption(setting), changed: resolved(setting).source == .user,
            reset: { save(setting, nil) }, control: control)
    }

    private func toggleRow(_ setting: GameDefaults.Setting) -> some View {
        row(setting) {
            Toggle(Self.title(setting), isOn: Binding(get: { resolved(setting).value == "1" },
                                                      set: { save(setting, $0 ? "1" : "0") }))
                .toggleStyle(.brandSwitch)
                .labelsHidden()
        }
    }

    // MARK: Frame rate limit
    //
    // One row: a switch that applies the limit, and under it, while on, a slider in whole
    // frames per second from 15 to the fastest display's rate. Off keeps the slider's value.
    // overlay-shim holds the limit to the display a game is on.

    private var maxFPS: Int {
        min(360, max(GameDefaults.minFrameLimit, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60))
    }

    private var limitValue: Int {
        GameDefaults.frameLimitValue(resolved(.frameLimit).value, maxFPS: maxFPS) ?? maxFPS
    }

    private var limitOff: Bool {
        GameDefaults.frameLimitIsOff(limit: resolved(.frameLimit).value, off: resolved(.frameLimitOff).value)
    }

    private var frameLimitRow: some View {
        let shown = Int(limitDraft ?? Double(limitValue))
        let changed = resolved(.frameLimit).source == .user || resolved(.frameLimitOff).source == .user
        return VStack(alignment: .leading, spacing: 8) {
            row(Self.title(.frameLimit), "", changed: changed, reset: {
                save(.frameLimit, nil)
                save(.frameLimitOff, nil)
            }) {
                if !limitOff {
                    Text(verbatim: "\(shown) FPS")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle(Self.title(.frameLimitOff), isOn: Binding(get: { !limitOff }, set: { setLimitOff(!$0) }))
                    .toggleStyle(.brandSwitch)
                    .labelsHidden()
            }
            if !limitOff {
                HStack(spacing: 10) {
                    Text(verbatim: "\(GameDefaults.minFrameLimit)")
                    BrandSlider(value: Binding(get: { limitDraft ?? Double(limitValue) },
                                               set: { limitDraft = $0.rounded() }),
                                range: Double(GameDefaults.minFrameLimit)...Double(maxFPS),
                                label: Self.title(.frameLimit)) {
                        guard let draft = limitDraft else { return }
                        limitDraft = nil
                        save(.frameLimit, String(Int(draft)))
                    }
                    Text(verbatim: "\(maxFPS)")
                }
                .font(BP.sans(11))
                .monospacedDigit()
                .foregroundStyle(BP.fg3)
            }
        }
    }

    // On with no value set takes the slider's, the display's rate.
    private func setLimitOff(_ off: Bool) {
        if !off, GameDefaults.frameLimitValue(resolved(.frameLimit).value, maxFPS: maxFPS) == nil {
            save(.frameLimit, String(limitValue))
        }
        save(.frameLimitOff, off ? "1" : "0")
    }

    private func label(_ title: String, _ caption: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BP.sans(13, .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(BP.fg)
                if !caption.isEmpty {
                    Text(caption)
                        .font(BP.sans(12))
                        .foregroundStyle(BP.fg2)
                }
            }
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(BP.sans(12, .semibold))
            .tracking(0.2)
            .foregroundStyle(BP.fg2)
    }

    private func footer(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(BP.sans(11))
            .foregroundStyle(BP.fg3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A neutral menu: the value in near-white, not the accent.
    private func menu<Content: View>(_ title: String, selection: Binding<String>,
                                     @ViewBuilder content: () -> Content) -> some View {
        Picker(title, selection: selection, content: content)
            .labelsHidden()
            .fixedSize()
            .tint(BP.fg)
            // The menu button draws ~10pt of empty bezel before its text; pull it in so the
            // reset arrow sits as close to a menu as it does to a switch or a value.
            .padding(.leading, -10)
    }

    // Bridgeplay's performance overlay and Apple's Metal HUD are one choice, as in Steam
    // Properties › Bridgeplay; overlay-shim shows the Metal HUD when a conf turns on both.
    private var overlayChoice: String {
        resolved(.metalHUD).value == "1" ? "hud" : (resolved(.perfOverlay).value ?? "0")
    }

    private var overlayRow: some View {
        let changed = resolved(.perfOverlay).source == .user || resolved(.metalHUD).source == .user
        return row(Self.title(.perfOverlay), "", changed: changed, reset: {
            save(.perfOverlay, nil)
            save(.metalHUD, nil)
        }) {
            menu(Self.title(.perfOverlay), selection: Binding(get: { overlayChoice }, set: saveOverlay)) {
                ForEach(Self.options(.perfOverlay) + ["hud"], id: \.self) { option in
                    Text(Self.optionLabel(option, for: .perfOverlay)).tag(option)
                }
            }
        }
    }

    private func saveOverlay(_ choice: String) {
        let hud = choice == "hud"
        save(.perfOverlay, hud ? "0" : choice)
        save(.metalHUD, hud ? "1" : "0")
    }

    private func choiceRow(_ setting: GameDefaults.Setting) -> some View {
        row(setting) {
            menu(Self.title(setting), selection: Binding(
                get: { resolved(setting).value ?? "" },
                set: { save(setting, $0.isEmpty ? nil : $0) }
            )) {
                if setting.fallback == nil {
                    Text("Automatic").tag("")
                }
                ForEach(choices(setting), id: \.self) { option in
                    Text(Self.optionLabel(option, for: setting)).tag(option)
                }
            }
        }
    }

    // The page's options, plus a valid value the conf sets that the page does not list
    // (FRAMEGEN=1 written by hand), so the picker shows what games actually get.
    private func choices(_ setting: GameDefaults.Setting) -> [String] {
        let options = Self.options(setting)
        guard let current = resolved(setting).value, !options.contains(current) else { return options }
        return options + [current]
    }

    private var dllRow: some View {
        row(.dllOverrides) {
            TextField(Self.title(.dllOverrides), text: $dllDraft, prompt: Text(verbatim: "dinput8=n,b"))
                .labelsHidden()
                .frame(maxWidth: 200)
                .onSubmit(saveDLLOverrides)
            Button("Apply", action: saveDLLOverrides)
                .disabled(dllDraft == (resolved(.dllOverrides).value ?? ""))
        }
    }

    private var overridesSection: some View {
        Section {
            ForEach(overrides) { item in
                HStack(alignment: .center, spacing: 12) {
                    gameIcon(item.appID)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? String(localized: "App \(item.appID)"))
                            .font(BP.sans(13, .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(BP.fg)
                        Text(item.settings.map(Self.overrideTitle).joined(separator: ", "))
                            .font(BP.sans(12))
                            .foregroundStyle(BP.fg2)
                            .help(Self.place(item.place))
                    }
                    Spacer(minLength: 12)
                    Button("Open in Steam") { Self.openInSteam(item.appID) }
                        .controlSize(.small)
                }
                .contextMenu {
                    if item.place == .conf {
                        Button(String(localized: "Use Defaults…")) { clearing = item }
                    }
                }
            }
        } header: {
            header("Games with Their Own Settings")
        } footer: {
            footer("Games with launch options reset in their Steam Properties › Bridgeplay.")
        }
    }

    private func gameIcon(_ appID: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Group {
            if let image = icons[appID] {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                BP.raise2.overlay(Image(systemName: "gamecontroller").font(.system(size: 13)).foregroundStyle(BP.fg3))
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(shape)
        .overlay(shape.strokeBorder(BP.line, lineWidth: 1))
        .accessibilityHidden(true)
    }

    // Steam's small icon at appcache/librarycache/<appid>/<hash>.jpg, as the Guide's list reads it.
    nonisolated private static func steamIcons(for ids: [String]) -> [String: NSImage] {
        let fm = FileManager.default
        let cache = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
        var found: [String: NSImage] = [:]
        for id in Set(ids) {
            let file = ((try? fm.contentsOfDirectory(at: cache.appending(path: id), includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension.lowercased() == "jpg" }
            if let file, let image = NSImage(contentsOf: file) { found[id] = image }
        }
        return found
    }

    // MARK: Actions

    private func load() async {
        user = GameDefaults.read(GameDefaults.file)
        shipped = GameDefaults.read(GameDefaults.shippedFile)
        dllDraft = resolved(.dllOverrides).value ?? ""
        defaultTool = SteamDefaultTool.current(in: GameDefaults.read(SteamDefaultTool.config))?.name
        overrides = await Task.detached(priority: .utility) { GameDefaults.overrides() }.value
        let ids = overrides.map(\.appID)
        icons = await Task.detached(priority: .utility) { Self.steamIcons(for: ids) }.value
    }

    private func save(_ setting: GameDefaults.Setting, _ value: String?) {
        do {
            try GameDefaults.set(setting, to: value)
            user = GameDefaults.read(GameDefaults.file)
            failure = nil
        } catch {
            failure = String(localized: "Bridgeplay could not save this setting. \(error.localizedDescription)")
        }
    }

    private func saveDLLOverrides() {
        let text = dllDraft.trimmingCharacters(in: .whitespaces)
        save(.dllOverrides, text.isEmpty ? nil : text)
        dllDraft = resolved(.dllOverrides).value ?? ""
    }

    private func resetAll() {
        do {
            try GameDefaults.resetAll()
            user = GameDefaults.read(GameDefaults.file)
            dllDraft = resolved(.dllOverrides).value ?? ""
            failure = nil
        } catch {
            failure = String(localized: "Bridgeplay could not save this setting. \(error.localizedDescription)")
        }
    }

    private func clear(_ item: GameDefaults.Override) {
        do {
            try GameDefaults.clearConf(appID: item.appID)
            overrides.removeAll { $0.id == item.id }
            failure = nil
        } catch {
            failure = String(localized: "Bridgeplay could not save this setting. \(error.localizedDescription)")
        }
    }

    private static func openInSteam(_ appID: String) {
        if let url = URL(string: "steam://nav/games/details/\(appID)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Names

    static func title(_ setting: GameDefaults.Setting) -> String {
        switch setting {
        case .backend: String(localized: "Graphics Backend")
        case .highResolution: String(localized: "High Resolution")
        case .metalHUD: String(localized: "Metal HUD")
        case .perfOverlay: String(localized: "Performance Overlay")
        case .nvapi: String(localized: "Report an NVIDIA GPU")
        case .metalFX: "DLSS"
        case .dlssFrameGen: String(localized: "DLSS Frame Generation")
        case .advertiseAVX: String(localized: "Advertise AVX2 to Rosetta")
        case .msync: "MSync"
        case .vsync: String(localized: "Force VSync")
        case .frameLimit: String(localized: "Frame Rate Limit")
        case .frameLimitOff: String(localized: "Enable Frame Limit")
        case .scalingFilter: String(localized: "Scaling Filter")
        case .frameGen: String(localized: "Frame Generation")
        case .frameGenQuality: String(localized: "Quality")
        case .frameGenUI: String(localized: "Protect UI")
        case .frameGenFallback: String(localized: "Fast-Motion Fallback")
        case .frameGenEngine: String(localized: "Frame Generation Engine")
        case .dllOverrides: String(localized: "DLL Overrides")
        }
    }

    // Listed beside other settings, "Quality" alone reads as the value.
    static func overrideTitle(_ setting: GameDefaults.Setting) -> String {
        switch setting {
        case .frameGenQuality: String(localized: "Frame Generation Quality")
        default: title(setting)
        }
    }

    static func summary(_ setting: GameDefaults.Setting) -> String {
        switch setting {
        case .highResolution: String(localized: "Sharper, but slower.")
        case .metalFX: String(localized: "Uses MetalFX when a game turns DLSS on.")
        case .nvapi: String(localized: "Lets games offer DLSS. Some take NVIDIA-only paths.")
        case .dlssFrameGen: String(localized: "Experimental. Can freeze some Macs.")
        case .advertiseAVX: String(localized: "Many games need it.")
        case .vsync: String(localized: "Even when a game turns it off.")
        case .scalingFilter: String(localized: "How games scale up when High Resolution is off.")
        case .frameGen: String(localized: "Experimental. Adds input lag.")
        case .frameGenUI: String(localized: "Keeps HUD and menus sharp.")
        case .frameGenFallback: String(localized: "Skips frames that would smear.")
        case .dllOverrides: String(localized: "Wine syntax.")
        case .backend, .metalHUD, .perfOverlay, .msync, .frameLimit, .frameLimitOff,
             .frameGenQuality, .frameGenEngine: ""
        }
    }

    static func options(_ setting: GameDefaults.Setting) -> [String] {
        if case .choice(let values) = setting.kind { return values }
        return []
    }

    static func optionLabel(_ option: String, for setting: GameDefaults.Setting) -> String {
        switch (setting, option) {
        case (.backend, "d3dmetal"): "D3DMetal"
        case (.backend, "wined3d"): "WineD3D"
        case (.backend, _): option.uppercased()
        case (.msync, "1"): String(localized: "On")
        case (.msync, _), (.frameGen, "0"): String(localized: "Off")
        case (.frameGen, "adaptive"): String(localized: "Adaptive")
        case (.frameGen, _): "\(option)x"
        case (.frameGenQuality, "performance"): String(localized: "Performance")
        case (.frameGenQuality, "quality"): String(localized: "Quality")
        case (.frameGenQuality, _): String(localized: "Balanced")
        case (.frameGenEngine, "metalfx"): "MetalFX"
        case (.frameGenEngine, _): String(localized: "Built-in optical flow")
        case (.perfOverlay, "fps"): "FPS"
        case (.perfOverlay, "summary"): String(localized: "Summary")
        case (.perfOverlay, "detailed"): String(localized: "Detailed")
        case (.perfOverlay, "hud"): String(localized: "Metal HUD")
        case (.perfOverlay, _): String(localized: "Off")
        case (.scalingFilter, "nearest"): String(localized: "Nearest")
        case (.scalingFilter, "integer"): String(localized: "Integer")
        case (.scalingFilter, "linear"): String(localized: "Linear")
        case (.scalingFilter, _): String(localized: "Automatic")
        default: option
        }
    }

    static func place(_ place: GameDefaults.Override.Place) -> String {
        switch place {
        case .conf: String(localized: "Own conf")
        case .launchOptions(let account): String(localized: "Launch options, account \(account)")
        }
    }
}


// The top of Game Defaults, in the Status page's frame: the aurora behind what every game
// starts with, and the settings in force as chips.
private struct DefaultsHero: View {
    let customized: Bool
    let chips: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Ambient motion stops while the window is in the background
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack(alignment: .leading) {
            // Only the aurora redraws per frame; the grid and the text stay put
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
                let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate * 0.6
                Aurora(t: t, lean: customized ? 0.65 : 0.35)
            }
            GridLines()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Game Defaults")
                        .font(BP.sans(24, .semibold))
                        .tracking(-0.7)
                        .foregroundStyle(BP.fg)
                    Text("Every game starts with these, unless it has its own settings in Steam.")
                        .font(BP.sans(13))
                        .foregroundStyle(BP.fg2)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            HeroChip(text: chip)
                        }
                    }
                }
                .padding(.horizontal, 24)
        }
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(BP.bg)
    }
}

// A changed setting's way back: a small arrow, quiet until the pointer is on it.
private struct ResetButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? BP.fg : BP.fg3)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { hovered = $0 }
        .help(String(localized: "Reset to Bridgeplay's Default"))
    }
}

// A value along a range in the brand's progress style: a 4 pt raise-2 track, the gradient up
// to the value and a white knob. Steps by one with the arrow keys; VoiceOver gets a slider.
private struct BrandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let onCommit: () -> Void

    @State private var dragging = false
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - knob, 1)
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
            let x = CGFloat(min(max(fraction, 0), 1)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(BP.raise2).frame(height: 4)
                Capsule().fill(BP.iridescent).frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .scaleEffect(dragging ? 1.1 : 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    let f = min(max((drag.location.x - knob / 2) / width, 0), 1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in
                    dragging = false
                    onCommit()
                })
            .animation(.easeOut(duration: 0.18), value: dragging)
        }
        .frame(height: 20)
        .focusable()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(label) } onEditingChanged: { if !$0 { onCommit() } }
        }
    }

    private func step(_ by: Double) -> KeyPress.Result {
        value = min(max(value.rounded() + by, range.lowerBound), range.upperBound)
        onCommit()
        return .handled
    }
}
