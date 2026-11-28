import SwiftUI

// Under the Status hero: the games whose last launch went wrong in the past three days, each
// with why in one sentence and what to do next.
struct LastLaunchSection: View {
    let launches: [LastLaunch]
    var openPane: ((Pane) -> Void)?
    @Environment(PrefixesModel.self) private var prefixes
    @State private var hidden = LastLaunchDismissals.hidden()

    var body: some View {
        let shown = LastLaunchDismissals.visible(launches, hidden: hidden)
        if !shown.isEmpty {
            Section("Last Launch") {
                ForEach(shown) { launch in row(launch) }
            }
        }
    }

    private func row(_ launch: LastLaunch) -> some View {
        var menu = [StatusAction(label: String(localized: "Hide")) {
            LastLaunchDismissals.hide(launch)
            hidden = LastLaunchDismissals.hidden()
        }]
        if launch.hasPrefix, launch.verdict.offersRebuild {
            menu.insert(StatusAction(label: String(localized: "Rebuild Prefix\u{2026}"), isEnabled: !prefixes.isBusy) {
                Task {
                    await prefixes.askRebuild(launch.prefix)
                    openPane?(.prefixes)
                }
            }, at: 0)
        }
        let hasLog = PrefixTools.hasLog(.launch, for: launch.prefix)
        return StatusRow(
            title: launch.prefix.title,
            value: launch.verdict.sentence,
            tone: .warning,
            detail: [launch.duration, launch.ended.formatted(.relative(presentation: .named))]
                .joined(separator: " · "),
            secondaryAction: StatusAction(label: String(localized: "Open Log"),
                                          help: hasLog ? nil : String(localized: "This launch left no log."),
                                          isEnabled: hasLog) {
                PrefixTools.openLastRun(for: launch.prefix)
            },
            action: StatusAction(label: String(localized: "Report")) {
                PlayReports.shared.ask(about: launch.prefix)
            },
            menu: menu
        )
    }
}
