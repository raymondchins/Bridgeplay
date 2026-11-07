import Foundation
import Testing

@testable import BridgeplayApp

@Suite("CrossOver rows on the Status pane")
struct CrossOverRowTests {

    private static let preview = SupportedRunners.all.first { $0.flavor == "fex" }!
    private static let release = SupportedRunners.all.first { $0.id == "26.3.0.39832" }!
    private static let old = CrossOverInstall(
        bundle: URL(filePath: "/Applications/CrossOver 24.app"), releaseVersion: "24.0.5",
        support: .unsupportedBuild("24.0.5")
    )

    private func install(_ name: String, _ build: RunnerBuild, root: String = "/Applications") -> CrossOverInstall {
        CrossOverInstall(bundle: URL(filePath: "\(root)/\(name).app"), releaseVersion: "x", support: .supported(build))
    }

    private func rows(
        _ installs: [CrossOverInstall],
        installed: [RunnerBuild] = [],
        damaged: [String] = [],
        orphaned: [String] = [],
        unpatched: [String] = [],
        unlicensed: Set<String> = []
    ) -> [CrossOverRow] {
        var licenses: [String: CrossOverLicense.Status] = [:]
        for install in installs {
            licenses[install.id] = CrossOverLicense.Status(
                licensed: !unlicensed.contains(install.id), detail: "", diagnostic: "test"
            )
        }
        return CrossOverRow.rows(
            installs: installs, licenses: licenses, installed: installed,
            damaged: damaged, orphaned: orphaned, unpatched: unpatched
        )
    }

    @Test("Each app gets its own row, tied to its own build")
    func oneRowPerApp() {
        let preview = install("CrossOver Preview", Self.preview)
        let release = install("CrossOver", Self.release)

        let made = rows([preview, release], installed: [Self.preview, Self.release])

        #expect(made.map(\.install?.id) == [preview.id, release.id])
        #expect(made.map(\.buildID) == [Self.preview.id, Self.release.id])
        #expect(made.allSatisfy { $0.copy == .ready && $0.canSetUp })
    }

    @Test("An app with no copy yet can be set up, and its license shows on the row")
    func appWithoutCopy() {
        let release = install("CrossOver", Self.release)

        let made = rows([release], unlicensed: [release.id])

        #expect(made.count == 1)
        #expect(made[0].copy == .none)
        #expect(made[0].licensed == false)
        #expect(made[0].canSetUp)
    }

    @Test("A copy whose app is gone keeps a row that cannot be recopied")
    func copyWithoutApp() {
        let made = rows([], installed: [Self.release])

        #expect(made.count == 1)
        #expect(made[0].install == nil)
        #expect(made[0].copy == .ready)
        #expect(!made[0].canSetUp)
        #expect(made[0].title == "CrossOver \(Self.release.displayVersion)")
    }

    @Test("Damaged, unpatched and unsupported copies are marked on their own rows")
    func problemCopies() {
        let preview = install("CrossOver Preview", Self.preview)
        let release = install("CrossOver", Self.release)

        let made = rows(
            [preview, release], installed: [Self.preview], damaged: [Self.release.id],
            orphaned: ["25.0.0.1"], unpatched: [Self.preview.id]
        )

        #expect(made.map(\.copy) == [.unpatched, .damaged, .unsupported])
        #expect(made[2].buildID == "25.0.0.1")
        #expect(made[2].install == nil)
    }

    @Test("Two apps of the same build share one row, the preferred one")
    func sameBuildTwice() {
        let first = install("CrossOver", Self.release)
        let second = install("CrossOver", Self.release, root: "/Volumes/Spare")

        let made = rows([first, second], installed: [Self.release])

        #expect(made.map(\.install?.id) == [first.id])
    }

    @Test("A picked copy is found under the row for its path or its build")
    func pickedCopyListing() {
        let first = install("CrossOver", Self.release)
        let second = install("CrossOver", Self.release, root: "/Volumes/Spare")
        let preview = install("CrossOver Preview", Self.preview, root: "/Volumes/Spare")

        let made = rows([first], installed: [Self.release, Self.preview])

        #expect(CrossOverRow.listing(first, in: made)?.id == first.id)
        #expect(CrossOverRow.listing(second, in: made)?.id == first.id)
        #expect(CrossOverRow.listing(preview, in: made) == nil)

        let swapped = install("CrossOver", Self.preview)
        #expect(CrossOverRow.listing(swapped, in: made) == nil)

        #expect(CrossOverRow.listing(Self.old, in: rows([Self.old]))?.id == Self.old.id)
        #expect(CrossOverRow.listing(Self.old, in: made) == nil)
    }

    @Test("An app Bridgeplay doesn't support is listed with its version and nothing to set up")
    func unsupportedApp() {
        let made = rows([Self.old])

        #expect(made.count == 1)
        #expect(made[0].unsupportedVersion == "24.0.5")
        #expect(!made[0].canSetUp)
    }

    @Test("Free engines are told apart from CrossOver, so CrossOver can be listed first")
    func freeEnginesApart() throws {
        let winecx = try #require(SupportedRunners.all.first { $0.bundleVersion.hasPrefix("winecx-") })
        let engine = install("WineCX", winecx, root: SupportPaths.engines.path(percentEncoded: false))
        let release = install("CrossOver", Self.release)
        let odd = CrossOverInstall(
            bundle: SupportPaths.engines.appending(path: "WineHQ 9.0.app"), releaseVersion: "9.0",
            support: .unsupportedBuild("9.0"), isEngine: true
        )
        let made = rows([engine, release, odd, Self.old], orphaned: ["winehq-10.0", "25.0.0.1"])
        #expect(made.map(\.isFreeEngine) == [true, false, true, false, true, false])

        // CrossOver stays CrossOver wherever its app is, supported or not.
        var moved = install("CrossOver", Self.release, root: SupportPaths.engines.path(percentEncoded: false))
        moved.isEngine = true
        let oldMoved = CrossOverInstall(
            bundle: SupportPaths.engines.appending(path: "CrossOver 24.app"), releaseVersion: "24.0.5",
            support: .unsupportedBuild("24.0.5"), isEngine: true
        )
        #expect(rows([moved, oldMoved]).map(\.isFreeEngine) == [false, false])

        let copies = rows([], installed: [winecx, Self.release])
        #expect(copies.map(\.isFreeEngine) == [true, false])
    }

    @Test("Each kind of engine is pointed at its own supported versions")
    func crossOverVersions() {
        let named = SupportedRunners.crossOverVersions

        #expect(named.hasPrefix(Self.release.releaseVersion))
        #expect(named.contains("Preview \(Self.preview.releaseVersion)"))
        #expect(!named.contains("Wine"))
        let previews = SupportedRunners.all.filter(\.isPreview)
        #expect(!previews.isEmpty && previews.allSatisfy { !$0.isFree })

        let free = SupportedRunners.freeEngineVersions
        #expect(free.contains("WineHQ") && free.contains("WineCX") && !free.contains("Preview"))
    }
}

@Suite("Manually added CrossOver copies")
struct ManualCrossOverTests {

    @Test("The single copy 1.0 remembered carries over as the first entry")
    func legacyChoiceCarriesOver() {
        let defaults = scratchDefaults()
        defaults.set("/Volumes/Spare/CrossOver.app", forKey: "manualCrossOverPath")

        #expect(CrossOverSource.manualBundles(defaults).map { $0.path(percentEncoded: false) }
            == ["/Volumes/Spare/CrossOver.app/"])

        CrossOverSource.addManualBundle(URL(filePath: "/Volumes/Other/CrossOver.app"), defaults)

        #expect(CrossOverSource.manualBundles(defaults).count == 2)
        #expect(defaults.string(forKey: "manualCrossOverPath") == nil)
    }

    @Test("Adding keeps earlier copies, skips repeats, and removing drops only the one named")
    func addAndRemove() {
        let defaults = scratchDefaults()
        let spare = URL(filePath: "/Volumes/Spare/CrossOver.app", directoryHint: .isDirectory)
        let other = URL(filePath: "/Volumes/Other/CrossOver Preview.app", directoryHint: .isDirectory)

        CrossOverSource.addManualBundle(spare, defaults)
        CrossOverSource.addManualBundle(other, defaults)
        CrossOverSource.addManualBundle(spare, defaults)
        #expect(CrossOverSource.manualBundles(defaults) == [spare, other])

        CrossOverSource.removeManualBundle(spare, defaults)
        #expect(CrossOverSource.manualBundles(defaults) == [other])
    }

    @Test("A remembered copy in a folder the search covers is not treated as added by hand")
    func searchedFolderIsNotManual() {
        #expect(CrossOverSource.isSearched(URL(filePath: "/Applications/CrossOver.app/")))
        #expect(CrossOverSource.isSearched(URL(filePath: "/Applications/CrossOver.app")))
        #expect(!CrossOverSource.isSearched(URL(filePath: "/Volumes/Spare/CrossOver.app")))
        #expect(!CrossOverSource.isSearched(URL(filePath: "/Applications/Games/CrossOver.app")))
    }
}
