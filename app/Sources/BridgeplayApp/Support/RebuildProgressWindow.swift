import AppKit

// A rebuild started from Play runs while Steam shows the game as running, with nothing
// else on screen saying why it has not started. The Compatibility page shows its own
// progress, so only the run script asks for this.
enum RebuildProgressCommand {
    static let environmentKey = "NOTPROTON_REBUILD_WINDOW"

    static var requested: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    // Never returns. The rebuild runs off the main thread, which AppKit needs for the window.
    static func run(_ arguments: [String]) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let window = ProgressPanel(title: String(localized: "Rebuilding the prefix"))
            window.show(game: nil, phase: .settingUp)
            DispatchQueue.main.async { MainActor.assumeIsolated { window.present() } }
            Thread.detachNewThread {
                var code: Int32 = 0
                do {
                    try RebuildPrefixCommand.run(arguments, observe: { name, phase in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { window.show(game: name, phase: phase) }
                        }
                    })
                } catch {
                    AppLog.note("rebuild prefix failed: \(error.localizedDescription)")
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    code = 1
                }
                DispatchQueue.main.async { exit(AppLog.finished(code)) }
            }
            app.run()
        }
        exit(1)
    }
}

// Laid out like the alert that asked for the rebuild, so the one reads as following the other.
// The launch progress uses it too, without activating, so the keyboard stays with Steam.
@MainActor
final class ProgressPanel {
    private static let width: CGFloat = 440
    private static let textWidth: CGFloat = width - 20 - 64 - 16 - 20

    let panel: NSPanel
    private let activates: Bool
    private var placed = false
    private let message = NSTextField(wrappingLabelWithString: "")
    private let phase = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()

    init(title: String, activates: Bool = true) {
        self.activates = activates
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: activates ? [.titled] : [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // macOS may refuse to activate a background helper while Steam is in front, and a
        // panel that hides on deactivate then never shows.
        panel.hidesOnDeactivate = false
        if !activates {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.preferredMaxLayoutWidth = Self.textWidth
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.cell?.truncatesLastVisibleLine = true
        phase.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        phase.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.textWidth
        note.isHidden = true
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)

        let text = NSStackView(views: [message, bar, phase, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.setCustomSpacing(12, after: message)
        text.detachesHiddenViews = true
        let content = NSView()
        for view in [icon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            message.widthAnchor.constraint(equalTo: text.widthAnchor),
            note.widthAnchor.constraint(equalTo: text.widthAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: 20),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 20),
        ])
        panel.contentView = content
    }

    // Ordering the panel front before the application has finished launching leaves it
    // off screen, so this waits for the run loop.
    func present() {
        if !placed {
            // Top right, where notifications show, so a panel that does not activate stays clear
            // of the dialogs Steam centers in its window, such as Exit game.
            if activates {
                panel.center()
            } else if let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - 16))
            }
            placed = true
        }
        panel.orderFrontRegardless()
        if activates { NSApp.activate() }
    }

    func show(message text: String, phase current: String, note detail: String? = nil) {
        message.stringValue = text
        phase.stringValue = current
        note.stringValue = detail ?? ""
        note.isHidden = detail == nil
        bar.setAccessibilityLabel(current)
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    func show(game name: String?, phase current: RebuildPhase) {
        let text = name.map { String(localized: "Bridgeplay is rebuilding the prefix for \($0).") }
            ?? String(localized: "Bridgeplay is rebuilding this game's prefix.")
        let step = switch current {
        case .settingUp: String(localized: "Rebuilding…")
        case .copying: String(localized: "Copying your files…")
        case .finishing: String(localized: "Finishing…")
        }
        show(message: text, phase: step)
    }
}
