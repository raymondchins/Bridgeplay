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
        #expect(PrefixPrompt.deleteTitle([agent]) == "Delete the prefix for Agent 64: Spies Never Die?")
        #expect(PrefixPrompt.deleteButton([agent]) == "Delete Prefix")
        // A prefix whose game is gone still has to be askable about.
        #expect(PrefixPrompt.deleteTitle([orphan]) == "Delete the prefix for App 1649240?")
    }

    // The Prefix menu shows the delete item greyed out with nothing selected, and it shows
    // it by name, so an empty selection has to read as an action rather than as a count.
    @Test("With nothing selected the delete item still reads as an action")
    func emptySelectionReadsAsTheAction() {
        #expect(PrefixPrompt.deleteButton([]) == "Delete Prefix")
        #expect(PrefixPrompt.deleteTitle([]) == "Delete prefix?")
    }

    // Naming one of them and deleting all of them is how the wrong prefix gets thrown
    // away, so more than one is counted instead.
    @Test("Several prefixes are counted, not named")
    func multipleDeleteCountsThem() {
        let targets = [agent, ikaruga, orphan]
        #expect(PrefixPrompt.deleteTitle(targets) == "Delete 3 prefixes?")
        #expect(PrefixPrompt.deleteButton(targets) == "Delete 3 Prefixes")
    }

    @Test("Delete says the save data goes and asks for confirmation")
    func deleteSaysSavesAreLost() {
        let one = PrefixPrompt.deleteMessage([agent])
        #expect(one == "This will DELETE the game's prefix. The game SAVE DATA inside the"
            + " prefix WILL BE LOST. Are you sure you want to do this?")

        let both = PrefixPrompt.deleteMessage([agent, ikaruga])
        #expect(both == "This will DELETE the prefixes for 2 games. The game SAVE DATA inside"
            + " them WILL BE LOST. Are you sure you want to do this?")
        #expect(!both.contains("Agent 64"))
    }

    @Test("Delete warns that the backups inside the prefix go too")
    func deleteNamesTheBackups() {
        #expect(PrefixPrompt.deleteMessage([agent], backups: 0) == PrefixPrompt.deleteMessage([agent]))
        #expect(PrefixPrompt.deleteMessage([agent], backups: 1).contains("Its 1 backup will also be permanently deleted."))
        #expect(PrefixPrompt.deleteMessage([agent, ikaruga], backups: 3).contains("All 3 backups will also be permanently deleted."))
    }

    // Rebuild inits the prefix itself before the dialog closes, so deferring to Steam
    // would be describing something that does not happen.
    @Test("Rebuild does not claim Steam makes the prefix again")
    func rebuildDescribesItself() {
        let message = PrefixPrompt.rebuildMessage()
        #expect(PrefixPrompt.rebuildTitle([ikaruga]) == "Rebuild the prefix for IKARUGA?")
        #expect(PrefixPrompt.rebuildButton([ikaruga]) == "Rebuild Prefix")
        #expect(message.contains("switching between Rosetta/FEX CrossOver"))
        #expect(message.contains("You will not lose saves by using this tool."))
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

        #expect(PrefixPrompt.deleteBackupsTitle([]) == "Delete backup?")
        #expect(PrefixPrompt.deleteBackupsTitle([one]) == "Delete the backup for IKARUGA?")
        #expect(PrefixPrompt.deleteBackupsTitle([one, two]) == "Delete 2 backups?")
        #expect(PrefixPrompt.deleteBackupsButton([one]) == "Delete Backup")
        #expect(PrefixPrompt.deleteBackupsButton([one, two]) == "Delete 2 Backups")
    }

    @Test("The rebuild prompt offers the backup choice and counts both ways")
    func rebuildOffersTheBackupChoice() {
        let targets = [agent, ikaruga, orphan]

        #expect(PrefixPrompt.rebuildWithBackupButton([agent]) == "Back Up and Rebuild")
        #expect(
            PrefixPrompt.rebuildWithoutBackupButton([agent]) == "Rebuild Without Backing Up")
        #expect(
            PrefixPrompt.rebuildWithBackupButton(targets) == "Back Up and Rebuild 3 Prefixes")
        #expect(
            PrefixPrompt.rebuildWithoutBackupButton(targets)
                == "Rebuild 3 Prefixes Without Backing Up")

    }

    @Test("Backing up names the game for one and counts many")
    func backUpPromptCounts() {
        let targets = [agent, ikaruga, orphan]

        #expect(PrefixPrompt.backUpTitle([]) == "Back up prefix?")
        #expect(PrefixPrompt.backUpTitle([agent]) == "Back up the prefix for Agent 64: Spies Never Die?")
        #expect(PrefixPrompt.backUpTitle(targets) == "Back up 3 prefixes?")

        #expect(PrefixPrompt.backUpButton([agent]) == "Back Up Prefix")
        #expect(PrefixPrompt.backUpButton(targets) == "Back Up 3 Prefixes")

        #expect(
            PrefixPrompt.backUpMessage([agent])
                == "Are you sure you want to back up this prefix?")
        #expect(
            PrefixPrompt.backUpMessage(targets)
                == "Are you sure you want to back up these prefixes?")
    }

    private func backup(of prefix: WinePrefix, stamp: String) -> PrefixBackup {
        PrefixBackup(
            prefix: prefix,
            url: prefix.root.appending(path: "pfx.previous-\(stamp)"),
            taken: PrefixStore.backupClock().date(from: stamp),
            bytes: 1024
        )
    }

    @Test("The backup prompt asks once and names what is lost")
    func deleteBackupsPromptReassures() {
        let one = backup(of: ikaruga, stamp: "20260101-120000")
        let two = backup(of: ikaruga, stamp: "20260102-133000")

        #expect(PrefixPrompt.deleteBackupsMessage([one])
            == "Are you sure you want to delete this backup? Any data in it will be lost.")
        #expect(PrefixPrompt.deleteBackupsMessage()
            == "Are you sure you want to delete this backup? Any data in it will be lost.")
        #expect(PrefixPrompt.deleteBackupsMessage([one, two])
            == "Are you sure you want to delete these 2 backups? Any data in them will be lost.")
    }
}
