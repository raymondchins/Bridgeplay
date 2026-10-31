// Strings for the delete/recreate confirmation prompts. Kept out of the view so
// they can be tested. Dumb development artifact, basically.

import Foundation

enum PrefixPrompt {

    static func deleteTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: String(localized: "Delete prefix?")
        case 1: String(localized: "Delete the prefix for \(targets[0].title)?")
        default: String(localized: "Delete \(targets.count) prefixes?")
        }
    }

    static func deleteButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Delete \(targets.count) Prefixes") : String(localized: "Delete Prefix")
    }

    // Backups live inside the folder a delete removes, so they go with it.
    static func deleteMessage(_ targets: [WinePrefix], backups: Int = 0) -> String {
        var lines = targets.count > 1
            ? [String(localized: "This will DELETE the prefixes for \(targets.count) games."),
               String(localized: "The game SAVE DATA inside them WILL BE LOST.")]
            : [String(localized: "This will DELETE the game's prefix."),
               String(localized: "The game SAVE DATA inside the prefix WILL BE LOST.")]
        if backups == 1 {
            lines.append(String(localized: "Its 1 backup will also be permanently deleted."))
        } else if backups > 1 {
            lines.append(String(localized: "All \(backups) backups will also be permanently deleted."))
        }
        lines.append(String(localized: "Are you sure you want to do this?"))
        return sentences(lines)
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

    static func backUpMessage(_ targets: [WinePrefix] = []) -> String {
        targets.count > 1
            ? String(localized: "Are you sure you want to back up these prefixes?")
            : String(localized: "Are you sure you want to back up this prefix?")
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
        case 0: String(localized: "Delete backup?")
        case 1: String(localized: "Delete the backup for \(targets[0].title)?")
        default: String(localized: "Delete \(targets.count) backups?")
        }
    }

    static func deleteBackupsButton(_ targets: [PrefixBackup]) -> String {
        targets.count > 1 ? String(localized: "Delete \(targets.count) Backups") : String(localized: "Delete Backup")
    }

    static func deleteBackupsMessage(_ targets: [PrefixBackup] = []) -> String {
        guard targets.count > 1 else {
            return sentences([
                String(localized: "Are you sure you want to delete this backup?"),
                String(localized: "Any data in it will be lost."),
            ])
        }
        return sentences([
            String(localized: "Are you sure you want to delete these \(targets.count) backups?"),
            String(localized: "Any data in them will be lost."),
        ])
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: " ")
    }
}
