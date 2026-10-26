import AppKit
import SwiftUI
import Testing

@testable import BridgeplayApp

// Renders the Setup Assistant's steps and the Status page to PNGs for review when
// NOTPROTON_SNAPSHOTS names an output folder. Reads this Mac's state without changing it.
@Suite("Setup Assistant snapshots", .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_SNAPSHOTS"] != nil))
@MainActor
struct SetupAssistantSnapshots {

    private let out = URL(filePath: ProcessInfo.processInfo.environment["NOTPROTON_SNAPSHOTS"] ?? "/tmp", directoryHint: .isDirectory)

    private func render(_ view: some View, _ name: String, size: CGSize, status: SystemStatus, chrome: NSWindow.StyleMask = [.borderless]) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(status).environment(PrefixesModel()))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: chrome,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        window.displayIfNeeded()
        let bounds = try #require(window.contentView?.superview).bounds
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: rep)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appending(path: "\(name).png"))
    }

    private func wizard(_ name: String, status: SystemStatus = SystemStatus(), revealed: Int = .max,
                        _ configure: (SetupAssistant) -> Void) throws {
        let model = SetupAssistant()
        configure(model)
        try render(SetupAssistantView(model: model, revealed: revealed), name, size: CGSize(width: 780, height: 580), status: status)
    }

    // Frames of the check wave and of Set Up progressing, stitched into GIFs for review.
    @Test func motionFrames() throws {
        for step in 0...4 {
            try wizard("frames/wave-\(step)", revealed: step) { $0.step = .mac; $0.rosettaInstalled = false }
        }
        let states: [[SetupAssistant.TaskState]] = [
            [.running, .waiting, .waiting], [.done, .running, .waiting], [.done, .done, .running], [.done, .done, .done],
        ]
        for (index, row) in states.enumerated() {
            let busy = SystemStatus()
            busy.activity = ["Stopping Steam", "Unpacking WineCX 11.17", "Writing config.vdf", nil][index]
            try wizard("frames/setup-\(index)", status: busy) { m in
                m.step = .finish
                for (i, state) in row.enumerated() { m.tasks[i].state = state }
            }
        }
    }

    @Test func steps() throws {
        try wizard("2-wizard-1-mac") { $0.step = .mac; $0.rosettaInstalled = false }
        try wizard("2-wizard-2-graphics") { m in
            m.step = .graphics; m.gptk = nil
            m.gptkImages = [URL(filePath: "/Users/you/Downloads/Game_Porting_Toolkit_4.0_beta_2.dmg")]
        }
        try wizard("2-wizard-3-steam") { $0.step = .steam; $0.steamInstalled = true; $0.signedIn = false }
        let busy = SystemStatus()
        busy.activity = "Unpacking WineCX 11.17"
        try wizard("2-wizard-4-setup", status: busy) { m in
            m.step = .finish
            m.tasks[0].state = .done
            m.tasks[1].state = .running
        }
        try wizard("2-wizard-4b-permission") { m in
            m.step = .finish
            m.tasks[0].state = .failed("macOS needs your permission first.")
            m.needsAppManagement = true
        }
        try wizard("2-wizard-4c-repair") { m in
            m.step = .finish
            m.tasks[0].state = .failed("Cartouche is already set up in Steam.")
            m.needsSteamRepair = "Cartouche"
        }
        try wizard("2-wizard-5-done") { $0.step = .done }
    }

    @Test func statusPage() throws {
        let status = SystemStatus()
        status.snapshot = StatusSnapshot.capture(bundledVersion: AppVersion.bundled)
        // The test build carries no payload; the installed app reports its files as current.
        status.snapshot?.installContent = .current
        try render(RootView(pane: .constant(.status)), "1-bridgeplay-status", size: CGSize(width: 900, height: 900), status: status,
                   chrome: [.titled, .fullSizeContentView])
    }
}
