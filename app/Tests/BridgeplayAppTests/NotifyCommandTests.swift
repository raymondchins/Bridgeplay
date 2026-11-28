import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Notify command")
struct NotifyCommandTests {
    let russian = Bundle.module.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))
    let english = Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("The Steam start notification shows in the player's language")
    func breakerTranslated() throws {
        let ru = try #require(russian)
        let text = NotifyCommand.text([
            "Bridgeplay", "Steam opened without Bridgeplay",
            "Steam stopped twice soon after starting, so it opens without Bridgeplay until Steam or Bridgeplay updates. Open Bridgeplay to try again.",
        ], bundle: ru)
        #expect(text.title == "Bridgeplay")
        #expect(text.subtitle == "Steam открылся без Bridgeplay")
        #expect(text.body.hasPrefix("Steam дважды закрылся"))
    }

    @Test("Text the run script already translated, or that is no key, shows as it is")
    func passesThrough() throws {
        let ru = try #require(russian)
        let text = NotifyCommand.text(["Bridgeplay", "Включён режим энергосбережения", "Some", "words"], bundle: ru)
        #expect(text.subtitle == "Включён режим энергосбережения")
        #expect(text.body == "Some words")
        #expect(NotifyCommand.text(["Bridgeplay", "Only a body"], bundle: ru) == ("Bridgeplay", "", "Only a body"))
    }

    @Test("English stays English")
    func englishStays() throws {
        let en = english ?? Bundle.module
        #expect(NotifyCommand.text(["Bridgeplay", "Steam opened without Bridgeplay", "b"], bundle: en).subtitle
            == "Steam opened without Bridgeplay")
    }
}
