// Strings for the delete/recreate/restore confirmation prompts. Kept out of the view so
// they can be tested. Dumb development artifact, basically.

import Foundation

enum PrefixPrompt {

    static func deleteTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: String(localized: "Move prefix to Trash?")
        case 1: String(localized: "Move prefix for \(targets[0].title) to Trash?")
        default: String(localized: "Move \(targets.count) prefixes to Trash?")
        }
    }

    static func deleteButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Move \(targets.count) to Trash") : String(localized: "Move to Trash")
    }

    // Saves live in the prefix, and backups inside the folder a delete moves, so both go.
    static func deleteMessage(_ targets: [WinePrefix], backups: Int = 0) -> String {
        let what = switch backups {
        case 0: String(localized: "Saves go too.")
        case 1: String(localized: "Saves and 1 backup go too.")
        default: String(localized: "Saves and \(backups) backups go too.")
        }
        return sentences([what, String(localized: "Put them back before the next launch.")])
    }

    // Asked only after a move to the Trash failed, so nothing has been deleted yet.
    static func deletePermanentlyTitle(prefixes: [WinePrefix], backups: [PrefixBackup]) -> String {
        prefixes.count + backups.count == 1
            ? String(localized: "This drive has no Trash")
            : String(localized: "These drives have no Trash")
    }

    static func deletePermanentlyMessage(bytes: Int64?, prefixes: Int) -> String {
        var lines = [String(localized: "Nothing deleted yet.")]
        if let bytes {
            let size = bytes.formatted(.byteCount(style: .file))
            lines.append(String(localized: "Frees \(size). Can't be undone."))
        } else {
            lines.append(String(localized: "Can't be undone."))
        }
        if prefixes > 0 {
            lines.append(String(localized: "Saves and backups will be lost."))
        }
        return sentences(lines)
    }

    static func deletePermanentlyButton() -> String {
        String(localized: "Delete Permanently")
    }

    static func rebuildTitle(_ targets: [WinePrefix], for tool: InstalledTool? = nil) -> String {
        let with = tool.map { String(localized: " with \($0.display)") } ?? ""
        switch targets.count {
        case 0: return String(localized: "Rebuild prefix\(with)?")
        case 1: return String(localized: "Rebuild the prefix for \(targets[0].title)\(with)?")
        default: return String(localized: "Rebuild \(targets.count) prefixes\(with)?")
        }
    }

    static func rebuildButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Rebuild \(targets.count) Prefixes") : String(localized: "Rebuild Prefix")
    }

    static func rebuildWithBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? String(localized: "Back Up and Rebuild \(targets.count) Prefixes") : String(localized: "Back Up and Rebuild")
    }

    static func rebuildWithoutBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? String(localized: "Rebuild \(targets.count) Prefixes Without Backing Up")
            : String(localized: "Rebuild Without Backing Up")
    }

    static func backUpTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: String(localized: "Back up prefix?")
        case 1: String(localized: "Back up the prefix for \(targets[0].title)?")
        default: String(localized: "Back up \(targets.count) prefixes?")
        }
    }

    static func backUpButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Back Up \(targets.count) Prefixes") : String(localized: "Back Up Prefix")
    }

    // bytes: the prefixes' private size, nil while it is still being measured.
    static func backUpMessage(_ targets: [WinePrefix] = [], bytes: Int64? = nil) -> String {
        guard let bytes else {
            return targets.count > 1
                ? String(localized: "Each copy stays beside its prefix.")
                : String(localized: "The copy stays beside the prefix.")
        }
        let size = bytes.formatted(.byteCount(style: .file))
        guard targets.count == 1 else {
            return String(localized: "\(size), each beside its prefix.")
        }
        return String(localized: "\(size), kept on \(targets[0].library.displayName).")
    }

    static func restoreTitle(_ backup: PrefixBackup?) -> String {
        guard let backup else { return String(localized: "Restore backup?") }
        guard let taken = backup.taken else { return String(localized: "Restore backup for \(backup.title)?") }
        let date = taken.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Restore \(backup.title) from \(date)?")
    }

    static func restoreButton() -> String {
        String(localized: "Restore Backup")
    }

    static func restoreMessage() -> String {
        sentences([
            String(localized: "Current data becomes a new backup."),
            String(localized: "If Steam Cloud asks, pick your save."),
        ])
    }

    static func clearShaderCacheTitle(_ targets: [WinePrefix]) -> String {
        targets.count == 1
            ? String(localized: "Clear shader cache for \(targets[0].title)?")
            : String(localized: "Clear \(targets.count) shader caches?")
    }

    static func clearShaderCacheButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Clear \(targets.count) Shader Caches") : String(localized: "Clear Shader Cache")
    }

    static func clearShaderCacheMessage(bytes: Int64) -> String {
        let size = bytes.formatted(.byteCount(style: .file))
        return sentences([
            String(localized: "Frees \(size). Saves stay."),
            String(localized: "The next launch may stutter."),
        ])
    }

    static func rebuildMessage() -> String {
        sentences([
            String(localized: "This tool is intended to repair a prefix after switching between Rosetta/FEX CrossOver."),
            String(localized: "It will replace the DLLs used by CrossOver with ones that match your compatibility tool."),
            String(localized: "This can also fix issues where a game previously started/worked and does not work now, even if you did not switch CrossOver types."),
            String(localized: "You will not lose saves by using this tool."),
        ])
    }

    static func deleteBackupsTitle(_ targets: [PrefixBackup]) -> String {
        switch targets.count {
        case 0: String(localized: "Move backup to Trash?")
        case 1: String(localized: "Move backup for \(targets[0].title) to Trash?")
        default: String(localized: "Move \(targets.count) backups to Trash?")
        }
    }

    static func deleteBackupsButton(_ targets: [PrefixBackup]) -> String {
        targets.count > 1 ? String(localized: "Move \(targets.count) to Trash") : String(localized: "Move to Trash")
    }

    static func deleteBackupsMessage(_ targets: [PrefixBackup] = []) -> String {
        String(localized: "Undo with Put Back in the Trash.")
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: " ")
    }
}
