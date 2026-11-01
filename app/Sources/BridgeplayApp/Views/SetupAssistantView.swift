import SwiftUI
import UniformTypeIdentifiers
import BridgeplayUI

// First-run Setup Assistant. Built from the Status page's own pieces (a grouped Form of
// StatusRows with StatusTone dots and StatusActions) so it reads as part of the same app.
// Each step checks first; buttons appear only for what a check could not do on its own.
struct SetupAssistantView: View {
    @Environment(SystemStatus.self) private var status
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: SetupAssistant
    // How many rows of the current step have resolved; the rest still show "Checking…".
    @State private var revealed: Int
    @State private var forward = true
    @State private var confirmingRepair = false
    private let fixedReveal: Int?
    private let onClose: (() -> Void)?

    init(model: SetupAssistant = SetupAssistant(), revealed: Int? = nil, onClose: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        _revealed = State(initialValue: revealed ?? 0)
        fixedReveal = revealed
        self.onClose = onClose
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    static let pageSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let rowSpring = Animation.spring(response: 0.32, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 0) {
            SetupArt(step: model.step, progress: finishedFraction, running: model.step == .finish && model.isWorking)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4.4) {
                        BridgeplayMark(size: 22)
                        Text(verbatim: "Bridgeplay")
                            .font(BP.display(13))
                            .foregroundStyle(BP.iridescent)
                    }
                    .padding(22)
                }
                .frame(width: 240)
                .animation(Self.pageSpring, value: model.step)
            Rectangle().fill(BP.line).frame(width: 1)
            main
        }
        .frame(width: 780, height: 580)
        .background(BP.bg)
        .foregroundStyle(BP.fg)
        .environment(\.colorScheme, .dark)
        .tint(BP.blue)
        .task(id: model.step) { await wave() }
    }

    private var finishedFraction: Double {
        switch model.step {
        case .mac, .graphics, .steam: 0
        case .finish: Double(model.tasks.filter { $0.state == .done }.count) / Double(max(model.tasks.count, 1))
        case .done: 1
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            StepBar(current: model.step)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 4)
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                        if let message = model.message {
                            SetupCard {
                                WizardRow(row: StatusRow(title: String(localized: "Something went wrong"), value: message, tone: .bad,
                                          action: StatusAction(label: ErrorReport.reportLabel) { ErrorReport.open(message, in: "Setup") }))
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .id(model.step)
                .transition(pageTransition)
            }
            .clipped()
            // Pinned above the footer, so it stays in view however long the step's content is.
            if DownloadMeter.shared.fraction != nil {
                Rectangle().fill(BP.line).frame(height: 1)
                DownloadStrip().padding(.horizontal, 28).padding(.vertical, 12)
            }
            Rectangle().fill(BP.line).frame(height: 1)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // Rows resolve one after another so the checks read as work being done, not a wall of
    // results. Reduce Motion shows them all at once.
    private func wave() async {
        if let fixedReveal { revealed = fixedReveal; return }
        guard !reduceMotion else { revealed = .max; return }
        revealed = 0
        try? await Task.sleep(for: .milliseconds(260))
        for index in 1...5 {
            withAnimation(Self.rowSpring) { revealed = index }
            try? await Task.sleep(for: .milliseconds(210))
        }
        revealed = .max
    }

    private func go(forward: Bool, _ change: () -> Void) {
        self.forward = forward
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Self.pageSpring, change)
    }

    // One row of the wave: pending rows keep their title and show a spinner in place of the
    // result, then swap in the real value and tone.
    private func checked(_ index: Int, _ row: StatusRow) -> some View {
        let pending = index >= revealed
        var shown = row
        if pending {
            shown.value = String(localized: "Checking…")
            shown.tone = .neutral
            shown.detail = nil
            shown.action = nil
            shown.secondaryAction = nil
            shown.trailing = nil
        }
        return WizardRow(row: shown, pending: pending)
            .animation(Self.rowSpring, value: pending)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .mac: macStep
        case .graphics: graphicsStep
        case .steam: steamStep
        case .finish: finishStep
        case .done: doneStep
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var macStep: some View {
        StepHeader(step: model.step, title: "Check your Mac",
                   detail: "Bridgeplay runs Windows games from your Steam library. First, a few quick checks.")
        SetupCard {
            checked(0, StatusRow(title: String(localized: "Apple silicon"),
                      value: model.appleSilicon ? SetupChecks.chipName : String(localized: "Bridgeplay doesn't run on Intel Macs."),
                      tone: model.appleSilicon ? .ok : .bad))
            SetupHairline()
            checked(1, StatusRow(title: String(localized: "macOS \(SetupChecks.minimumMacOS) or later"),
                      value: model.macOSSupported ? SetupChecks.macOSDisplay : String(localized: "\(SetupChecks.macOSDisplay). Update macOS first."),
                      tone: model.macOSSupported ? .ok : .bad))
            SetupHairline()
            checked(2, StatusRow(title: String(localized: "Free space"),
                      value: model.freeBytes.map { String(localized: "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) available, 3 GB needed") },
                      tone: model.hasSpace ? .ok : .bad))
            SetupHairline()
            checked(3, StatusRow(title: String(localized: "Rosetta 2"),
                      value: model.rosettaInstalled ? String(localized: "Installed.") : model.rosettaNote ?? String(localized: "Apple's translator for Windows games. Asks for your Mac password."),
                      tone: model.rosettaInstalled ? .ok : .warning,
                      action: model.rosettaInstalled ? nil : StatusAction(
                        label: String(localized: "Install"), isProminent: true, isEnabled: !model.isWorking
                      ) { Task { await model.installRosetta() } }))
        }
    }

    @ViewBuilder
    private var graphicsStep: some View {
        StepHeader(step: model.step, title: "Add Apple's game graphics",
                   detail: "Apple's Game Porting Toolkit (D3DMetal) runs DirectX 11 and 12 games on Metal. Bridgeplay can download it for you under Apple's non-commercial license, or add your own copy from Apple.")
        SetupCard {
            if let gptk = model.gptk {
                WizardRow(row: StatusRow(title: String(localized: "Game Porting Toolkit"),
                          value: String(localized: "Ready from \(gptk.libRoot.path(percentEncoded: false))."),
                          tone: .ok, trailing: gptk.version))
            } else {
                // Apple's files unmodified, from Bridgeplay's installer release; Steam comes along when it's missing.
                WizardRow(row: StatusRow(title: String(localized: "Download with Bridgeplay"),
                          value: DownloadMeter.shared.title ?? model.gptkProgress
                            ?? String(localized: "About 500 MB. Also installs Steam if this Mac doesn't have it yet."),
                          action: StatusAction(label: String(localized: "Download"), isProminent: true, isEnabled: !model.isWorking) {
                              Task { await model.downloadGPTK() }
                          }), symbol: "arrow.down.circle")
                SetupHairline()
                WizardRow(row: StatusRow(title: String(localized: "Or download it from Apple"),
                          value: String(localized: "Sign in, then download the latest Game Porting Toolkit .dmg."),
                          action: StatusAction(label: String(localized: "Open Apple Downloads")) {
                              NSWorkspace.shared.open(URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!)
                          }), number: 1)
                SetupHairline()
                if let image = model.gptkImages.first {
                    WizardRow(row: StatusRow(title: String(localized: "Use the one in Downloads"),
                              value: image.lastPathComponent,
                              action: StatusAction(label: String(localized: "Use This"), isEnabled: !model.isWorking) {
                                  Task { await model.importGPTK(image) }
                              }), number: 2)
                } else {
                    WizardRow(row: StatusRow(title: String(localized: "Add the disk image"),
                              value: String(localized: "Drag the .dmg onto this window, or choose it."),
                              action: StatusAction(label: String(localized: "Choose…"), isEnabled: !model.isWorking) { chooseImage() }),
                              number: 2)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isWorking, let url = urls.first(where: { $0.pathExtension.lowercased() == "dmg" }) else { return false }
            Task { await model.importGPTK(url) }
            return true
        }
        if model.gptk == nil {
            Text("Optional. If you skip it, games use DXMT, which runs DirectX 10 and 11 games only. You can add the toolkit later from Status.")
                .font(BP.sans(12))
                .foregroundStyle(BP.fg3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var steamStep: some View {
        StepHeader(step: model.step, title: "Sign in to Steam",
                   detail: "Sign in with your account in Steam. Bridgeplay continues on its own once you're in.")
        // Above the rows, so it is read before the Set Up step patches Steam.
        VStack(alignment: .leading, spacing: 6) {
            Text("Bridgeplay adds a library to Steam.app and re-signs Steam on this Mac. Valve doesn't support this, and it may go against Steam's terms. Repair Steam in Status undoes it.")
            Text("Online games with anti-cheat often won't start and may flag Bridgeplay. Play them at your own risk.")
        }
        .font(BP.sans(12))
        .foregroundStyle(BP.fg3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
        SetupCard {
            checked(0, StatusRow(title: String(localized: "Steam"),
                      value: model.steamInstalled ? SupportPaths.Steam.app.path(percentEncoded: false)
                        : DownloadMeter.shared.title ?? model.steamProgress ?? String(localized: "Not installed."),
                      tone: model.steamInstalled ? .ok : .warning,
                      action: model.steamInstalled ? nil : StatusAction(
                        label: String(localized: "Install Steam"), isProminent: true, isEnabled: !model.isWorking
                      ) { Task { await model.installSteam() } }))
            SetupHairline()
            checked(1, StatusRow(title: String(localized: "Steam account"),
                      value: model.signedIn ? String(localized: "Signed in.") : String(localized: "Waiting for you to sign in to Steam. Bridgeplay doesn't read or store your password."),
                      tone: model.signedIn ? .ok : .info,
                      action: model.signedIn || !model.steamInstalled ? nil : StatusAction(label: String(localized: "Open Steam"), isProminent: true) { model.openSteam() }))
            SetupHairline()
            checked(2, trustRow)
        }
    }

    // Optional: Continue does not wait for it. No password is asked for.
    private var trustRow: StatusRow {
        let title = String(localized: "Trust Bridgeplay on this Mac")
        switch model.trust {
        case .unknown, .needed:
            return StatusRow(title: title,
                             value: String(localized: "Keeps your controller working after Bridgeplay updates. Adds a certificate for this Mac to your login keychain. If macOS then asks for your password, choose Always Allow."),
                             tone: .info,
                             action: StatusAction(label: String(localized: "Trust"), isEnabled: !model.isWorking && model.trust == .needed) {
                                 Task { await model.trustThisMac() }
                             })
        case .working:
            return StatusRow(title: title, value: String(localized: "Adding the certificate…"), tone: .info)
        case .done:
            return StatusRow(title: title, value: String(localized: "Done. Your controller keeps working after updates."), tone: .ok)
        case .declined(let note):
            return StatusRow(title: title, value: note, tone: .warning,
                             action: StatusAction(label: String(localized: "Try Again"), isEnabled: !model.isWorking) {
                                 Task { await model.trustThisMac() }
                             })
        }
    }

    @ViewBuilder
    private var finishStep: some View {
        StepHeader(step: model.step, title: "Set up Bridgeplay",
                   detail: "Bridgeplay adds itself to Steam, sets up the WineCX engine and makes it Steam's default. Steam closes for a moment.")
        // Above the tasks, so the button is in view without scrolling.
        if model.needsAppManagement {
            SetupCard {
                WizardRow(row: StatusRow(title: String(localized: "App Management"),
                          value: String(localized: "Turn on Bridgeplay in Privacy & Security › App Management. Setup continues by itself once it's on."),
                          tone: .warning,
                          detail: String(localized: "After a Bridgeplay update the switch can look on but no longer work. Turn it off and on again, or remove Bridgeplay from the list with − and add it back with +."),
                          action: StatusAction(label: Remedy.settingsButton, isProminent: true) { model.openAppManagement() }))
            }
        } else if let tool = model.needsSteamRepair {
            SetupCard {
                WizardRow(row: StatusRow(title: String(localized: "Steam needs repair"),
                          value: String(localized: "\(tool) is already set up in Steam. Repair Steam to remove it, and Setup continues by itself."),
                          tone: .warning,
                          action: StatusAction(label: String(localized: "Repair Steam"), isProminent: true) { confirmingRepair = true }))
            }
            .confirmationDialog(String(localized: "Replace Steam with Valve's bundle?"),
                                isPresented: $confirmingRepair, titleVisibility: .visible) {
                Button("Replace Steam", role: .destructive) { Task { await model.repairSteamAndRetry(with: status) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(localized: "\(tool) will stop working in Steam, and Steam may quit for a moment."))
            }
        } else if model.tasks.contains(where: { $0.state != .done }) {
            approvals
        }
        SetupCard {
            ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 { SetupHairline() }
                WizardRow(row: StatusRow(title: task.title, value: value(of: task), tone: tone(of: task),
                                         action: report(task)),
                          pending: task.state == .running)
                    .animation(Self.rowSpring, value: task.state)
            }
        }
        let done = model.tasks.filter { $0.state == .done }.count
        HStack(spacing: 12) {
            GradientProgress(fraction: Double(done) / Double(max(model.tasks.count, 1)))
                .animation(Self.rowSpring, value: done)
            Text("\(done) of \(model.tasks.count)")
                .font(BP.sans(12, .medium))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(done)))
                .animation(Self.rowSpring, value: done)
                .foregroundStyle(BP.fg3)
        }
        .padding(.horizontal, 2)
    }

    // Told before Set Up is pressed, so the macOS dialogs that follow are expected. An older
    // install's certificate in the login keychain makes macOS ask for the login password, once
    // per signed file, until the user picks Always Allow; one in Bridgeplay's own keychain
    // never asks (LocalSigning). App Management can ask too.
    @ViewBuilder
    private var approvals: some View {
        SetupCard {
            if model.trust == .done, model.trustInLoginKeychain {
                WizardRow(row: StatusRow(title: String(localized: "Confirm the Steam update"),
                          value: String(localized: "macOS asks for your Mac password once, so Steam keeps working with Bridgeplay. Type it and choose Always Allow, and it won't ask again."),
                          tone: .info))
                SetupHairline()
            }
            WizardRow(row: StatusRow(title: String(localized: "Allow Bridgeplay in App Management"),
                      value: String(localized: "If macOS shows the switch, turn it on. Setup carries on by itself."),
                      tone: .info))
        }
    }

    // Points people who own CrossOver at it, and the rest at buying it, since that funds Wine.
    private var crossOverRow: StatusRow {
        let title = String(localized: "CrossOver")
        if CrossOverSource.discover().contains(where: \.isUsable) {
            return StatusRow(title: title, value: String(localized: "Found. Set it up in Status to play on it."), tone: .ok)
        }
        return StatusRow(title: title,
                         value: String(localized: "Own CrossOver? Bridgeplay can run games on it. Buying it funds Wine."),
                         tone: .neutral,
                         action: StatusAction(label: String(localized: "Get CrossOver")) {
                             NSWorkspace.shared.open(URL(string: "https://www.codeweavers.com/crossover")!)
                         })
    }

    @ViewBuilder
    private var doneStep: some View {
        StepHeader(step: model.step, title: "You're all set",
                   detail: "Open Steam, install a Windows game and press Play. Status, Prefixes and Prefix Backups in this window change engines, fix a game or undo everything.",
                   emphasized: true)
        SetupCard {
            checked(0, StatusRow(title: String(localized: "Bridgeplay"), value: String(localized: "Installed into Steam."), tone: .ok))
            SetupHairline()
            checked(1, StatusRow(title: String(localized: "WineCX Engine"), value: String(localized: "Steam's default for Windows games."), tone: .ok))
            SetupHairline()
            checked(2, StatusRow(title: String(localized: "Game Porting Toolkit"),
                      value: model.gptk == nil ? String(localized: "Skipped. Games use DXMT; add it later from Status.") : String(localized: "Linked."),
                      tone: model.gptk == nil ? .neutral : .ok))
            SetupHairline()
            checked(3, StatusRow(title: String(localized: "Controllers"),
                      value: String(localized: "The first time a game uses a controller, macOS asks to let Steam use Input Monitoring. Click Allow. If you missed it, turn on Steam in Input Monitoring."),
                      tone: .info,
                      action: StatusAction(label: String(localized: "Open Input Monitoring")) { SystemStatus.openInputMonitoring() }))
            SetupHairline()
            checked(4, crossOverRow)
        }
        Text("For every game")
            .font(BP.sans(13, .semibold))
            .foregroundStyle(BP.fg)
            .padding(.horizontal, 2)
            .padding(.top, 8)
        SetupCard {
            WizardRow(row: StatusRow(title: String(localized: "Metal HUD"),
                      value: String(localized: "Shows frame rate and GPU details in a corner while you play."),
                      toggle: Binding(get: { model.metalHUD }, set: { model.setGameDefault(.metalHUD, $0) })),
                      symbol: "gauge.with.dots.needle.33percent")
            SetupHairline()
            WizardRow(row: StatusRow(title: String(localized: "High Resolution"),
                      value: String(localized: "Sharper on Retina displays, but games run slower."),
                      toggle: Binding(get: { model.highResolution }, set: { model.setGameDefault(.highResolution, $0) })),
                      symbol: "display")
        }
        Text("Both start off. You can change them here later, or for one game in its Steam Properties › Bridgeplay.")
            .font(BP.sans(12))
            .foregroundStyle(BP.fg3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private func value(of task: SetupAssistant.SetupTask) -> String? {
        switch task.state {
        case .waiting: nil
        case .running: DownloadMeter.shared.title ?? status.activity ?? String(localized: "Working…")
        case .done: String(localized: "Done.")
        case .failed(let reason): reason
        }
    }

    // App Management and Repair Steam have their own card and button.
    private func report(_ task: SetupAssistant.SetupTask) -> StatusAction? {
        guard case .failed(let reason) = task.state, !model.needsAppManagement, model.needsSteamRepair == nil
        else { return nil }
        return StatusAction(label: ErrorReport.reportLabel) { ErrorReport.open(reason, in: "Setup: \(task.title)") }
    }

    private func tone(of task: SetupAssistant.SetupTask) -> StatusTone {
        switch task.state {
        case .waiting: .neutral
        case .running: .info
        case .done: .ok
        case .failed: .bad
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage]
        panel.directoryURL = GPTKImport.downloads
        panel.prompt = String(localized: "Use This")
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importGPTK(url) } }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step == .mac {
                Button("Not Now") { model.dismiss(); close() }
                    .buttonStyle(.pillPlain)
            } else if model.step != .done {
                Button("Back") { go(forward: false) { model.back() } }
                    .buttonStyle(.pillPlain)
                    .disabled(model.isWorking)
            } else {
                // Shown once, where it can't be scrolled past.
                Text("Built on [NotProton](https://github.com/NotProtonNot/NotProton) and CodeWeavers' Wine.\nSupport Wine: [buy CrossOver](https://www.codeweavers.com/crossover).")
                    .font(BP.sans(12))
                    .foregroundStyle(BP.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small).padding(.trailing, 4) }
            switch model.step {
            case .mac:
                Button("Continue") { go(forward: true) { model.advance() } }
                    .buttonStyle(.pillLarge)
                    .disabled(!model.macReady || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .graphics:
                if model.gptk == nil {
                    Button("Skip") { go(forward: true) { model.advance() } }
                        .buttonStyle(.pillSecondaryLarge)
                        .disabled(model.isWorking)
                }
                Button("Continue") { go(forward: true) { model.advance() } }
                    .buttonStyle(.pillLarge)
                    .disabled(model.gptk == nil || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .steam:
                Button("Continue") { go(forward: true) { model.advance() } }
                    .buttonStyle(.pillLarge)
                    .disabled(!model.steamInstalled || !model.signedIn || model.isWorking)
                    .keyboardShortcut(.defaultAction)
            case .finish:
                // Secondary while the Repair Steam card leads, for a tool removed some other way.
                if model.needsSteamRepair == nil {
                    Button(model.failed ? "Try Again" : "Set Up") { Task { await model.finish(with: status) } }
                        .buttonStyle(.pillLarge)
                        .disabled(model.isWorking || !(model.failed || model.notStarted))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Try Again") { Task { await model.finish(with: status) } }
                        .buttonStyle(.pillSecondaryLarge)
                        .disabled(model.isWorking)
                }
            case .done:
                Button("Close") { model.dismiss(); close() }
                    .buttonStyle(.pillSecondaryLarge)
                Button("Open Steam") { model.openSteamAndClose(); model.dismiss(); close() }
                    .buttonStyle(.pillLarge)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Pieces

// One continuous gradient across the five segments, revealed up to the current step.
private struct StepBar: View {
    let current: SetupAssistant.Step
    private let steps = SetupAssistant.Step.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                segments { _ in BP.raise2 }
                BP.iridescent
                    .mask(segments { step in step.rawValue <= current.rawValue ? Color.white : Color.clear })
            }
            .frame(height: 3)
            .animation(SetupAssistantView.pageSpring, value: current)
            HStack(spacing: 6) {
                ForEach(steps) { step in
                    Text(step.title)
                        .font(BP.sans(11, step == current ? .semibold : .medium))
                        .foregroundStyle(step == current ? BP.fg : (step.rawValue < current.rawValue ? BP.fg2 : BP.fg3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.2), value: current)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(steps.count), \(current.title)")
    }

    private func segments(_ fill: @escaping (SetupAssistant.Step) -> Color) -> some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in Capsule().fill(fill(step)) }
        }
    }
}

private struct StepHeader: View {
    let step: SetupAssistant.Step
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(step.rawValue + 1) of \(SetupAssistant.Step.allCases.count)")
                .font(BP.sans(11, .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(BP.fg3)
            Text(title)
                .font(BP.sans(28, .semibold))
                .tracking(-0.9)
                .foregroundStyle(emphasized ? AnyShapeStyle(BP.iridescent) : AnyShapeStyle(BP.fg))
            Text(detail)
                .font(BP.sans(14))
                .lineSpacing(2)
                .foregroundStyle(BP.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

// A StatusRow's content in the wizard's style: a tone badge, the title and value, and pill
// buttons on the right.
private struct WizardRow: View {
    let row: StatusRow
    var pending = false
    // A step number in place of the tone, for rows that are instructions.
    var number: Int?
    // A symbol in place of the tone, for rows that are settings rather than checks.
    var symbol: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let number {
                Text("\(number)")
                    .font(BP.sans(12, .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(BP.iridescentDiagonal, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BP.fg2)
                    .frame(width: 24, height: 24)
                    .background(BP.raise2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                ToneBadge(tone: row.tone, pending: pending)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(BP.sans(14, .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(BP.fg)
                    if let trailing = row.trailing {
                        Text(trailing)
                            .font(BP.sans(11, .semibold))
                            .foregroundStyle(BP.fg2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(BP.raise2, in: Capsule())
                    }
                }
                if let value = row.value {
                    Text(value)
                        .font(BP.sans(13))
                        .foregroundStyle(BP.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(BP.sans(12))
                        .foregroundStyle(BP.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let toggle = row.toggle {
                Toggle(row.title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(BP.blue)
            }
            if row.secondaryAction != nil || row.action != nil {
                HStack(spacing: 8) {
                    if let secondary = row.secondaryAction { button(secondary, prominent: false) }
                    if let action = row.action { button(action, prominent: action.isProminent) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func button(_ action: StatusAction, prominent: Bool) -> some View {
        Button(action.label, role: action.role, action: action.perform)
            .buttonStyle(PillButtonStyle(kind: prominent ? .primary : .secondary))
            .fixedSize()
            .disabled(!action.isEnabled)
            .help(action.help ?? "")
    }
}

private struct ToneBadge: View {
    let tone: StatusTone?
    var pending = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border, lineWidth: 1)
            if pending {
                ProgressView().controlSize(.mini)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .ok: BP.green
        case .warning: BP.orange
        case .bad: BP.red
        case .info, .neutral, nil: BP.fg2
        }
    }

    private var fill: Color {
        switch tone {
        case .ok, .warning, .bad: color.opacity(pending ? 0 : 0.14)
        case .info, .neutral, nil: BP.raise2
        }
    }

    private var border: Color {
        switch tone {
        case .ok, .warning, .bad: pending ? BP.line : .clear
        case .info, .neutral, nil: BP.line
        }
    }

    private var symbol: String? {
        switch tone {
        case .ok: "checkmark"
        case .warning: "exclamationmark"
        case .bad: "xmark"
        case .info: "arrow.right"
        case .neutral, nil: nil
        }
    }
}

struct GradientProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(BP.raise2)
                Capsule().fill(BP.iridescent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
