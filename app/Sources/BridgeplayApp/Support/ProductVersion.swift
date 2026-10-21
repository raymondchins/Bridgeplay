// Bridgeplay's version as make app stamps it from dylib/version.h

import AppKit
import Foundation

enum ProductVersion {

    // CFBundleShortVersionString: Bridgeplay semver, the same string recorded as the
    // installed build in Steam.
    static var short: String { AppVersion.display }

    // CFBundleVersion: the release counter Sparkle orders updates by.
    static var build: String? { stamped(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")) }

    // The NotProton release this build is based on.
    static var upstream: String? { stamped(Bundle.main.object(forInfoDictionaryKey: "NotProtonVersion")) }

    static var display: String { display(short: short, build: build, upstream: upstream) }

    // "Bridgeplay 2.0.0 (32) · based on NotProton 1.2.0"
    static func display(short: String, build: String?, upstream: String?) -> String {
        var text = "Bridgeplay \(short)"
        if let build { text += " (\(build))" }
        if let upstream { text += " · based on NotProton \(upstream)" }
        return text
    }

    // app/Info.plist carries placeholders that only make app replaces.
    private static func stamped(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text != "0", text != "0.0.0" else { return nil }
        return text
    }
}

@MainActor
enum AboutPanel {

    // The standard panel already reads "Version 2.0.0 (32)"; the credits line adds the
    // upstream release.
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let upstream = ProductVersion.upstream {
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            options[.credits] = NSAttributedString(
                string: "Based on NotProton \(upstream)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: centered,
                ]
            )
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }
}
