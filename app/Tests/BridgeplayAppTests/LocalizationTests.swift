import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Localization")
struct LocalizationTests {
    let chinese = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Chinese text is looked up with interpolated values in place")
    func chineseLookup() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Status", bundle: zh) == "状态")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: zh) == "删除 3 个游戏容器？")
    }

    @Test("Chinese text can put interpolated values in another order")
    func chineseReorders() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: zh)
            == "已在“Zuma Deluxe”中打开Wine Configuration。")
    }

    let italian = Bundle.module.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Italian text is looked up with interpolated values in place")
    func italianLookup() throws {
        let it = try #require(italian)
        #expect(String(localized: "Status", bundle: it) == "Stato")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: it) == "Eliminare 3 prefissi?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: it)
            == "Aperto Wine Configuration in Zuma Deluxe.")
    }

    let russian = Bundle.module.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Russian text is looked up with interpolated values in place")
    func russianLookup() throws {
        let ru = try #require(russian)
        #expect(String(localized: "Status", bundle: ru) == "Статус")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: ru) == "Удалить префиксы (3)?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: ru)
            == "Wine Configuration открыт в Zuma Deluxe.")
    }

    // l10ncheck keeps every catalogued string translated, so the fallback is shown with a
    // string the catalog does not have.
    @Test("A string without a translation shows English")
    func missingTranslationFallsBack() throws {
        let zh = try #require(chinese)
        let it = try #require(italian)
        #expect(String(localized: "Not in the string catalog", bundle: zh) == "Not in the string catalog")
        #expect(String(localized: "The trial version is not supported.", bundle: zh) == "不支持试用版。")
        #expect(String(localized: "The trial version is not supported.", bundle: it)
            == "La versione di prova non è supportata.")
    }
}
