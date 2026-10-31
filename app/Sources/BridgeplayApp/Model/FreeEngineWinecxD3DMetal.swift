// Links a Game Porting Toolkit the user installed into a WineCX engine, so D3DMetal can
// run on it. Nothing of Apple's is copied or shipped: every entry is a symlink into the
// user's own copy, and the marker compat_run.sh reads is written only once all of them
// are in place. Apple's payload is the redist/lib tree: external/ (D3DMetal.framework and
// libd3dshared.dylib), builtin-marked PE forwarders under wine/x86_64-windows, and their
// unix halves under wine/x86_64-unix, which are links to ../../external/libd3dshared.dylib
// (GPTK 4.0 beta 2; older copies without that folder get libd3dshared directly). There is
// no i386 half, so D3DMetal is 64-bit only.
//
// Apple's forwarders only work as builtins (only a builtin gets a unix half), and Wine
// searches its own lib/wine before anything else, so they replace Wine's builtins outright,
// the way Whisky does it:
//   lib/wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll -> the user's forwarders
//   lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so     -> the user's wine/x86_64-unix/<name>.so
//       Wine takes a builtin's unix half from x86_64-unix beside the PE's directory.
//   lib/wine/x86_64-{windows,unix}/nvapi64.*  -> the user's, when the GPTK has them. Wine has
//       none of its own here. compat_run.sh disables it unless a game's conf says NVAPI=1,
//       since an nvapi that answers sends some games down NVIDIA-only paths.
//   lib/wine/x86_64-{windows,unix}/nvapi.*    -> the user's nvapi64.* again, under the internal
//       name Wine resolves Apple's nvapi64 builtin by.
//   lib/wine/x86_64-{windows,unix}/d3d12core.*  -> the user's, when the GPTK has them (4.0 beta 3
//       on). Its d3d12.dll loads d3d12core.dll by name for Agility SDK games, so Wine's own
//       (vkd3d's) goes aside like a forwarder's original and comes back on unlink.
//   lib/wine/x86_64-{windows,unix}/nvngx.*    -> the user's nvngx-on-metalfx.*, DLSS served
//       by MetalFX. CrossOver copies it into each prefix as nvngx.dll; linking it under
//       that name here lets the prefix's placeholder nvngx.dll resolve to it. compat_run.sh
//       gates it together with nvapi64.
//   lib/external/{D3DMetal.framework,libd3dshared.dylib}  -> the user's external/
//       winecx's own lib/external, and the CX_APPLEGPTK_LIBD3DSHARED_PATH winecx's ntdll
//       dlopens for non-native code regions.
//   lib/notproton-backends/wine-stock/x86_64-windows/<dll>  Wine's originals, moved aside
//       and moved back on unlink, so they come back byte for byte.
//   lib/notproton-backends/d3dmetal.enabled
// Without a Game Porting Toolkit none of this exists and lib/wine is as shipped. DXMT and
// DXVK still load per game as natives from the prefix either way.

import Foundation

enum WinecxD3DMetal {

    static let forwarders = ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]
    // Linked when the GPTK has it, never required. Wine's tree has no file of these names.
    // nvapi.dll is nvapi64.dll again: Apple's nvapi64 carries the internal name nvapi.dll, and
    // Wine looks its builtin up by that name, so without it nvapi64 loads with no unix half
    // and its DllMain fails.
    static let optionalForwarders = ["nvapi64.dll", "nvapi.dll", "nvngx.dll"]
    // The GPTK file an optional forwarder links to, when its name differs.
    // Linked when the GPTK has it, like the optional forwarders, but Wine ships one of the same
    // name, which is set aside and put back like a forwarder's original. No pin: Wine's file
    // is only moved, never rewritten, and is kept whatever its bytes are.
    static let replacedForwarders = ["d3d12core.dll"]
    static let optionalSources = ["nvapi.dll": "nvapi64.dll", "nvngx.dll": "nvngx-on-metalfx.dll"]
    static let sharedLibrary = "libd3dshared.dylib"
    static let framework = "D3DMetal.framework"

    static let externalPath = "lib/external"
    static let builtinPath = "lib/wine/x86_64-windows"
    static let unixPath = "lib/wine/x86_64-unix"
    static let stockPath = "\(FreeEngineWinecx.backendsPath)/wine-stock/x86_64-windows"
    static let enabledMarkerPath = "\(FreeEngineWinecx.backendsPath)/d3dmetal.enabled"
    // Where the first layout put the forwarders. Wine never loaded them from there; unlink
    // clears it out of engines set up before.
    static let legacyBackendPath = "\(FreeEngineWinecx.backendsPath)/d3dmetal"

    static func unixName(of forwarder: String) -> String {
        (forwarder as NSString).deletingPathExtension + ".so"
    }

    static func sourceName(of forwarder: String) -> String {
        optionalSources[forwarder] ?? forwarder
    }

    // The replaced forwarders this GPTK ships as builtins.
    static func replacedForwarders(in source: URL) -> [String] {
        replacedForwarders.filter { isBuiltin(source.appending(path: "wine/x86_64-windows/\($0)")) }
    }

    struct Payload: Sendable, Equatable {
        // The folder holding external/ and wine/.
        let libRoot: URL
        // D3DMetal.framework's CFBundleShortVersionString, when it has one.
        let version: String?
    }

    // Where the user puts a copy by hand: GPTK's redist/lib, or the whole redist folder.
    static var userFolder: URL {
        SupportPaths.support.appending(path: "gptk", directoryHint: .isDirectory)
    }

    // In order of preference. The user's own folder wins over an installed app.
    static func searchRoots(home: URL = SupportPaths.home) -> [URL] {
        [
            home.appending(path: "Library/Application Support/\(SupportPaths.supportDirName)/gptk",
                           directoryHint: .isDirectory),
            // Gcenx's game-porting-toolkit cask installs here.
            URL(filePath: "/Applications/Game Porting Toolkit.app", directoryHint: .isDirectory),
            home.appending(path: "Applications/Game Porting Toolkit.app", directoryHint: .isDirectory),
        ]
    }

    // Accepts the lib folder itself, a redist folder, an evaluation-environment volume
    // root, or a Game Porting Toolkit.app.
    static func payloadRoot(under url: URL) -> URL? {
        [
            url,
            url.appending(path: "lib"),
            url.appending(path: "redist/lib"),
            url.appending(path: "Contents/Resources/wine/lib"),
        ].first(where: isPayloadRoot)
    }

    static func isPayloadRoot(_ lib: URL) -> Bool {
        let fm = FileManager.default
        let external = lib.appending(path: "external")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: external.appending(path: sharedLibrary).path(percentEncoded: false)),
              fm.fileExists(atPath: external.appending(path: framework).path(percentEncoded: false),
                            isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return forwarders.allSatisfy { isBuiltin(lib.appending(path: "wine/x86_64-windows/\($0)")) }
    }

    // Apple's forwarders are winebuild builtins, and only a builtin gets a unix half, so a
    // forwarder without the marker could never reach D3DMetal. Wine compares the 17 bytes
    // at 0x40 against the marker and its terminator.
    static func isBuiltin(_ dll: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x51), head.count == 0x51 else { return false }
        let marker = Array("Wine builtin DLL".utf8) + [0]
        return Array(head[0x40 ..< 0x51]) == marker
    }

    static func locate(in roots: [URL] = searchRoots()) -> Payload? {
        for root in roots {
            guard let lib = payloadRoot(under: root) else { continue }
            return Payload(libRoot: lib, version: version(ofExternal: lib.appending(path: "external")))
        }
        return nil
    }

    static func version(ofExternal external: URL) -> String? {
        let bundle = external.appending(path: framework)
        for plist in [bundle.appending(path: "Versions/A/Resources/Info.plist"),
                      bundle.appending(path: "Resources/Info.plist")] {
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
            else { continue }
            return version
        }
        return nil
    }

    static func enabledMarker(in root: URL) -> URL { root.appending(path: enabledMarkerPath) }

    // Every link the layout needs, as (link, destination it must resolve to).
    static func links(for payload: Payload, root: URL) -> [(link: URL, target: String)] {
        let fm = FileManager.default
        let source = payload.libRoot.standardizedFileURL
        let shared = source.appending(path: "external/\(sharedLibrary)").path(percentEncoded: false)
        var links: [(link: URL, target: String)] = [
            (root.appending(path: "\(externalPath)/\(framework)"),
             source.appending(path: "external/\(framework)").path(percentEncoded: false)),
            (root.appending(path: "\(externalPath)/\(sharedLibrary)"), shared),
        ]
        let optional = optionalForwarders.filter { name in
            isBuiltin(source.appending(path: "wine/x86_64-windows/\(sourceName(of: name))"))
                && !exists(root.appending(path: "\(builtinPath)/\(name)"))
        }
        for name in forwarders + replacedForwarders(in: source) + optional {
            links.append((root.appending(path: "\(builtinPath)/\(name)"),
                          source.appending(path: "wine/x86_64-windows/\(sourceName(of: name))").path(percentEncoded: false)))
            // Apple's own unix half when the GPTK ships one, which is itself a link to
            // libd3dshared, otherwise libd3dshared directly.
            let unix = source.appending(path: "wine/x86_64-unix/\(unixName(of: sourceName(of: name)))")
            links.append((root.appending(path: "\(unixPath)/\(unixName(of: name))"),
                          fm.fileExists(atPath: unix.path(percentEncoded: false))
                              ? unix.path(percentEncoded: false) : shared))
        }
        return links
    }

    static func link(_ payload: Payload, root: URL, stock: [String: String] = FreeEngineWinecx.current.d3dStock) throws {
        let fm = FileManager.default
        unlink(root: root)
        do {
            // Wine's originals go aside first, each checked against its pin, so unlink can
            // always put back exactly what the engine shipped.
            let saved = root.appending(path: stockPath)
            try fm.createDirectory(at: saved, withIntermediateDirectories: true)
            for name in forwarders {
                let live = root.appending(path: "\(builtinPath)/\(name)")
                guard let hash = stock[name], Digest.sha256IfPresent(live) == hash, !isSymlink(live) else {
                    throw StepFailure(step: FreeEngineWinecx.step,
                                      detail: "\(builtinPath)/\(name) is not Wine's own. Update & Set Up the WineCX engine again.")
                }
                try fm.moveItem(at: live, to: saved.appending(path: name))
            }
            for name in replacedForwarders(in: payload.libRoot.standardizedFileURL) {
                let live = root.appending(path: "\(builtinPath)/\(name)")
                guard exists(live) else { continue }
                guard !isSymlink(live) else {
                    throw StepFailure(step: FreeEngineWinecx.step,
                                      detail: "\(builtinPath)/\(name) is not Wine's own. Update & Set Up the WineCX engine again.")
                }
                try fm.moveItem(at: live, to: saved.appending(path: name))
            }
            for entry in links(for: payload, root: root) {
                try fm.createDirectory(at: entry.link.deletingLastPathComponent(), withIntermediateDirectories: true)
                if isSymlink(entry.link) { try fm.removeItem(at: entry.link) }
                try fm.createSymbolicLink(atPath: entry.link.path(percentEncoded: false),
                                          withDestinationPath: entry.target)
            }
            guard linksResolve(root: root) else {
                throw StepFailure(step: FreeEngineWinecx.step,
                                  detail: "The Game Porting Toolkit links in the engine do not resolve.")
            }
            let marker = [
                "source=\(payload.libRoot.standardizedFileURL.path(percentEncoded: false))",
                "version=\(payload.version ?? "unknown")",
                "libd3dshared=\(externalPath)/\(sharedLibrary)",
                "model=builtin",
            ].joined(separator: "\n") + "\n"
            try Data(marker.utf8).write(to: enabledMarker(in: root))
        } catch {
            unlink(root: root)
            throw error
        }
    }

    // Undoes link and nothing else: the marker goes first so a consumer never sees it over a
    // half-removed layout, only symlinks are removed, and Wine's originals are moved back.
    // lib/external keeps winecx's own README.
    static func unlink(root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: enabledMarker(in: root))
        try? fm.removeItem(at: root.appending(path: legacyBackendPath))
        let saved = root.appending(path: stockPath)
        for name in optionalForwarders {
            for path in ["\(builtinPath)/\(name)", "\(unixPath)/\(unixName(of: name))"] {
                let link = root.appending(path: path)
                if isSymlink(link) { try? fm.removeItem(at: link) }
            }
        }
        for name in forwarders + replacedForwarders {
            let live = root.appending(path: "\(builtinPath)/\(name)")
            if isSymlink(live) { try? fm.removeItem(at: live) }
            let original = saved.appending(path: name)
            if fm.fileExists(atPath: original.path(percentEncoded: false)), !exists(live) {
                try? fm.moveItem(at: original, to: live)
            }
            let unix = root.appending(path: "\(unixPath)/\(unixName(of: name))")
            if isSymlink(unix) { try? fm.removeItem(at: unix) }
        }
        for name in [framework, sharedLibrary] {
            let link = root.appending(path: "\(externalPath)/\(name)")
            if isSymlink(link) { try? fm.removeItem(at: link) }
        }
        // rmdir only takes empty folders, so an original that could not go back stays put.
        rmdir(saved.path(percentEncoded: false))
        rmdir(saved.deletingLastPathComponent().path(percentEncoded: false))
    }

    static func isLinked(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: enabledMarker(in: root).path(percentEncoded: false))
            && linksResolve(root: root)
    }

    // The GPTK folder a linked engine points at, as the marker records it.
    static func linkedSource(root: URL) -> String? {
        guard isLinked(root: root),
              let text = try? String(contentsOf: enabledMarker(in: root), encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) }
    }

    // The two states the engine may be in, and nothing else: stock (Wine's own Direct3D in
    // lib/wine, nothing set aside) or linked (the marker, symlinks where Wine's builtins were,
    // and those originals intact in wine-stock). Links are checked as links here; a Game
    // Porting Toolkit that went away is isLinked's concern and a refresh undoes it.
    static func layoutProblems(root: URL, stock: [String: String] = FreeEngineWinecx.current.d3dStock) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        let linked = fm.fileExists(atPath: enabledMarker(in: root).path(percentEncoded: false))
        for name in forwarders {
            let livePath = "\(builtinPath)/\(name)"
            let savedPath = "\(stockPath)/\(name)"
            let unixPath = "\(self.unixPath)/\(unixName(of: name))"
            let live = root.appending(path: livePath)
            let saved = root.appending(path: savedPath)
            let unix = root.appending(path: unixPath)
            if linked {
                if !isSymlink(live) { problems.append(livePath) }
                if isSymlink(saved) || Digest.sha256IfPresent(saved) != stock[name] { problems.append(savedPath) }
                if !isSymlink(unix) { problems.append(unixPath) }
            } else {
                if isSymlink(live) || Digest.sha256IfPresent(live) != stock[name] { problems.append(livePath) }
                if exists(saved) { problems.append(savedPath) }
                if exists(unix) { problems.append(unixPath) }
            }
        }
        for name in replacedForwarders {
            let livePath = "\(builtinPath)/\(name)"
            let savedPath = "\(stockPath)/\(name)"
            let unixPath = "\(self.unixPath)/\(unixName(of: name))"
            let live = root.appending(path: livePath)
            let saved = root.appending(path: savedPath)
            let unix = root.appending(path: unixPath)
            if linked && isSymlink(live) {
                if isSymlink(saved) { problems.append(savedPath) }
                if !isSymlink(unix) { problems.append(unixPath) }
            } else {
                // Stock, or linked from a GPTK without one: Wine's own, if any, in place.
                if isSymlink(live) { problems.append(livePath) }
                if exists(saved) { problems.append(savedPath) }
                if exists(unix) { problems.append(unixPath) }
            }
        }
        for name in optionalForwarders {
            for path in ["\(builtinPath)/\(name)", "\(unixPath)/\(unixName(of: name))"] {
                let url = root.appending(path: path)
                // Linked: only ever a link. Stock: Wine has none.
                if linked ? exists(url) && !isSymlink(url) : exists(url) { problems.append(path) }
            }
        }
        if linked {
            for name in [framework, sharedLibrary] where !isSymlink(root.appending(path: "\(externalPath)/\(name)")) {
                problems.append("\(externalPath)/\(name)")
            }
        }
        return problems
    }

    // fileExists follows links, so a GPTK that was moved or deleted shows up here.
    private static func linksResolve(root: URL) -> Bool {
        let linkedOptional = (replacedForwarders + optionalForwarders).filter { isSymlink(root.appending(path: "\(builtinPath)/\($0)")) }
        let paths = [root.appending(path: "\(externalPath)/\(framework)"),
                     root.appending(path: "\(externalPath)/\(sharedLibrary)")]
            + (forwarders + linkedOptional).flatMap { name in
                [root.appending(path: "\(builtinPath)/\(name)"),
                 root.appending(path: "\(unixPath)/\(unixName(of: name))")]
            }
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    // Present as a file or as a link, dangling or not.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    // Links the first Game Porting Toolkit found, or clears the layout when there is none
    // or the old one went away. Only ever touches a WineCX root: a CrossOver bundle has
    // its own D3DMetal and is never written to.
    @discardableResult
    static func refresh(
        root: URL, roots: [URL] = searchRoots(), stock: [String: String]? = nil
    ) -> Payload? {
        guard let release = FreeEngineWinecx.release(forRoot: root) else { return nil }
        let stock = stock ?? release.d3dStock
        guard let payload = locate(in: roots) else {
            unlink(root: root)
            return nil
        }
        do {
            try link(payload, root: root, stock: stock)
            AppLog.note("winecx: linked D3DMetal \(payload.version ?? "unknown") from "
                + payload.libRoot.path(percentEncoded: false))
            return payload
        } catch {
            AppLog.note("winecx: could not link D3DMetal: \(error.localizedDescription)")
            return nil
        }
    }
}
