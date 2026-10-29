// Downloads a free WineHQ build and lays it out like a CrossOver bundle, so the
// rest of the runner setup treats it as just another source to clone from.

import Foundation

struct FreeEngineRelease: Sendable {
    let build: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    // Path of the Wine tree inside the archive.
    let wineTree: String
    let renderer: RendererRelease
    // sha256 of the winemac.so Bridgeplay ships for this build (winemac-patch/), which
    // exports the macdrv entry points DXMT needs to put Metal into a window.
    let macDriver: String
    // arch/file -> sha256 of Wine's own file, which stays in lib/wine untouched.
    let stock: [String: String]
    // DXVK-macOS, staged beside DXMT for games that do better on it.
    let dxvk: BackendRelease
}

// DXMT replaces Wine's own D3D10/11 and DXGI. Wine's wined3d goes through macOS
// OpenGL 4.1, which tops out below feature level 11 and so fails any Unreal or
// Unity game that needs it, and DXVK pays for a second translation through
// MoltenVK. DXMT goes to Metal directly, the way D3DMetal does. Both free engines take
// the same build: DXMT master e94c312 (https://github.com/3Shain/dxmt/tree/e94c312f5c054263acf261cfa109edf13e757587),
// LGPL-2.1-or-later since ec357fd (v0.80 was the last MIT release), built by
// scripts/build-dxmt.sh as docs/DXMT.md describes.
struct RendererRelease: Sendable {
    let name: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let tree: String
    // Path inside the archive tree -> sha256 as shipped. The winemetal pair goes into
    // lib/wine, where the unix half and its PE stub are found by the loader; the D3D DLLs
    // go to FreeEngine.dxmtDirectory, so lib/wine keeps Wine's own.
    let files: [String: String]
    // The D3D DLLs again, path -> sha256 once FreeEngine.stripBuiltinMarker has run. The
    // launcher copies them into a prefix as natives, and Wine swaps any file carrying the
    // builtin marker for the lib/wine builtin of the same name (load_builtin in
    // dlls/ntdll/unix/loader.c), which would quietly run wined3d instead of DXMT.
    let natives: [String: String]

    static func isWinemetal(_ path: String) -> Bool {
        path.hasSuffix("/winemetal.dll") || path.hasSuffix("/winemetal.so")
    }

    func installPath(of path: String) -> String {
        Self.isWinemetal(path) ? "lib/wine/\(path)" : "\(FreeEngine.dxmtDirectory)/\(path)"
    }

    // The sha256 the file has once installed: the winemetal pair as shipped, the D3D DLLs
    // with the builtin marker stripped.
    func installedHash(of path: String) -> String? {
        Self.isWinemetal(path) ? files[path] : natives[path]
    }
}

// A set of D3D DLLs the launcher can swap in per game. Nothing here is loaded by default.
struct BackendRelease: Sendable {
    let name: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let tree: String
    // Path inside the archive tree -> sha256, installed at FreeEngine.dxvkDirectory/<path>.
    let files: [String: String]
}

enum FreeEngine {

    static let step = "Download free Wine engine"

    // Gcenx's WineHQ packages. 11.15 is the Wine the bridge components are built
    // against (bridge/setup-wine-tree.sh), so the unix halves speak its protocol.
    static let current = FreeEngineRelease(
        build: "winehq-11.15",
        archive: "wine-devel-11.15-osx64.tar.xz",
        sha256: "3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2",
        bases: [URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15")!],
        bundleName: "WineHQ 11.15.app",
        wineTree: "Wine Devel.app/Contents/Resources/wine",
        renderer: dxmt,
        macDriver: "d95fe40b6321ba8a34933a6b394af6d75547220a7168896c357af3a32377b08f",
        stock: [
            "x86_64-windows/d3d10core.dll": "ff08e21a331e4160779ae140b0fd67c25f1557803b0f865467025a55e6133800",
            "x86_64-windows/d3d11.dll": "66d08df71bdb897b55d6f5d12f44b90846dec362641baab2100c0cdf6615c809",
            "x86_64-windows/d3d12.dll": "7dfa70d5b9ac50541c81801d8539be4cd31f37079ea1d93a495fe70c93f95d9a",
            "x86_64-windows/dxgi.dll": "ed8d22612d121415063e54283e7284ae294a07a6b6d83b65dcd91abaadde2e49",
            "i386-windows/d3d10core.dll": "7f9d10eaf361d7d7ad0a76fcedda037014184df9abe3ef0a65c4966a74bcd98d",
            "i386-windows/d3d11.dll": "9f7a4f6ed76c75e902b8f27c45ba9a8d7cadb3205d3e4ab16a6f8a29aedfd30e",
            "i386-windows/d3d12.dll": "501a94c7f2689f996b658ceee101b5b7bd44845dfc53a9336b4ece848ed343e1",
            "i386-windows/dxgi.dll": "5e7310cc1c80650a467a4022e924d34ec07ce58933383ad06f530a61c82afc9d",
        ],
        // Gcenx's repack carries d3d10core and d3d11 only: it drops dxgi and d3d9 as
        // unwanted on macOS, so DXVK games run on Wine's stock dxgi.
        dxvk: BackendRelease(
            name: "DXVK-macOS 1.10.3",
            archive: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
            sha256: "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00",
            bases: [URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack")!],
            tree: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin",
            files: [
                "x86_64-windows/d3d10core.dll": "225562562050d9fae1d4d5d2ca0537020bac268c80dec9aa0633dc0d338a2840",
                "x86_64-windows/d3d11.dll": "173980cb6c51fdd53dc37b9a17f0de7c5dfdebda18f52059aa7d5a6f1871299c",
                "i386-windows/d3d10core.dll": "9e0202437af13a6d0acdb992954321f00a641b2eb98897908c41635ffddc1fc8",
                "i386-windows/d3d11.dll": "2173b081a8660dd70a089dac875a829da6cd1a6230b23fd1daa2a7d7baa1cb03",
            ]
        )
    )

    // Shared by both free engines. Hosted on Bridgeplay's own release, since upstream
    // publishes no build of master; the per-file hashes are in docs/DXMT.md. d3d12.dll
    // (x86_64-windows-d3d12/ in the tarball) is the unfinished backend and is never staged.
    static let dxmt = RendererRelease(
        name: "DXMT e94c312",
        archive: "dxmt-e94c312.tar.gz",
        sha256: "8de0d5b7eb2b96315f6ec8e259c05423ab43212e776196147b30d9f44927f7f0",
        bases: [URL(string: "https://github.com/raymondchins/Bridgeplay/releases/download/dxmt-e94c312")!],
        tree: "e94c312",
        // nvapi64 and nvngx are left out: they only serve DLSS to MetalFX, and an
        // nvapi that answers makes some games take NVIDIA-only paths.
        files: [
            "x86_64-unix/winemetal.so": "1d0a1258cbb696e1323d1fde77ebef7fedf5ea32a554bb777a9916321dedc195",
            "x86_64-windows/d3d10core.dll": "14fef5785b9c83ab1d440d9d8de9d2d875420b9ae468c282737fcd44bb75336b",
            "x86_64-windows/d3d11.dll": "f2ee8959c19548fb66c5b2a3802ff84967107d2faa3391bafb38c1363ece8a8b",
            "x86_64-windows/dxgi.dll": "75436305876c11f4b7e8535fc32b0007e157b062dbd1534c1757c310a44bd99e",
            "x86_64-windows/winemetal.dll": "33dd95086ab29ed03f876c47589b04a1e4a5891c6cbb5af6129309414aa8b0f7",
            "i386-windows/d3d10core.dll": "7cbefea0f3b766024b85413ec75a2cc32e0431bbcc5f966b0b7515b4d785f3e7",
            "i386-windows/d3d11.dll": "842b5a3868230e1b3eb829581b362f4ff56c86b318a3ce5b5307fa071485b58d",
            "i386-windows/dxgi.dll": "51d01ce7f2b9edacaaa3490d838a95bf060ff04db7f42fe746cb62174c484bca",
            "i386-windows/winemetal.dll": "6ddeb053c5510cffafdabfd27c8a67950f2e37308e6b9f9d1a0c44b9119ac456",
        ],
        natives: [
            "x86_64-windows/d3d10core.dll": "aeb43e1ca7d9f221b9f0070c8654fa3579fd767006272cf675a9113e27bc6e72",
            "x86_64-windows/d3d11.dll": "c1c8c4779686990bf343162a8804dd2d1564b2a893e64e5ddcc7db5e76ce409e",
            "x86_64-windows/dxgi.dll": "1bb4939ff43e676eac8b3f3cb0583985ab8f7b1a8e11760d14931da3fc44223b",
            "i386-windows/d3d10core.dll": "e851c39641f66d64a3e4460e7046900cd234b11f44d793826d2f094e9d2166d9",
            "i386-windows/d3d11.dll": "a654ea3851ccc128a1f33d978462872e22fa6430ea85eff6ba9549de95788652",
            "i386-windows/dxgi.dll": "91f38df103412235793f84efe06b87f6f6fc3a4791d4f8d9f8cc2e16bc137d53",
        ]
    )

    static let macDriverPath = "lib/wine/x86_64-unix/winemac.so"

    // Wine keeps its own dxgi, d3d11 and d3d10core in lib/wine. The launcher picks a
    // backend per game from these, so no game is forced onto one by the engine itself.
    static let backendsDirectory = "lib/notproton-backends"
    static let dxmtDirectory = "\(backendsDirectory)/dxmt"
    static let dxvkDirectory = "\(backendsDirectory)/dxvk"

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/engines")
    }

    static func bundle(for release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return hasRenderer(root: install.crossOverRoot, release: release)
    }

    // Every file the engine should carry, relative to its root, with its sha256: Wine's
    // stock D3D DLLs, DXMT's winemetal pair, both backends and the patched winemac.so.
    static func expectedFiles(_ release: FreeEngineRelease = current) -> [String: String] {
        var table: [String: String] = [macDriverPath: release.macDriver]
        for (path, hash) in release.stock { table["lib/wine/\(path)"] = hash }
        for path in release.renderer.files.keys {
            table[release.renderer.installPath(of: path)] = release.renderer.installedHash(of: path)
        }
        for (path, hash) in release.dxvk.files { table["\(dxvkDirectory)/\(path)"] = hash }
        return table
    }

    // Files that are absent or differ from the pinned hash.
    static func layoutProblems(root: URL, release: FreeEngineRelease = current) -> [String] {
        expectedFiles(release).filter { path, hash in
            !SignedPin.matches(root.appending(path: path), sha256: hash)
        }.keys.sorted()
    }

    // An engine unpacked before the backends were split out still runs, but it needs
    // the new layout before the launcher can choose a renderer per game.
    static func hasRenderer(root: URL, release: FreeEngineRelease = current) -> Bool {
        layoutProblems(root: root, release: release).isEmpty
    }

    // The first layout baked DXMT's dxgi, d3d11 and d3d10core over Wine's in lib/wine.
    static func hasLegacyLayout(root: URL, release: FreeEngineRelease = current) -> Bool {
        release.renderer.files.contains { path, hash in
            !RendererRelease.isWinemetal(path)
                && Digest.sha256IfPresent(root.appending(path: "lib/wine/\(path)")) == hash
        }
    }

    // Upstream Wine hides the macdrv functions DXMT looks up, so without this DXMT can
    // create a device but no swapchain, and games abort on their first window.
    static func installMacDriver(root: URL, release: FreeEngineRelease) throws {
        try installMacDriver(root: root, build: release.build, sha256: release.macDriver, step: step)
    }

    // Puts the bundled winemac-<build>.so, checked against its pin, over the engine's own.
    static func installMacDriver(root: URL, build: String, sha256: String, step: String) throws {
        guard let source = Bundle.module.url(forResource: "winemac-\(build)", withExtension: "so"),
              SignedPin.matches(source, sha256: sha256)
        else {
            throw StepFailure(step: step, detail: "Bridgeplay is missing its winemac.so for \(build).")
        }
        let destination = root.appending(path: macDriverPath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking Wine"
            }
        }
    }

    static func install(
        _ release: FreeEngineRelease = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads, step: step, from: "GitHub",
            report: { report(.downloading($0)) }
        )
        let renderer = try await PinnedDownload.obtain(
            file: release.renderer.archive, sha256: release.renderer.sha256, bases: release.renderer.bases,
            into: downloads, step: step, from: "GitHub",
            report: { report(.downloading($0)) }
        )
        let dxvk = try await PinnedDownload.obtain(
            file: release.dxvk.archive, sha256: release.dxvk.sha256, bases: release.dxvk.bases,
            into: downloads, step: step, from: "GitHub",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        // The engine is always rebuilt from the pinned archives, so an engine from the
        // first layout (DXMT over Wine's DLLs) is replaced rather than patched in place.
        return try unpack(archive, renderer: renderer, dxvk: dxvk, release: release, engines: engines)
    }

    static func unpack(
        _ archive: URL, renderer: URL?, dxvk: URL? = nil, release: FreeEngineRelease, engines: URL
    ) throws -> CrossOverInstall {
        let fm = FileManager.default
        let target = bundle(for: release, engines: engines)
        let staging = engines.appending(path: ".\(release.bundleName).new", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let extracted = staging.appending(path: "extract", directoryHint: .isDirectory)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try untar(archive, into: extracted)

        let wine = extracted.appending(path: release.wineTree, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: wine.appending(path: "lib/wine").path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: "\(release.archive) has no Wine tree at \(release.wineTree).")
        }

        let shaped = staging.appending(path: release.bundleName, directoryHint: .isDirectory)
        let root = SupportPaths.crossOverRoot(inBundle: shaped)
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: wine, to: root)

        if let renderer {
            try untar(renderer, into: extracted)
            let tree = extracted.appending(path: release.renderer.tree, directoryHint: .isDirectory)
            try installRenderer(release.renderer, from: tree, root: root, step: step)
            try installMacDriver(root: root, release: release)
        }

        if let dxvk {
            try untar(dxvk, into: extracted)
            let tree = extracted.appending(path: release.dxvk.tree, directoryHint: .isDirectory)
            for (path, hash) in release.dxvk.files.sorted(by: { $0.key < $1.key }) {
                let source = tree.appending(path: path)
                guard Digest.sha256IfPresent(source) == hash else {
                    throw StepFailure(step: step, detail: "\(release.dxvk.archive) has no pinned \(path).")
                }
                try place(source, at: root.appending(path: "\(dxvkDirectory)/\(path)"))
            }
        }

        // WineHQ already keeps its unix loader beside the unix libraries, where
        // CrossOver keeps its own, so the Wine tree needs no reshaping inside.
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winehq.wine.notproton",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "winehq-", with: ""),
            "CFBundleVersion": release.build,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: shaped.appending(path: "Contents/Info.plist"))
        try RunnerInstaller.clearQuarantine(at: shaped)

        let install = CrossOverSource.inspect(bundle: shaped)
        guard case .supported(let build) = install.support, build.id == release.build else {
            throw StepFailure(
                step: step,
                detail: "The unpacked Wine loader is not the \(release.build) build Bridgeplay was made for."
            )
        }

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    // Lays the renderer out under root: the winemetal pair as shipped into lib/wine, the
    // D3D DLLs with the builtin marker stripped into dxmtDirectory. Every file is checked
    // against its pin before and after, so a winemetal from another build never lands
    // beside these DLLs (they share one unix-call table).
    static func installRenderer(_ renderer: RendererRelease, from tree: URL, root: URL, step: String) throws {
        for (path, hash) in renderer.files.sorted(by: { $0.key < $1.key }) {
            let source = tree.appending(path: path)
            guard Digest.sha256IfPresent(source) == hash else {
                throw StepFailure(step: step, detail: "\(renderer.archive) has no pinned \(path).")
            }
            let destination = root.appending(path: renderer.installPath(of: path))
            if RendererRelease.isWinemetal(path) {
                try place(source, at: destination)
                continue
            }
            var image = try Data(contentsOf: source)
            try stripBuiltinMarker(&image)
            guard Digest.sha256(of: image) == renderer.natives[path] else {
                throw StepFailure(step: step, detail: "\(path) from \(renderer.archive) does not match its native pin.")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try image.write(to: destination)
        }
    }

    static let builtinMarker = Array("Wine builtin DLL".utf8) + [0]
    // The bytes winecx-gptk writes over the marker (a plain DOS stub), so DXMT 0.80 stripped
    // here hashes the same as the copy in the WineCX archive.
    static let dosStub: [UInt8] = [0x0e, 0x1f, 0xba, 0x0e, 0x00, 0xb4, 0x09, 0xcd,
                                   0x21, 0xb8, 0x01, 0x4c, 0xcd, 0x21, 0x90, 0x90]

    // Wine reads the 17 bytes at 0x40 as the builtin marker. Without it the DLL is an
    // ordinary native, which is what a per-game backend in a prefix has to be.
    static func stripBuiltinMarker(_ image: inout Data) throws {
        let start = image.startIndex
        guard image.count > 0x51, image[start] == 0x4d, image[start + 1] == 0x5a,
              Array(image[(start + 0x40) ..< (start + 0x51)]) == builtinMarker
        else {
            throw StepFailure(step: step, detail: "A DXMT DLL does not carry the Wine builtin marker.")
        }
        image.replaceSubrange((start + 0x40) ..< (start + 0x50), with: dosStub)
    }

    private static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
    }

    private static func untar(_ archive: URL, into directory: URL) throws {
        let result = try Shell.run("/usr/bin/tar", [
            "-xf", archive.path(percentEncoded: false), "-C", directory.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Unpacking \(archive.lastPathComponent) failed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
