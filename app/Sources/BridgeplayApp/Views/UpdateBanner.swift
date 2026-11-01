import BridgeplayUI
import SwiftUI

enum RestartBlock: Equatable, Sendable {
    case game
    case work
}

// The updater's state, read from AppUpdater. In the setup assistant it only answers a click,
// so an update found in the background doesn't interrupt setup.
struct UpdateNotice: View {
    var onlyWhenAsked = false
    // Bridgeplay's own work, which a restart would cut off.
    var busy = false

    @State private var showsChanges = false

    var body: some View {
        let updater = AppUpdater.shared
        if let stage = updater.flow.notice, !onlyWhenAsked || updater.flow.checkQueued {
            UpdateBanner(stage: stage, block: updater.flow.gameRunning ? .game : busy ? .work : nil) {
                if case .ready = stage {
                    Task { await updater.restartToUpdate(busy: busy) }
                } else {
                    updater.check()
                }
            }
            .task(id: stage) {
                guard case .ready = stage else { return }
                while !Task.isCancelled {
                    await updater.refreshRestartBlock()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } else if !onlyWhenAsked, let whatsNew = updater.whatsNew {
            WhatsNewBanner(whatsNew: whatsNew, open: { showsChanges = true }, dismiss: updater.dismissWhatsNew)
                .sheet(isPresented: $showsChanges) { WhatsNewSheet(whatsNew: whatsNew) }
        }
    }
}

// Sparkle downloads in the background without a window, so this says one is on the way.
// Sparkle reports no progress for those downloads, hence the spinner instead of a bar.
struct UpdateBanner: View {
    let stage: UpdateStage
    var block: RestartBlock?
    let action: () -> Void

    var body: some View {
        UpdateBannerRow {
            if button == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(BP.blue)
                    .accessibilityHidden(true)
            }
        } text: {
            Text(title).font(BP.sans(13, .semibold))
            if let detail {
                Text(detail)
                    .font(BP.sans(12))
                    .foregroundStyle(BP.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let button {
                Button(button, action: action)
                    .buttonStyle(.pillSecondary)
                    .disabled(block != nil)
            }
        }
    }

    private var title: String {
        switch stage {
        case .idle, .checking: String(localized: "Checking for updates…")
        case .available(let version): String(localized: "Bridgeplay \(version) is available")
        case .downloading(let version): String(localized: "Downloading Bridgeplay \(version)")
        case .preparing(let version): String(localized: "Getting Bridgeplay \(version) ready")
        case .ready(let version): String(localized: "Bridgeplay \(version) is ready to install")
        }
    }

    private var detail: String? {
        switch stage {
        case .ready:
            switch block {
            case .game: String(localized: "A game is running, so Bridgeplay won't restart. The update installs when you quit.")
            case .work: String(localized: "Bridgeplay is busy, so it won't restart yet. The update installs when you quit.")
            case nil: String(localized: "It installs when you quit Bridgeplay, or you can restart now.")
            }
        case .downloading: String(localized: "You can keep using Bridgeplay while it downloads.")
        default: nil
        }
    }

    private var button: String? {
        switch stage {
        case .available: String(localized: "View Update…")
        case .ready: String(localized: "Restart to Update")
        default: nil
        }
    }
}

struct WhatsNewBanner: View {
    let whatsNew: WhatsNew
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        UpdateBannerRow {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BP.blue)
                .accessibilityHidden(true)
        } text: {
            Text("Updated to Bridgeplay \(whatsNew.version)").font(BP.sans(13, .semibold))
        } actions: {
            if !whatsNew.changes.isEmpty {
                Button("What's New", action: open).buttonStyle(.pillSecondary)
            }
            Button(String(localized: "Close"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(BP.fg2)
        }
    }
}

private struct WhatsNewSheet: View {
    let whatsNew: WhatsNew

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's New in Bridgeplay \(whatsNew.version)").font(BP.sans(15, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(whatsNew.changes, id: \.self) { change in
                        Text(verbatim: "• \(change)")
                            .font(BP.sans(13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.pillSecondary)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct UpdateBannerRow<Icon: View, Words: View, Actions: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let text: Words
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) { text }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BP.raise)
        .overlay(alignment: .bottom) { Rectangle().fill(BP.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
