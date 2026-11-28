import Foundation
import ObjectiveC
import SwiftUI

@testable import BridgeplayApp

// NOTPROTON_SNAPSHOT_LANG=ru renders the snapshots in that language. The test runner's main
// bundle has no app strings (the app copies its .lproj folders into Contents/Resources when it
// is packaged), so the main bundle's string lookups are answered from the module bundle's
// folder for that language.
enum SnapshotLanguage {
    static let code: String? = {
        guard let code = ProcessInfo.processInfo.environment["NOTPROTON_SNAPSHOT_LANG"], code != "en" else { return nil }
        return code
    }()

    static var locale: Locale { Locale(identifier: code ?? "en") }

    // What install replaced, for uninstall: Bundle.main's class and this process's own
    // AppleLanguages (nil when it had none).
    @MainActor private static var saved: (bundleClass: AnyClass, languages: Any?)?
    private static let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

    // Swaps Bundle.main's class for the language's and sets AppleLanguages, until uninstall.
    // Other suites share the process, so call uninstall as soon as the snapshot is taken.
    @MainActor static func install() {
        guard saved == nil, let code, let subclass = languageClass else { return }
        let defaults = UserDefaults.standard
        saved = (object_getClass(Bundle.main)!, defaults.persistentDomain(forName: defaultsDomain)?["AppleLanguages"])
        defaults.set([code], forKey: "AppleLanguages")
        object_setClass(Bundle.main, subclass)
    }

    @MainActor static func uninstall() {
        guard let saved else { return }
        self.saved = nil
        object_setClass(Bundle.main, saved.bundleClass)
        if let languages = saved.languages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    // Made once: objc_allocateClassPair returns nil for a class name already taken.
    @MainActor private static let languageClass: AnyClass? = {
        guard let code,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let strings = Bundle(path: path) else { return nil }
        let main: AnyClass = object_getClass(Bundle.main)!
        let subclass: AnyClass = objc_allocateClassPair(main, "BPSnapshotMainBundle", 0)!

        // Every lookup Foundation and SwiftUI make on a bundle, each answered by the same
        // method on the language's bundle.
        typealias Three = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        typealias Four = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        typealias FiveFlag = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool) -> AnyObject?
        typealias Six = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        func forward(_ name: String, _ make: (IMP, Selector) -> AnyObject) {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(Bundle.self, selector) else { return }
            let original = method_getImplementation(method)
            class_addMethod(subclass, selector, imp_implementationWithBlock(make(original, selector)), method_getTypeEncoding(method))
        }
        for name in ["localizedStringForKey:value:table:", "localizedAttributedStringForKey:value:table:"] {
            forward(name) { imp, sel in
                let f = unsafeBitCast(imp, to: Three.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = { _, a, b, c in f(strings, sel, a, b, c) }
                return block as AnyObject
            }
        }
        for name in ["localizedStringForKey:value:table:localization:", "localizedStringForKey:value:table:localizations:",
                     "_localizedStringForKey:value:table:localizations:", "localizedAttributedStringForKey:value:table:localization:"] {
            forward(name) { imp, sel in
                let f = unsafeBitCast(imp, to: Four.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = { _, a, b, c, _ in
                    f(strings, sel, a, b, c, nil)
                }
                return block as AnyObject
            }
        }
        forward("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:") { imp, sel in
            let f = unsafeBitCast(imp, to: FiveFlag.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool) -> AnyObject? = { _, a, b, c, _, _, flag in
                f(strings, sel, a, b, c, strings.localizations as NSArray, strings.localizations.first as NSString?, flag)
            }
            return block as AnyObject
        }
        forward("_localizedStringNoCacheNoMarkdownParsingForKey:value:table:bundleLocalizations:localization:formatSpecifierConfiguration:") { imp, sel in
            let f = unsafeBitCast(imp, to: Six.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = { _, a, b, c, _, _, g in
                f(strings, sel, a, b, c, strings.localizations as NSArray, strings.localizations.first as NSString?, g)
            }
            return block as AnyObject
        }
        objc_registerClassPair(subclass)
        return subclass
    }()
}
