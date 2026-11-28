import BridgeplayInstallerCore
import Foundation

// What Setup does when Apple's Game Porting Toolkit can't be had: it never blocks Setup.
// Without it the WineCX engine runs DXMT and DXVK, and adding the toolkit later links it into
// the installed engine and runner (SystemStatus.relinkGameportingToolkit) without a reinstall.
enum ToolkitPlan: Equatable {
    case ready(version: String?)
    case without(Reason)

    enum Reason: Equatable {
        // Not added yet: nothing tried, or the user skipped it.
        case notAdded
        // Bridgeplay's download carries no toolkit (package-installer.sh --no-gptk).
        case notInDownload
        // The toolkit in the download failed Apple's signature or licence check.
        case refused
        // The download or the copy failed.
        case failed(String)
    }

    // The last attempt to add it through Bridgeplay's download.
    enum Attempt: Equatable {
        case none
        case components(ComponentsToolkit)
        case failed(String)
    }

    // A toolkit on this Mac wins over whatever the last download said.
    static func decide(located: WinecxD3DMetal.Payload?, attempt: Attempt) -> ToolkitPlan {
        if let located { return .ready(version: located.version) }
        switch attempt {
        case .none, .components(.placed): return .without(.notAdded)
        case .components(.notInDownload): return .without(.notInDownload)
        case .components(.refused): return .without(.refused)
        case .failed(let detail): return .without(.failed(detail))
        }
    }

    var isReady: Bool { if case .ready = self { true } else { false } }

    // Bridgeplay's download is worth offering only while it may still bring the toolkit.
    var offersComponentsDownload: Bool {
        switch self {
        case .without(.notInDownload), .without(.refused): false
        default: true
        }
    }

    // Why the toolkit is missing, after a download that didn't bring it; nil when nothing needs saying.
    var message: String? {
        switch self {
        case .ready, .without(.notAdded): nil
        case .without(.notInDownload):
            String(localized: "Not included. DXMT still works.")
        case .without(.refused):
            String(localized: "Failed Apple’s checks.")
        case .without(.failed(let detail)):
            String(localized: "Toolkit not added. \(detail)")
        }
    }

    // What going without it means for games.
    static let withoutNote = String(localized: "Optional. Needed for DirectX 12.")

    var doneValue: String {
        isReady ? String(localized: "Linked.")
            : String(localized: "Skipped. Add it in Status.")
    }
}
