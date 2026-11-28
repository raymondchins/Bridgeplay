import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Asking before a prefix goes")
struct PrefixPromptTests {

    private func prefix(_ appID: String, _ name: String?) -> WinePrefix {
        WinePrefix(
            appID: appID,
            name: name,
            library: SteamLibrary(root: URL(filePath: "/Users/tester/Library/Application Support/Steam")),
            lastUsed: nil)
    }

    private var agent: WinePrefix { prefix("1574480", "Agent 64: Spies Never Die") }
    private var ikaruga: WinePrefix { prefix("253750", "IKARUGA") }
    private var orphan: WinePrefix { prefix("1649240", nil) }

    @Test("One prefix is asked about by name")
    func singleDeleteNamesTheGame() {
        #expect(PrefixPrompt.deleteTitle([agent]) == "Move prefix for Agent 64: Spies Never Die to Trash?")
        #expect(PrefixPrompt.deleteButton([agent]) == "Move to Trash")
        // A prefix whose game is gone still has to be askable about.
        #expect(PrefixPrompt.deleteTitle([orphan]) == "Move prefix for App 1649240 to Trash?")
    }

    // The Prefix menu shows the delete item greyed out with nothing selected, and it shows
    // it by name, so an empty selection has to read as an action rather than as a count.
    @Test("With nothing selected the delete item still reads as an action")
    func emptySelectionReadsAsTheAction() {
        #expect(PrefixPrompt.deleteButton([]) == "Move to Trash")
        #expect(PrefixPrompt.deleteTitle([]) == "Move prefix to Trash?")
    }

    // Naming one of them and deleting all of them is how the wrong prefix gets thrown
    // away, so more than one is counted instead.
    @Test("Several prefixes are counted, not named")
    func multipleDeleteCountsThem() {
        let targets = [agent, ikaruga, orphan]
        #expect(PrefixPrompt.deleteTitle(targets) == "Move 3 prefixes to Trash?")
        #expect(PrefixPrompt.deleteButton(targets) == "Move 3 to Trash")
    }

    @Test("Delete says the save data goes to the Trash and how to undo it")
    func deleteSaysSavesGoToTheTrash() {
        #expect(PrefixPrompt.deleteMessage([agent])
            == "Saves go too. Put them back before the next launch.")
        #expect(!PrefixPrompt.deleteMessage([agent, ikaruga]).contains("Agent 64"))
    }

    @Test("Delete says the backups inside the prefix go too")
    func deleteNamesTheBackups() {
        #expect(PrefixPrompt.deleteMessage([agent], backups: 0) == PrefixPrompt.deleteMessage([agent]))
        #expect(PrefixPrompt.deleteMessage([agent], backups: 1).hasPrefix("Saves and 1 backup go too."))
        #expect(PrefixPrompt.deleteMessage([agent, ikaruga], backups: 3).hasPrefix("Saves and 3 backups go too."))
    }

    // Asked only when the Trash refused, so it must say nothing went yet and what is at stake.
    @Test("The no-Trash prompt says nothing was deleted, the size, and that saves go")
    func deletePermanentlyPrompt() {
        #expect(PrefixPrompt.deletePermanentlyTitle(prefixes: [agent], backups: []) == "This drive has no Trash")
        #expect(PrefixPrompt.deletePermanentlyTitle(prefixes: [agent, ikaruga], backups: []) == "These drives have no Trash")
        let message = PrefixPrompt.deletePermanentlyMessage(bytes: 2_000_000_000, prefixes: 1)
        #expect(message.hasPrefix("Nothing deleted yet."))
        #expect(message.contains(Int64(2_000_000_000).formatted(.byteCount(style: .file))))
        #expect(message.contains("Saves and backups will be lost."))
        #expect(!PrefixPrompt.deletePermanentlyMessage(bytes: nil, prefixes: 0).contains("Saves"))
    }

    @Test("Back Up says the size and where the copy goes once measured")
    func backUpNamesSizeAndPlace() {
        #expect(PrefixPrompt.backUpMessage([agent]) == "The copy stays beside the prefix.")
        let one = PrefixPrompt.backUpMessage([agent], bytes: 1_000_000)
        #expect(one.contains(agent.library.displayName))
        #expect(one.contains(Int64(1_000_000).formatted(.byteCount(style: .file))))
    }

    // Rebuild inits the prefix itself before the dialog closes, so deferring to Steam
    // would be describing something that does not happen.
    @Test("Rebuild does not claim Steam makes the prefix again")
    func rebuildDescribesItself() {
        let message = PrefixPrompt.rebuildMessage()
        #expect(PrefixPrompt.rebuildTitle([ikaruga]) == "Rebuild prefix for IKARUGA?")
        #expect(PrefixPrompt.rebuildButton([ikaruga]) == "Rebuild Prefix")
        #expect(message.contains("Rosetta/FEX"))
        #expect(message.contains("Saves are kept."))
        #expect(!message.contains("Steam"))
        #expect(!message.contains("Continue"))
    }

    // A queued rebuild asks once for the whole selection, so it counts too.
    @Test("A rebuild of several prefixes counts them instead of naming one")
    func rebuildCountsTheSelection() {
        #expect(PrefixPrompt.rebuildTitle([agent, ikaruga]) == "Rebuild 2 prefixes?")
        #expect(PrefixPrompt.rebuildButton([agent, ikaruga]) == "Rebuild 2 Prefixes")
        #expect(!PrefixPrompt.rebuildTitle([agent, ikaruga]).contains("Agent 64"))

        // The menu bar item keeps its label while greyed out with nothing selected.
        #expect(PrefixPrompt.rebuildTitle([]) == "Rebuild prefix?")
        #expect(PrefixPrompt.rebuildButton([]) == "Rebuild Prefix")
    }
    @Test("The backup prompt names the game for one and the count for many")
    func deleteBackupsPromptCounts() {
        let one = backup(of: ikaruga, stamp: "20260101-120000")
        let two = backup(of: ikaruga, stamp: "20260102-133000")

        #expect(PrefixPrompt.deleteBackupsTitle([]) == "Move backup to Trash?")
        #expect(PrefixPrompt.deleteBackupsTitle([one]) == "Move backup for IKARUGA to Trash?")
        #expect(PrefixPrompt.deleteBackupsTitle([one, two]) == "Move 2 backups to Trash?")
        #expect(PrefixPrompt.deleteBackupsButton([one]) == "Move to Trash")
        #expect(PrefixPrompt.deleteBackupsButton([one, two]) == "Move 2 to Trash")
    }

    @Test("The rebuild prompt offers the backup choice and counts both ways")
    func rebuildOffersTheBackupChoice() {
        let targets = [agent, ikaruga, orphan]

        #expect(PrefixPrompt.rebuildWithBackupButton([agent]) == "Back Up and Rebuild")
        #expect(PrefixPrompt.rebuildWithoutBackupButton([agent]) == "Rebuild Without Backup")
        #expect(PrefixPrompt.rebuildWithBackupButton(targets) == "Back Up and Rebuild 3")
        #expect(PrefixPrompt.rebuildWithoutBackupButton(targets) == "Rebuild 3 Without Backup")
    }

    @Test("Backing up names the game for one and counts many")
    func backUpPromptCounts() {
        let targets = [agent, ikaruga, orphan]

        #expect(PrefixPrompt.backUpTitle([]) == "Back up prefix?")
        #expect(PrefixPrompt.backUpTitle([agent]) == "Back up prefix for Agent 64: Spies Never Die?")
        #expect(PrefixPrompt.backUpTitle(targets) == "Back up 3 prefixes?")

        #expect(PrefixPrompt.backUpButton([agent]) == "Back Up Prefix")
        #expect(PrefixPrompt.backUpButton(targets) == "Back Up 3 Prefixes")

        #expect(PrefixPrompt.backUpMessage([agent]) == "The copy stays beside the prefix.")
        #expect(PrefixPrompt.backUpMessage(targets) == "Each copy stays beside its prefix.")
    }

    private func backup(of prefix: WinePrefix, stamp: String) -> PrefixBackup {
        PrefixBackup(
            prefix: prefix,
            url: prefix.root.appending(path: "pfx.previous-\(stamp)"),
            taken: PrefixStore.backupClock().date(from: stamp),
            bytes: 1024
        )
    }

    @Test("The backup prompt says how to undo it")
    func deleteBackupsPromptReassures() {
        let one = backup(of: ikaruga, stamp: "20260101-120000")
        let two = backup(of: ikaruga, stamp: "20260102-133000")

        #expect(PrefixPrompt.deleteBackupsMessage([one]) == "Undo with Put Back in the Trash.")
        #expect(PrefixPrompt.deleteBackupsMessage([one, two]) == PrefixPrompt.deleteBackupsMessage([one]))
    }
}
