import SwiftUI
import BridgeplayUI

struct InstallerView: View {
    @Bindable var model: InstallerModel

    private var title: String {
        switch model.stage {
        case .checking: tr("Check your installation")
        case .review: model.isCurrent ? tr("Finish setting up Bridgeplay") : model.updating ? tr("Update Bridgeplay") : tr("Install Bridgeplay")
        case .downloading: model.settingUp ? tr("Downloading Apple's graphics") : tr("Downloading Bridgeplay")
        case .installing: model.settingUp ? tr("Setting up Bridgeplay") : tr("Installing Bridgeplay")
        case .done: model.isCurrent ? tr("Bridgeplay is up to date") : tr("Bridgeplay is ready")
        case .failed: tr("Installation could not continue")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 240)
            Rectangle().fill(BP.line).frame(width: 1)
            VStack(spacing: 0) {
                steps.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("Bridgeplay Installer")).font(BP.sans(11, .semibold))
                                .tracking(0.9).textCase(.uppercase).foregroundStyle(BP.fg3)
                            Text(title).font(BP.sans(28, .semibold)).tracking(-0.9)
                            Text(detail).font(BP.sans(14)).foregroundStyle(BP.fg2)
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        }
                        content
                        if let failure = model.failure {
                            SetupCard {
                                Label {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(tr("Something went wrong")).font(BP.sans(13, .semibold))
                                        Text(failure).font(BP.sans(12)).foregroundStyle(BP.fg2)
                                            .textSelection(.enabled)
                                    }
                                } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(BP.orange) }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                Rectangle().fill(BP.line).frame(height: 1)
                footer.padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .frame(width: 780, height: 580)
        .background(BP.bg).foregroundStyle(BP.fg)
        .environment(\.colorScheme, .dark).tint(BP.accent)
        .onChange(of: model.stage) {
            for window in NSApplication.shared.windows {
                window.standardWindowButton(.closeButton)?.isEnabled = model.stage != .installing
            }
        }
    }

    private var detail: String {
        switch model.stage {
        case .checking: tr("Checking the latest release and the application on this Mac.")
        case .review: tr("The application goes in Applications. Your settings, game prefixes and saves are kept.")
        case .downloading: model.settingUp
            ? tr("Apple's Game Porting Toolkit and Bridgeplay's graphics layers, checked against Bridgeplay's signature. Setup adds the WineCX engine later.")
            : tr("Only the application is downloaded here. Its signature is checked before installation.")
        case .installing: model.settingUp
            ? tr("Installing Steam, Apple's graphics, the engine and the default settings. Please keep the installer open.")
            : tr("Verifying and replacing the application. Please keep the installer open.")
        case .done: tr("Open Bridgeplay to finish setup: Rosetta, Steam sign-in and a couple of standard macOS prompts.")
        case .failed: tr("Review the details below, then try again. The installer does not remove your game data.")
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4.4) {
                BridgeplayMark(size: 22)
                Text(verbatim: "Bridgeplay").font(BP.display(13)).foregroundStyle(BP.iridescent)
            }
            .padding(22)
            Spacer()
            BridgeplayMark(size: 136).frame(maxWidth: .infinity)
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Windows games.")).foregroundStyle(BP.fg)
                Text(tr("In your Mac's Steam.")).foregroundStyle(BP.iridescent)
            }
            .font(BP.sans(19, .semibold)).tracking(-0.5).padding(24)
        }
        .background(BP.bg)
    }

    private var steps: some View {
        let names = [tr("Check"), tr("Review"), tr("Install"), tr("Finish")]
        return VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { _ in Capsule().fill(BP.raise2) }
                }
                BP.iridescent.mask {
                    HStack(spacing: 6) {
                        ForEach(0..<4) { index in Capsule().fill(index <= model.step ? Color.white : .clear) }
                    }
                }
            }.frame(height: 3)
            HStack(spacing: 6) {
                ForEach(0..<4) { index in
                    Text(names[index]).font(BP.sans(11, index == model.step ? .semibold : .medium))
                        .foregroundStyle(index == model.step ? BP.fg : BP.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names[model.step])
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .checking:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
        case .review:
            SetupCard {
                row(tr("Version"), value: model.version, icon: "arrow.down.circle")
                if let installed = model.installedVersion {
                    SetupHairline()
                    row(tr("Installed"), value: installed, icon: "checkmark.circle")
                }
                SetupHairline()
                row(tr("Location"), value: model.destination.path, icon: "folder")
                if let total = model.total {
                    SetupHairline()
                    row(tr("Download"), value: bytes(total), icon: "network")
                }
            }
            Text(model.components == nil
                 ? tr("Close Bridgeplay before updating. Steam setup and any required permissions are handled by Bridgeplay after installation.")
                 : tr("Steam and Apple's graphics are installed too. Setup adds the WineCX engine later."))
                .font(BP.sans(12)).foregroundStyle(BP.fg3).fixedSize(horizontal: false, vertical: true)
        case .downloading, .installing:
            SetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        if model.paused { Image(systemName: "pause.circle.fill").foregroundStyle(BP.fg2) }
                        else { ProgressView().controlSize(.small) }
                        Text(model.stage == .downloading ? (model.paused ? tr("Paused") : tr("Downloading"))
                             : model.componentStatus ?? tr("Verifying and installing"))
                            .font(BP.sans(13, .semibold))
                    }
                    if model.stage == .downloading {
                        if let value = model.progress {
                            ProgressView(value: min(max(value, 0), 1)).tint(BP.accent)
                        } else { ProgressView().progressViewStyle(.linear).tint(BP.accent) }
                        HStack(spacing: 12) {
                            Text(DownloadRate.amount(received: model.received, total: model.total, speed: model.paused ? nil : model.speed))
                                .font(BP.sans(12)).monospacedDigit().foregroundStyle(BP.fg2)
                            Spacer(minLength: 8)
                            Button(model.paused ? tr("Resume") : tr("Pause")) { model.togglePause() }
                                .buttonStyle(.pillSecondary)
                        }
                    } else if let meter = model.scriptDownload {
                        if let total = meter.total {
                            ProgressView(value: min(max(Double(meter.received) / Double(total), 0), 1)).tint(BP.accent)
                        } else { ProgressView().progressViewStyle(.linear).tint(BP.accent) }
                        Text(DownloadRate.amount(received: meter.received, total: meter.total, speed: meter.speed))
                            .font(BP.sans(12)).monospacedDigit().foregroundStyle(BP.fg2)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .done:
            SetupCard {
                row(tr("Version"), value: model.version, icon: "checkmark.circle.fill")
                SetupHairline()
                row(tr("Game data"), value: tr("Kept in place"), icon: "externaldrive")
            }
            Toggle(tr("Open Bridgeplay"), isOn: $model.openBridgeplay).font(BP.sans(13))
            // Only when run from a DMG. From the ZIP the installer stays in Downloads: moving it
            // to Trash would ask for access to the Downloads folder, one more prompt.
            if model.cleanupSource != nil {
                Toggle(tr("Eject installer and move DMG to Trash"), isOn: $model.removeInstaller)
                    .font(BP.sans(13))
            }
        case .failed: EmptyView()
        }
    }

    private func row(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(BP.blue).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(BP.sans(13, .semibold))
                Text(value).font(BP.sans(12)).foregroundStyle(BP.fg2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if model.stage != .installing && model.stage != .done {
                Button(tr("Cancel")) {
                    model.cancel()
                    if model.preview == nil { NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(.pillPlain).keyboardShortcut(.cancelAction)
            }
            if model.stage == .failed {
                Button(tr("Show Log")) { model.showLog() }.buttonStyle(.pillPlain)
                Button(tr("Report on GitHub")) { model.report() }.buttonStyle(.pillPlain)
            }
            Spacer()
            switch model.stage {
            case .review:
                Button(model.updating && !model.isCurrent ? tr("Update") : tr("Install")) { model.start() }
                    .buttonStyle(.pillLarge).keyboardShortcut(.defaultAction)
            case .failed:
                Button(tr("Try Again")) { model.retry() }.buttonStyle(.pillLarge).keyboardShortcut(.defaultAction)
            case .done:
                Button(tr("Finish")) { model.finish() }.buttonStyle(.pillLarge)
                    .disabled(model.finishing).keyboardShortcut(.defaultAction)
            default: EmptyView()
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
