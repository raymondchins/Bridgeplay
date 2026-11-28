import AppKit
import BridgeplayUI
import SwiftUI

// Remove Everything, step one: what goes, what stays, and which prefixes go to the Trash.
struct UninstallPlanSheet: View {
    let plan: UninstallPlan
    let confirm: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trashing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove Bridgeplay?").font(BP.sans(17, .semibold))
            Text(Uninstall.confirmation()).font(BP.sans(13)).foregroundStyle(BP.fg2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    UninstallSection(title: String(localized: "Removed"), items: plan.remove)
                    Text(steamLine).font(BP.sans(13)).fixedSize(horizontal: false, vertical: true)
                    if !plan.prefixes.isEmpty { prefixes }
                    UninstallSection(title: String(localized: "Kept"), items: plan.keeps.filter { item in
                        !plan.prefixes.contains { $0.prefix.root == item.url }
                    })
                    if !plan.otherUsers.isEmpty { UninstallOtherUsers(names: plan.otherUsers) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pillPlain)
                    .keyboardShortcut(.cancelAction)
                Button("Remove Everything") {
                    dismiss()
                    confirm(trashing)
                }
                .buttonStyle(.pill)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var steamLine: String {
        guard plan.steamModified else { return String(localized: "Steam is unchanged.") }
        let line = plan.steamKeptOffline
            ? String(localized: "Steam is restored when it quits.")
            : String(localized: "Steam is downloaded again when it quits.")
        guard !plan.otherSteamCopies.isEmpty else { return line }
        let copies = plan.otherSteamCopies.map(\.plainPath).joined(separator: ", ")
        return line + "\n" + String(localized: "Also restored: \(copies)")
    }

    private var prefixes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prefixes").font(BP.sans(13, .semibold))
            Text("Checked ones go to the Trash, saves included.")
                .font(BP.sans(12)).foregroundStyle(BP.fg2).fixedSize(horizontal: false, vertical: true)
            ForEach(plan.prefixes) { entry in
                Toggle(isOn: Binding(
                    get: { trashing.contains(entry.id) },
                    set: { if $0 { trashing.insert(entry.id) } else { trashing.remove(entry.id) } }
                )) {
                    Text(verbatim: "\(entry.prefix.title) · \(entry.size)").font(BP.sans(12))
                }
                .help(entry.prefix.root.plainPath)
            }
        }
    }
}

// Remove Everything, step two: the checklist and the proof that Steam is Valve's again.
struct UninstallChecklistSheet: View {
    let checklist: UninstallChecklist
    let verify: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bridgeplay removed").font(BP.sans(17, .semibold))
            VStack(alignment: .leading, spacing: 6) {
                UninstallCheck(passed: checklist.verification.signedByValve, label: signatureLine)
                UninstallCheck(passed: checklist.verification.leftInSteam.isEmpty,
                               label: checklist.verification.leftInSteam.isEmpty
                                   ? String(localized: "Steam is clean")
                                   : String(localized: "Files left in Steam"))
                ForEach(checklist.verification.leftInSteam) { UninstallPath(item: $0) }
                if !checklist.verification.signedByValve {
                    Text("Repair or reinstall Steam.")
                        .font(BP.sans(12)).foregroundStyle(BP.fg2)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    UninstallSection(title: String(localized: "Removed"), items: checklist.removed)
                    UninstallSection(title: String(localized: "Trashed"), items: checklist.trashed)
                    UninstallSection(title: String(localized: "Kept"), items: checklist.remains)
                    if !checklist.otherUsers.isEmpty { UninstallOtherUsers(names: checklist.otherUsers) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            HStack {
                Button("Copy List") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(checklist.text, forType: .string)
                }
                .buttonStyle(.pillSecondary)
                Spacer()
                Button("Check Again") {
                    checking = true
                    Task { await verify(); checking = false }
                }
                .buttonStyle(.pillSecondary)
                .disabled(checking)
                Button("Done") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var signatureLine: String {
        switch checklist.verification.signature {
        case .valve: String(localized: "Signed by Valve")
        case .missing: String(localized: "Steam not installed")
        case .notValve: String(localized: "Not signed by Valve")
        }
    }
}

private struct UninstallCheck: View {
    let passed: Bool
    let label: String

    var body: some View {
        Label {
            Text(label).font(BP.sans(13))
        } icon: {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(passed ? BP.green : BP.orange)
        }
    }
}

private struct UninstallSection: View {
    let title: String
    let items: [UninstallItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(BP.sans(13, .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { UninstallPath(item: $0) }
                }
            }
        }
    }
}

private struct UninstallPath: View {
    let item: UninstallItem

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: item.path).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            let extra = [item.size, item.note].compactMap { $0 }.joined(separator: " · ")
            if !extra.isEmpty {
                Text(verbatim: extra).font(BP.sans(11)).foregroundStyle(BP.fg3)
            }
        }
    }
}

private struct UninstallOtherUsers: View {
    let names: [String]

    var body: some View {
        Text("Also removes Bridgeplay from Steam for \(names.formatted(.list(type: .and))).")
            .font(BP.sans(12)).foregroundStyle(BP.fg2).fixedSize(horizontal: false, vertical: true)
    }
}
