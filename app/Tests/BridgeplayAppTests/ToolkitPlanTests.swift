import BridgeplayInstallerCore
import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Setup without Apple's toolkit")
struct ToolkitPlanTests {

    private static let payload = WinecxD3DMetal.Payload(libRoot: URL(filePath: "/fixture/gptk"), version: "4.0")

    @Test("A toolkit on this Mac wins; otherwise the last download says why there is none")
    func decide() {
        let attempts: [ToolkitPlan.Attempt] = [.none, .components(.placed), .components(.notInDownload),
                                               .components(.refused("x")), .failed("offline")]
        for attempt in attempts {
            #expect(ToolkitPlan.decide(located: Self.payload, attempt: attempt) == .ready(version: "4.0"))
        }
        #expect(ToolkitPlan.decide(located: nil, attempt: .none) == .without(.notAdded))
        // Placed but not found afterwards (moved, or the 3.0 folder move): not added, no reason to give.
        #expect(ToolkitPlan.decide(located: nil, attempt: .components(.placed)) == .without(.notAdded))
        #expect(ToolkitPlan.decide(located: nil, attempt: .components(.notInDownload)) == .without(.notInDownload))
        #expect(ToolkitPlan.decide(located: nil, attempt: .components(.refused("not signed"))) == .without(.refused))
        #expect(ToolkitPlan.decide(located: nil, attempt: .failed("offline")) == .without(.failed("offline")))
    }

    @Test("Each reason is said plainly, and the download is not offered again when it can't help")
    func wording() {
        #expect(ToolkitPlan.ready(version: nil).message == nil)
        #expect(ToolkitPlan.without(.notAdded).message == nil)
        for reason in [ToolkitPlan.Reason.notInDownload, .refused] {
            #expect(ToolkitPlan.without(reason).message != nil)
            #expect(!ToolkitPlan.without(reason).offersComponentsDownload)
        }
        #expect(ToolkitPlan.without(.notInDownload).message?.contains("DXMT") == true)
        #expect(ToolkitPlan.without(.failed("No internet.")).message?.hasSuffix("No internet.") == true)
        #expect(ToolkitPlan.without(.failed("No internet.")).offersComponentsDownload)
        #expect(ToolkitPlan.without(.notAdded).offersComponentsDownload)
        #expect(ToolkitPlan.withoutNote.contains("DirectX 12"))
        #expect(ToolkitPlan.ready(version: nil).doneValue != ToolkitPlan.without(.notAdded).doneValue)
    }

    @Test("The Setup Assistant reads its plan from the toolkit it found and the last download")
    @MainActor
    func assistant() {
        let model = SetupAssistant(preview: .fresh)
        #expect(model.toolkitPlan == .without(.notAdded))
        model.toolkitAttempt = .components(.notInDownload)
        #expect(model.toolkitPlan == .without(.notInDownload))
        model.gptk = Self.payload
        #expect(model.toolkitPlan.isReady)
    }

    private final class Calls: @unchecked Sendable {
        var scanned = 0, imported: [URL] = [], relinked = 0
    }

    @Test("With no toolkit, Apple's image in Downloads is copied in, then the engine is relinked in place")
    func addFromDownloads() {
        let calls = Calls()
        let image = URL(filePath: "/fixture/Downloads/Game_Porting_Toolkit_4.0.dmg")
        let added = SystemStatus.addGameportingToolkit(
            located: { nil },
            downloads: { calls.scanned += 1; return [image] },
            importImage: { calls.imported.append($0); return Self.payload },
            relink: { calls.relinked += 1; return "/fixture/gptk" })
        #expect(added == SystemStatus.ToolkitAdded(linked: "/fixture/gptk", imported: image, failure: nil))
        #expect(calls.imported == [image] && calls.relinked == 1)
    }

    @Test("A toolkit already here is only relinked, and Downloads is never read")
    func addWhenPresent() {
        let calls = Calls()
        let added = SystemStatus.addGameportingToolkit(
            located: { Self.payload },
            downloads: { calls.scanned += 1; return [] },
            importImage: { calls.imported.append($0); return Self.payload },
            relink: { calls.relinked += 1; return "/fixture/gptk" })
        #expect(added.linked == "/fixture/gptk" && added.imported == nil)
        #expect(calls.scanned == 0 && calls.imported.isEmpty && calls.relinked == 1)
    }

    @Test("A failed copy is reported and the engine still matches what is on disk")
    func addFails() {
        struct Broken: LocalizedError { var errorDescription: String? { "The image has no redist/lib folder." } }
        let calls = Calls()
        let added = SystemStatus.addGameportingToolkit(
            located: { nil },
            downloads: { [URL(filePath: "/fixture/Downloads/Game_Porting_Toolkit_4.0.dmg")] },
            importImage: { _ in throw Broken() },
            relink: { calls.relinked += 1; return nil })
        #expect(added == SystemStatus.ToolkitAdded(linked: nil, imported: nil, failure: "The image has no redist/lib folder."))
        #expect(calls.relinked == 1)
    }

    @Test("Nothing in Downloads and no toolkit: relinked, nothing imported")
    func addNothing() {
        let added = SystemStatus.addGameportingToolkit(located: { nil }, downloads: { [] },
                                                      importImage: { _ in Self.payload }, relink: { nil })
        #expect(added == SystemStatus.ToolkitAdded())
    }
}
