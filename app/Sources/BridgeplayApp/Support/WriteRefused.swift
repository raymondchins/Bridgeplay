// We couldn't write? Logic for that

import AppKit
import Foundation

struct WriteRefused: LocalizedError {
    let path: String
    // Worked out when the write fails, while the folder is as the write found it.
    let remedy: Remedy

    init(path: String, errno code: Int32? = nil, remedy: Remedy? = nil) {
        self.path = path
        self.remedy = remedy ?? Remedy(forPath: path, errno: code)
    }

    static func posixCode(of error: Error) -> Int32? {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    var errorDescription: String? { String(localized: "Could not write files.") }
}

extension WriteRefused {
    static func catching<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: path, errno: posixCode(of: error))
        }
    }

    static func catching<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try catching(url.path(percentEncoded: false), body)
    }
}

// A write failure generally equals App Management permission error
// or bad folder ownership
enum Remedy: Hashable {
    case appManagement
    case otherAccount
    // Root owns it (MDM, `sudo cp`, `sudo make deploy`). Carries what a chown should cover,
    // if anything: a root folder outside a bundle and the home may be /Applications itself.
    case rootOwned(handOver: String?)
    case ownership

    var advice: String {
        switch self {
        // macOS ties the permission to the app's signature, so after an update the switch can
        // stay on while no longer applying.
        case .appManagement:
            String(localized: "Bridgeplay needs the App Management permission. Turn on Bridgeplay in System Settings › Privacy & Security › App Management. After a Bridgeplay update the switch can look on but no longer work: turn it off and on again.")
        case .otherAccount:
            String(localized: "Steam was installed by another account on this Mac. Only that account can modify it. Log in to macOS with that account to reinstall Bridgeplay.")
        case .rootOwned(let target?):
            String(localized: "\(target) belongs to the system (root), not to your account, so Bridgeplay cannot change it. An administrator has to make your account its owner, for example by running this in Terminal: \(Self.chownCommand(target))")
        case .rootOwned(nil):
            String(localized: "This folder belongs to the system (root), and your account cannot write to it. Try again from an administrator account, or ask an administrator for help.")
        case .ownership: String(localized: "Check permissions, make sure your user owns the folder.")
        }
    }

    // Names this account rather than $(whoami): the administrator may run it from their own.
    // One owning account is what dragging Steam.app in gives; other accounts are already
    // handled as .otherAccount.
    static func chownCommand(_ path: String, user: String = NSUserName()) -> String {
        func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "sudo chown -R \(quoted(user)) \(quoted(path))"
    }

    static let settingsButton = String(localized: "Open System Settings")

    private static let appManagementPane =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"

    var settingsPane: URL? {
        switch self {
        case .appManagement: URL(string: Self.appManagementPane)
        case .otherAccount, .rootOwned, .ownership: nil
        }
    }

    @MainActor
    static func openSettings(_ pane: URL) {
        AppLog.note("opening App Management settings")
        NSWorkspace.shared.open(pane)
    }

    // What the lookup reads, swappable in tests.
    struct Lookup {
        var owner: (String) -> uid_t? = Remedy.owner(of:)
        var writable: (String) -> Bool = { access($0, W_OK) == 0 }
        var user: uid_t = getuid()
        var home: String = NSHomeDirectory()
    }

    static func owner(of path: String) -> uid_t? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let owner = attributes[.ownerAccountID] as? NSNumber
        else { return nil }
        return uid_t(owner.uint32Value)
    }

    // The folder whose permissions decide a create, rename or delete: the path when it is a
    // folder, else the one it sits in.
    static func folder(holding path: String) -> String? {
        let url = URL(filePath: path)
        for candidate in [url, url.deletingLastPathComponent()] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.plainPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.plainPath
            }
        }
        return nil
    }

    // The outermost one, so a refusal inside Steam Helper.app names Steam.app.
    static func enclosingBundle(of path: String) -> String? {
        let files = FileManager.default
        var directory = URL(filePath: path)
        var outermost: String?
        while directory.pathComponents.count > 1 {
            let plist = directory.appending(path: "Contents/Info.plist")
            if files.fileExists(atPath: plist.path(percentEncoded: false)) {
                outermost = directory.plainPath
            }
            directory = directory.deletingLastPathComponent()
        }
        return outermost
    }

    // The outermost bundle, or the topmost folder root owns inside the home.
    static func handOver(_ path: String, folder: String, lookup: Lookup) -> String? {
        if let bundle = enclosingBundle(of: path) { return bundle }
        let inside = lookup.home + "/"
        guard folder.hasPrefix(inside) else { return nil }
        var top = URL(filePath: folder)
        while true {
            let parent = top.deletingLastPathComponent().plainPath
            guard parent.hasPrefix(inside), lookup.owner(parent) == 0 else { break }
            top = URL(filePath: parent)
        }
        return top.plainPath
    }

    init(forPath path: String, errno code: Int32? = nil, lookup: Lookup = Lookup()) {
        // EPERM is a policy refusing (App Management, a locked file), EACCES the permissions.
        // Without a code, ask the system, which counts ACLs and every group.
        if let folder = Self.folder(holding: path),
           code.map({ $0 != EPERM }) ?? !lookup.writable(folder),
           let owner = lookup.owner(folder), owner != lookup.user {
            self = owner == 0
                ? .rootOwned(handOver: Self.handOver(path, folder: folder, lookup: lookup))
                : .otherAccount
            return
        }
        self = Self.enclosingBundle(of: path) == nil ? .ownership : .appManagement
    }

    // One piece of advice for several refusals. Root-owned folders in different places
    // share theirs without a command, since no single chown covers them all.
    static func shared(by remedies: [Remedy]) -> Remedy? {
        let distinct = Set(remedies)
        if distinct.count == 1 { return distinct.first }
        let allRoot = !distinct.isEmpty && distinct.allSatisfy {
            if case .rootOwned = $0 { true } else { false }
        }
        return allRoot ? .rootOwned(handOver: nil) : nil
    }
}

struct FailureReport {
    let message: String
    let remedy: Remedy?

    var settingsPane: URL? { remedy?.settingsPane }

    init?(_ errors: [Error]) {
        guard !errors.isEmpty else { return nil }

        var seen = Set<String>()
        let reasons = errors.map(\.localizedDescription).filter { seen.insert($0).inserted }

        let refusals = errors.compactMap { $0 as? WriteRefused }
        remedy = refusals.count == errors.count ? Remedy.shared(by: refusals.map(\.remedy)) : nil

        var parts = reasons
        if let advice = remedy?.advice { parts.append(advice) }
        message = parts.joined(separator: " ")
    }
}
