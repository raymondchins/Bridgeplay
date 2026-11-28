// The questions both the Prefixes and the Backups pages ask: Delete Permanently when a drive
// has no Trash, and Restore.

import SwiftUI

struct PrefixDialogs: ViewModifier {

    @Environment(PrefixesModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                PrefixPrompt.deletePermanentlyTitle(prefixes: permanent.prefixes, backups: permanent.backups).keepingLastWordsTogether,
                isPresented: asking { if case .deletePermanently = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.deletePermanentlyButton(), role: .destructive) {
                    let (prefixes, backups) = permanent
                    model.pendingConfirmation = nil
                    Task { await model.deletePermanently(prefixes, backups) }
                }
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(PrefixPrompt.deletePermanentlyMessage(
                    bytes: model.permanentBytes(permanent.prefixes, permanent.backups),
                    prefixes: permanent.prefixes.count).keepingLastWordsTogether)
            }
            .confirmationDialog(
                PrefixPrompt.restoreTitle(restoring).keepingLastWordsTogether,
                isPresented: asking { if case .restore = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.restoreButton()) {
                    guard let backup = restoring else { return }
                    model.pendingConfirmation = nil
                    Task { await model.restore(backup) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
            } message: {
                Text(PrefixPrompt.restoreMessage().keepingLastWordsTogether)
            }
    }

    private var permanent: (prefixes: [WinePrefix], backups: [PrefixBackup]) {
        if case .deletePermanently(let prefixes, let backups) = model.pendingConfirmation { return (prefixes, backups) }
        return ([], [])
    }

    private var restoring: PrefixBackup? {
        if case .restore(let backup) = model.pendingConfirmation { return backup }
        return nil
    }

    private func asking(_ matches: @escaping (PrefixesModel.Confirmation) -> Bool) -> Binding<Bool> {
        Binding(
            get: { model.pendingConfirmation.map(matches) ?? false },
            set: { shown in
                if !shown, model.pendingConfirmation.map(matches) ?? false { model.pendingConfirmation = nil }
            }
        )
    }
}

extension View {
    func prefixDialogs() -> some View { modifier(PrefixDialogs()) }
}
