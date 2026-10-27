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

    private var hasD3DMetal: Bool { status.snapshot?.gptkSource != nil }

    var body: some View {
        Form {
            Section {
                choiceRow(.backend)
                toggleRow(.metalFX)
                toggleRow(.nvapi)
                choiceRow(.msync)
                toggleRow(.advertiseAVX)
            } header: {
                Text("Graphics")
            } footer: {
                Text("Changes apply the next time a game starts. A game's own settings in Steam Properties › Bridgeplay win over these.")
            }
            Section {
                toggleRow(.highResolution)
                toggleRow(.metalHUD)
                toggleRow(.vsync)
            } header: {
                Text("Display")
            }
            Section {
                choiceRow(.frameGen)
                if resolved(.frameGen).value != "0" {
                    choiceRow(.frameGenQuality)
                    toggleRow(.frameGenUI)
                    toggleRow(.frameGenFallback)
                    choiceRow(.frameGenEngine)
                }
            } header: {
                Text("Frame Generation")
            } footer: {
                Text("Experimental. Adds input lag.")
            }
            Section {
                dllRow
                ForEach(Array(GameDefaults.problems(in: user).enumerated()), id: \.offset) { _, problem in
                    StatusRow(title: Self.title(problem.setting),
                              value: String(localized: "Ignored: \(problem.reason)"), tone: .warning)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Other lines in gamefixes/default.conf are kept as they are.")
            }
            Section {
                StatusRow(title: String(localized: "Default Compatibility Tool"),
                          value: defaultTool ?? String(localized: "Not set"))
            } footer: {
                Text("Steam runs every game without a tool of its own with this one. Change it in the Setup Assistant while Steam is closed.")
            }
            overridesSection
            if let failure {
                Section {
                    StatusRow(title: String(localized: "Something went wrong"), value: failure, tone: .bad,
                              menu: ErrorReport.actions(failure, in: "Game Defaults"))
                }
            }
        }
        .formStyle(.grouped)
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

    // MARK: Rows

    private func resolved(_ setting: GameDefaults.Setting) -> GameDefaults.Resolved {
        GameDefaults.resolve(setting, user: user, shipped: shipped)
    }

    private func caption(_ setting: GameDefaults.Setting) -> String {
        var parts = [Self.summary(setting)]
        switch resolved(setting).source {
        case .user: parts.append(String(localized: "Set by you."))
        case .bridgeplay: parts.append(String(localized: "Bridgeplay's default."))
        case .engine: break
        }
        let needsD3DMetal = setting.requirement == .d3dmetal || (setting == .backend && resolved(setting).value == "d3dmetal")
        if needsD3DMetal, !hasD3DMetal {
            parts.append(String(localized: "Needs the Game Porting Toolkit. Without it, games use DXMT."))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func resetActions(_ setting: GameDefaults.Setting) -> [StatusAction] {
        guard resolved(setting).source == .user else { return [] }
        return [StatusAction(label: String(localized: "Reset to Bridgeplay's Default")) { save(setting, nil) }]
    }

    private func toggleRow(_ setting: GameDefaults.Setting) -> some View {
        StatusRow(title: Self.title(setting), value: caption(setting), menu: resetActions(setting),
                  toggle: Binding(get: { resolved(setting).value == "1" }, set: { save(setting, $0 ? "1" : "0") }))
    }

    private func label(_ setting: GameDefaults.Setting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(setting))
                .font(BP.sans(13, .semibold))
                .tracking(-0.1)
            Text(caption(setting))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, StatusMetrics.textInset)
    }

    private func choiceRow(_ setting: GameDefaults.Setting) -> some View {
        HStack(alignment: .center, spacing: 0) {
            label(setting)
            Spacer(minLength: 12)
            Picker(Self.title(setting), selection: Binding(
                get: { resolved(setting).value ?? "" },
                set: { save(setting, $0.isEmpty ? nil : $0) }
            )) {
                if setting.fallback == nil {
                    Text("Automatic").tag("")
                }
                ForEach(Self.options(setting), id: \.self) { option in
                    Text(Self.optionLabel(option, for: setting)).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .contextMenu {
            ForEach(resetActions(setting), id: \.label) { action in
                Button(action.label, action: action.perform)
            }
        }
    }

    private var dllRow: some View {
        HStack(alignment: .center, spacing: 8) {
            label(.dllOverrides)
            Spacer(minLength: 12)
            TextField(Self.title(.dllOverrides), text: $dllDraft, prompt: Text(verbatim: "dinput8=n,b"))
                .labelsHidden()
                .frame(maxWidth: 220)
                .onSubmit(saveDLLOverrides)
            Button("Apply", action: saveDLLOverrides)
                .disabled(dllDraft == (resolved(.dllOverrides).value ?? ""))
        }
    }

    private var overridesSection: some View {
        Section {
            if overrides.isEmpty {
                StatusRow(title: String(localized: "None"), value: String(localized: "Every game uses these defaults."))
            }
            ForEach(overrides) { item in
                StatusRow(title: item.name ?? String(localized: "App \(item.appID)"),
                          value: item.settings.map(Self.title).joined(separator: ", "),
                          trailing: Self.place(item.place),
                          action: StatusAction(label: String(localized: "Open in Steam")) { Self.openInSteam(item.appID) },
                          menu: item.place == .conf
                              ? [StatusAction(label: String(localized: "Use Defaults…")) { clearing = item }] : [])
            }
        } header: {
            Text("Games with Their Own Settings")
        } footer: {
            Text("A game with launch options goes back to these defaults with Use Bridgeplay defaults in its Steam Properties › Bridgeplay.")
        }
    }

    // MARK: Actions

    private func load() async {
        user = GameDefaults.read(GameDefaults.file)
        shipped = GameDefaults.read(GameDefaults.shippedFile)
        dllDraft = resolved(.dllOverrides).value ?? ""
        defaultTool = SteamDefaultTool.current(in: GameDefaults.read(SteamDefaultTool.config))?.name
        overrides = await Task.detached(priority: .utility) { GameDefaults.overrides() }.value
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
        case .nvapi: String(localized: "Report an NVIDIA GPU")
        case .metalFX: String(localized: "DLSS through MetalFX")
        case .advertiseAVX: String(localized: "Advertise AVX2 to Rosetta")
        case .msync: "MSync"
        case .vsync: String(localized: "Force VSync")
        case .frameGen: String(localized: "Frame Generation")
        case .frameGenQuality: String(localized: "Quality")
        case .frameGenUI: String(localized: "Protect UI")
        case .frameGenFallback: String(localized: "Fast-Motion Fallback")
        case .frameGenEngine: String(localized: "Engine")
        case .dllOverrides: String(localized: "DLL Overrides")
        }
    }

    static func summary(_ setting: GameDefaults.Setting) -> String {
        switch setting {
        case .backend: String(localized: "Automatic picks D3DMetal when the Game Porting Toolkit is linked, and DXMT otherwise.")
        case .highResolution: String(localized: "Sharper on Retina displays, but games run slower.")
        case .metalHUD: String(localized: "Shows frame rate and GPU details in a corner while you play.")
        case .nvapi: String(localized: "Lets games offer DLSS, served by MetalFX. Some games take NVIDIA-only paths with it.")
        case .metalFX: String(localized: "Only takes effect when DLSS is switched on in the game.")
        case .advertiseAVX: String(localized: "Many games quit without it.")
        case .msync: String(localized: "Automatic follows the engine.")
        case .vsync: String(localized: "Waits for the display even when a game turns VSync off.")
        case .frameGen, .frameGenQuality, .frameGenEngine: ""
        case .frameGenUI: String(localized: "Keeps static HUD and menus sharp.")
        case .frameGenFallback: String(localized: "Skips generated frames that would smear.")
        case .dllOverrides: String(localized: "Wine syntax. A game's own conf replaces these; its launch options win per DLL.")
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
