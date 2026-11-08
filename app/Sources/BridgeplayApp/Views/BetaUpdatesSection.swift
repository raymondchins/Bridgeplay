import SwiftUI

// The Status page's Updates section. Empty, and so absent, on a stable build with no beta keys.
struct BetaUpdatesSection: View {
    @State private var beta = BetaSwitch()

    var body: some View {
        let updater = AppUpdater.shared
        let running = updater.running
        if BetaUpdatesUI.visible(shown: updater.betaUIShown, state: updater.state, backOnStable: updater.backOnStable) {
            Section {
                if let back = updater.backOnStable {
                    let row = BetaCopy.backOnStable(back)
                    StatusRow(title: row.title, value: row.value, tone: .ok,
                              action: StatusAction(label: String(localized: "OK")) { updater.dismissBackOnStable() })
                }
                if let status = BetaStatus.make(state: updater.state, running: running,
                                                preferenceSet: BetaUpdatesUI.preferenceSet(.standard)) {
                    let row = BetaCopy.row(status, nothingFound: updater.leavingNothingFound)
                    StatusRow(title: row.title, value: row.value, tone: .info, detail: row.detail)
                }
                if updater.betaUIShown {
                    StatusRow(title: BetaCopy.toggle, value: BetaCopy.footnote, toggle: Binding(
                        get: { updater.betaEnrolled },
                        set: { beta.request($0, enrolled: updater.betaEnrolled) }
                    ))
                    .confirmationDialog(confirmation?.title ?? "", isPresented: asking, titleVisibility: .visible) {
                        // Captured here: the dialog may clear `asking` before the action runs.
                        if let ask = beta.asking {
                            Button(confirmation?.button ?? "") {
                                updater.setBetaUpdates(ask.enrolls)
                                beta.cancel()
                            }
                        }
                        Button("Cancel", role: .cancel) { beta.cancel() }
                    } message: {
                        Text(confirmation?.message ?? "")
                    }
                }
            } header: {
                Text("Updates")
            }
        }
    }

    private var confirmation: BetaConfirmation? {
        beta.asking.map { BetaCopy.confirmation($0, running: AppUpdater.shared.running, pending: AppUpdater.shared.pending) }
    }

    private var asking: Binding<Bool> {
        Binding(get: { beta.asking != nil }, set: { if !$0 { beta.cancel() } })
    }
}
