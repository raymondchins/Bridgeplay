// The questions PrefixesModel asks before it acts, shared by the Games, Prefixes and Backups
// pages: Move to Trash, Rebuild, Back Up, Clear Shader Cache, Delete Permanently when a drive
// has no Trash, and Restore.

import SwiftUI

struct PrefixDialogs: ViewModifier {

    @Environment(PrefixesModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                PrefixPrompt.deleteTitle(deleting).keepingLastWordsTogether,
                isPresented: asking { if case .delete = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.deleteButton(deleting), role: .destructive) {
                    let targets = deleting
                    model.pendingConfirmation = nil
                    Task { await model.delete(targets) }
                }
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(PrefixPrompt.deleteMessage(
                    deleting,
                    backups: model.backups.filter { backup in deleting.contains { $0.id == backup.prefix.id } }.count).keepingLastWordsTogether)
            }
            .confirmationDialog(
                PrefixPrompt.rebuildTitle(rebuilding, for: rebuildTool),
                isPresented: asking { if case .rebuild = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.rebuildWithBackupButton(rebuilding)) {
                    model.confirmRebuild()
                }
                .keyboardShortcut(.defaultAction)
                Button(PrefixPrompt.rebuildWithoutBackupButton(rebuilding)) {
                    model.confirmRebuild(keepBackup: false)
                }
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
            } message: {
                Text(PrefixPrompt.rebuildMessage())
            }
            .confirmationDialog(
                PrefixPrompt.backUpTitle(backingUp),
                isPresented: asking { if case .backUp = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.backUpButton(backingUp)) {
                    let targets = backingUp
                    model.pendingConfirmation = nil
                    Task { await model.backUp(targets) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
            } message: {
                Text(PrefixPrompt.backUpMessage(backingUp, bytes: backUpBytes))
            }
            .confirmationDialog(
                PrefixPrompt.clearShaderCacheTitle(clearingCache).keepingLastWordsTogether,
                isPresented: asking { if case .clearShaderCache = $0 { true } else { false } },
                titleVisibility: .visible
            ) {
                Button(PrefixPrompt.clearShaderCacheButton(clearingCache), role: .destructive) {
                    let targets = clearingCache
                    model.pendingConfirmation = nil
                    Task { await model.clearShaderCaches(targets) }
                }
                Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(PrefixPrompt.clearShaderCacheMessage(bytes: model.shaderCacheBytes(clearingCache)).keepingLastWordsTogether)
            }
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

    private var deleting: [WinePrefix] {
        if case .delete(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuilding: [WinePrefix] {
        if case .rebuild(let targets, _) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuildTool: InstalledTool? {
        if case .rebuild(_, let tool) = model.pendingConfirmation { return tool }
        return nil
    }

    private var backingUp: [WinePrefix] {
        if case .backUp(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private var backUpBytes: Int64? {
        var total: Int64 = 0
        for prefix in backingUp {
            guard let bytes = model.usage[prefix.id]?.bytes else { return nil }
            total += bytes
        }
        return total
    }

    private var clearingCache: [WinePrefix] {
        if case .clearShaderCache(let targets) = model.pendingConfirmation { return targets }
        return []
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
