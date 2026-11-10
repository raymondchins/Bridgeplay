#if DEBUG
import AppKit
import BridgeplayUI
import SwiftUI

// Debug builds only: `.build/debug/BridgeplayApp --setup-preview [--fresh]` opens the Setup
// Assistant by itself for design review, then the main window once it closes. The assistant
// reads this Mac's state and only pretends to act (--fresh shows a Mac that still needs
// setup; --main skips straight to the main window; --run presses the step's button, so its
// progress can be captured; --pause then pauses its download after three seconds). The main window is the real one: its
// buttons do what they do in the app.
struct SetupPreviewApp: App {
    static let flag = "--setup-preview"

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    // --pane gameDefaults opens the main window on that page.
    @State private var pane: Pane = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--pane"), index + 1 < arguments.count else { return .status }
        return Pane(rawValue: arguments[index + 1]) ?? .status
    }()
    private static let mainFirst = CommandLine.arguments.contains("--main")
        && !CommandLine.arguments.contains("--skeleton")
    private let preview: SetupAssistant.Preview =
        CommandLine.arguments.contains("--fresh") ? .fresh : .thisMac
    // --step 4 opens on Set Up; numbers match the wizard's "Step N of 5".
    private static let start: SetupAssistant.Step = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--step"), index + 1 < arguments.count,
              let number = Int(arguments[index + 1]),
              let step = SetupAssistant.Step(rawValue: number - 1) else { return .mac }
        return step
    }()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
        WindowMirror.startIfAsked()
    }

    var body: some Scene {
        Window("Bridgeplay Setup", id: "setup-preview") {
            PreviewWizard(preview: preview, start: Self.start)
                .environment(status)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.mainFirst || CommandLine.arguments.contains("--skeleton") ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // --skeleton shows the loading placeholders alone, for design review.
        Window("Bridgeplay Loading", id: "skeleton-preview") {
            HStack(spacing: 0) {
                SkeletonPage(label: "Checking").frame(width: 520)
                Rectangle().fill(BP.line).frame(width: 1)
                SkeletonTable(label: "Looking for prefixes")
            }
            .background(BP.bg)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--skeleton") ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Bridgeplay", id: "main-preview") {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 800, minHeight: 600)
                // --cycle-panes switches page every 1.5 s, for profiling page changes
                .task {
                    guard CommandLine.arguments.contains("--cycle-panes") else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1.5))
                        let all = Pane.allCases
                        pane = all[((all.firstIndex(of: pane) ?? 0) + 1) % all.count]
                    }
                }
        }
        .defaultSize(width: 900, height: 760)
        .defaultLaunchBehavior(Self.mainFirst ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bridgeplay") { AboutPanel.show() }
            }
        }
    }
}

// --mirror <file.png> writes the key window's pixels to that file every second, so a browser
// page can show the preview without Screen Recording permission (the app draws its own window).
private enum WindowMirror {
    static func startIfAsked() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--mirror"), index + 1 < arguments.count else { return }
        let out = URL(fileURLWithPath: arguments[index + 1])
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { write(to: out) }
        }
    }

    @MainActor private static func write(to out: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 300 }) else { return }
        // A process may read its own windows' pixels without Screen Recording permission.
        // The SDK marks CGWindowListCreateImage unavailable; CoreGraphics still exports it.
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: Create.self)
        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        guard let image = create(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                 UInt32(window.windowNumber), options)?.takeRetainedValue() else { return }
        // Encoding takes ~20 ms; keep it off the main thread so clicks never wait on it.
        DispatchQueue.global(qos: .utility).async {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let temp = out.appendingPathExtension("tmp")
            try? png.write(to: temp)
            _ = try? FileManager.default.replaceItemAt(out, withItemAt: temp)
        }
    }
}

private struct PreviewWizard: View {
    @State private var model: SetupAssistant
    private let start: SetupAssistant.Step
    @Environment(SystemStatus.self) private var status
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(preview: SetupAssistant.Preview, start: SetupAssistant.Step) {
        _model = State(initialValue: SetupAssistant(preview: preview, startAt: start))
        self.start = start
    }

    var body: some View {
        SetupAssistantView(model: model) {
            openWindow(id: "main-preview")
            dismissWindow(id: "setup-preview")
        }
        .task {
            guard CommandLine.arguments.contains("--run") else { return }
            if CommandLine.arguments.contains("--pause") {
                Task { try? await Task.sleep(for: .seconds(3)); DownloadMeter.shared.togglePause() }
            }
            switch start {
            case .steam: model.steamInstalled = false; await model.installSteam()
            case .finish: await model.finish(with: status)
            default: break
            }
        }
    }
}
#endif
