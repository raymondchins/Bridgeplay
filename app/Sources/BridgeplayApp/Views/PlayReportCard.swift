import SwiftUI
import BridgeplayUI

// Asks how the last game session ran. Smooth sends at once; Has Issues and Didn't Run first
// offer an optional note on what went wrong, and Has Issues an optional main problem.
struct PlayReportCard: View {
    let nudge: PlayReports.Nudge
    @State private var pending: ReportStatus?
    @State private var note = ""
    @State private var issue: ReportIssue?
    private var reports: PlayReports { .shared }

    var body: some View {
        Group {
            if let pending { noteRow(pending) } else { answerRow }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: nudge.id) {
            pending = nil
            note = ""
            issue = nil
        }
    }

    private func noteRow(_ status: ReportStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(BP.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("What went wrong? Optional, and public with the report.").font(BP.sans(13, .semibold))
                HStack(spacing: 8) {
                    if status == .bronze {
                        Picker("Main problem", selection: $issue) {
                            Text("Main problem").tag(ReportIssue?.none)
                            ForEach(ReportIssue.allCases, id: \.self) { Text(Self.label($0)).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    TextField("For example: no sound, crashes when a level loads", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send(status) }
                }
            }
            Spacer(minLength: 12)
            Button("Back") {
                pending = nil
                issue = nil
            }
            Button("Send") { send(status) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func send(_ status: ReportStatus) {
        reports.answer(status, note: note, issue: issue)
        pending = nil
        note = ""
        issue = nil
    }

    static func label(_ issue: ReportIssue) -> String {
        switch issue {
        case .performance: String(localized: "Low frame rate or stutter")
        case .crash: String(localized: "Crashes or freezes")
        case .graphics: String(localized: "Graphics glitches")
        case .sound: String(localized: "Sound problems")
        case .controls: String(localized: "Controller, keyboard or mouse")
        case .launcher: String(localized: "Launcher, sign-in or anti-cheat")
        }
    }

    private var answerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(BP.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(question).font(BP.sans(13, .semibold))
                Toggle("Share automatically after each game", isOn: Binding(
                    get: { reports.autoShare }, set: { reports.setAutoShare($0) }))
                    .toggleStyle(.checkbox)
                    .font(BP.sans(12))
                    .foregroundStyle(BP.fg2)
            }
            Spacer(minLength: 12)
            Button("Smooth") { reports.answer(.platinum) }
                .buttonStyle(.borderedProminent)
            Button("Has issues") { pending = .bronze }
            Button("Didn't run") { pending = .borked }
            // A click is Not Now; the menu also offers never asking about this game.
            Menu {
                Button("Not Now") { reports.dismiss() }
                Button("Don't Ask About This Game") { reports.neverAsk() }
                Divider()
                Button("Report Your Games…") { reports.openBulk() }
            } label: {
                Image(systemName: "xmark")
            } primaryAction: {
                reports.dismiss()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Not Now")
            .accessibilityLabel("Not Now")
        }
    }

    private var question: String {
        let name = nudge.prefix.title
        guard let seconds = nudge.session.seconds, seconds >= 60 else {
            return String(localized: "You played \(name). How did it run?")
        }
        let time = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "You played \(name) for \(time). How did it run?")
    }
}

struct PlayReportThanks: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BP.green)
                .accessibilityHidden(true)
            Text("Thanks! Your report is on its way.")
                .font(BP.sans(13, .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

// Shown once, before the first report leaves the Mac.
struct PlayReportConsent: View {
    @State private var alsoAutoShare = false
    private var reports: PlayReports { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share how your games run?")
                .font(BP.sans(17, .semibold))
            Text("Reports are posted publicly in Bridgeplay's GitHub Discussions and counted on the compatibility list. Each one has the game, how it ran, anything you write about it, your Mac's model, chip, GPU cores, memory and displays, whether it was on battery, in Low Power Mode or running hot, the macOS and Bridgeplay versions, the engine, backend and High Resolution setting, and the game's logs. Your home folder, user and computer names, Steam account name, Steam ID and email addresses are removed from the logs first. You don't need a GitHub account. It also sends a random install ID, used only for rate limits. The server sees your IP, like any website.")
                .foregroundStyle(BP.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if reports.consentRequest != .autoShare {
                Toggle("Share automatically after each game", isOn: $alsoAutoShare)
                    .toggleStyle(.checkbox)
            }
            Text("Automatic reports are sent only when the log makes the result clear. You can turn them off in the Prefix menu.")
                .font(BP.sans(12))
                .foregroundStyle(BP.fg3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { reports.consentRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Share") { reports.consent(alsoAutoShare: alsoAutoShare) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// Report Your Games…: one row per game with a session in its log, newest first.
struct BulkReportSheet: View {
    private var reports: PlayReports { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report Your Games")
                .font(BP.sans(17, .semibold))
            Text("How did each game run? Games you already answered for this version of Bridgeplay, games you asked not to be asked about, and games already verified on a Mac like yours are left out.")
                .foregroundStyle(BP.fg2)
                .fixedSize(horizontal: false, vertical: true)
            let list = reports.bulk ?? []
            if reports.bulkLoading {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { row in SkeletonRow(titleWidth: [140, 180, 120][row]) }
                }
                .shimmer()
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Checking"))
            } else if list.isEmpty {
                Text("Nothing left to report.")
                    .foregroundStyle(BP.fg3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(list, id: \.prefix.id) { item in
                    BulkReportRow(item: item)
                }
                .frame(minHeight: 260)
            }
            HStack {
                if !list.isEmpty {
                    Button("Smooth for All Remaining") { reports.answerBulk(list.map(\.prefix.appID), .platinum) }
                }
                Spacer()
                Button("Done") { reports.closeBulk() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
        .sheet(isPresented: Binding(get: { reports.consentRequest != nil },
                                    set: { if !$0 { reports.consentRequest = nil } })) {
            PlayReportConsent()
        }
    }
}

private struct BulkReportRow: View {
    let item: PlayReports.Found
    private var reports: PlayReports { .shared }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.prefix.title).font(BP.sans(13, .semibold)).lineLimit(1)
                Text(detail).font(BP.sans(11)).foregroundStyle(BP.fg3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Smooth") { send(.platinum) }
            Button("Has issues") { send(.bronze) }
            Button("Didn't run") { send(.borked) }
        }
        .controlSize(.small)
        .padding(.vertical, 3)
    }

    private func send(_ status: ReportStatus) { reports.answerBulk([item.prefix.appID], status) }

    private var detail: String {
        let when = item.session.ended.formatted(.relative(presentation: .named))
        guard let seconds = item.session.seconds, seconds >= 60 else {
            return String(localized: "Last played \(when)")
        }
        let time = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "Last played \(when), for \(time)")
    }
}
