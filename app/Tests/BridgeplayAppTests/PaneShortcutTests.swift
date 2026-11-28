import SwiftUI
import Testing

@testable import BridgeplayApp

@Suite("Page shortcuts")
struct PaneShortcutTests {

    @Test("⌘1 to ⌘6 follow the sidebar's order")
    func followSidebar() {
        #expect(Pane.allCases == [.status, .games, .gameDefaults, .prefixes, .backups, .guide])
        #expect(Pane.allCases.map(\.shortcut.character) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test("The View menu builds its shortcuts from the sidebar's pages")
    func menuUsesPaneOrder() throws {
        let source = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().appending(path: "../../Sources/BridgeplayApp/App.swift"), encoding: .utf8)
        #expect(source.contains(".keyboardShortcut(item.shortcut, modifiers: .command)"))
        #expect(!source.contains(#".keyboardShortcut("2", modifiers: .command)"#))
    }
}
