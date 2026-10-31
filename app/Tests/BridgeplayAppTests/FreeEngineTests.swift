import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Free WineHQ engine")
struct FreeEngineTests {

    private func makeEngines() throws -> URL {
        let engines = FileManager.default.temporaryDirectory
            .appending(path: "np-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        return engines
    }

    @Test("The pinned release names a free build Bridgeplay knows how to patch")
    func releaseIsSupported() throws {
        let build = try #require(SupportedRunners.build(id: FreeEngine.current.build))
        #expect(build.isFree)
        #expect(!NtdllPatcher.patches(for: build).isEmpty)
        #expect(SupportedRunners.all.filter(\.isFree).map(\.id).contains(FreeEngine.current.build))
    }

    @Test("A CrossOver-shaped tree whose loader is not a free build still needs a license")
    func crossOverKeepsItsLicenseCheck() throws {
        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let root = engines.appending(path: "Fake.app/Contents/SharedSupport/CrossOver")
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not wine".utf8).write(to: loader)

        #expect(CrossOverLicense.freeBuild(at: root) == nil)
        #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
    }

    // Runs against the real archive once it has been downloaded, by Bridgeplay or by hand
    // into the cache Bridgeplay uses.
    @Test("Unpacking the real archive yields a supported, license-free, patchable engine")
    func unpacksRealArchive() throws {
        let archive = FreeEngine.downloads.appending(path: FreeEngine.current.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngine.current.sha256 else { return }

        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let renderer = FreeEngine.downloads.appending(path: FreeEngine.current.renderer.archive)
        let dxvkArchive = FreeEngine.downloads.appending(path: FreeEngine.current.dxvk.archive)
        let haveRenderer = Digest.sha256IfPresent(renderer) == FreeEngine.current.renderer.sha256
            && Digest.sha256IfPresent(dxvkArchive) == FreeEngine.current.dxvk.sha256
        let install = try FreeEngine.unpack(
            archive, renderer: haveRenderer ? renderer : nil, dxvk: haveRenderer ? dxvkArchive : nil,
            release: FreeEngine.current, engines: engines
        )
        guard case .supported(let build) = install.support else {
            Issue.record("unpacked engine is \(install.support)")
            return
        }
        #expect(build.id == FreeEngine.current.build)
        #expect(install.isFree)
        #expect(FreeEngine.isInstalled(engines: engines) == haveRenderer)
        #expect(FreeEngine.hasRenderer(root: install.crossOverRoot) == haveRenderer)
        #expect(!FreeEngine.hasLegacyLayout(root: install.crossOverRoot))
        if haveRenderer { #expect(FreeEngine.layoutProblems(root: install.crossOverRoot).isEmpty) }
        #expect(CrossOverLicense.check(crossOverRoot: install.crossOverRoot).licensed)
        try RunnerInstaller.verifyClone(build: build, root: install.crossOverRoot)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: install.crossOverRoot, arch: patch.arch)
            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }
    }

    private func touch(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Builds a tree whose files hash to whatever the test hands in.
    private func release(table: [String: String]) -> FreeEngineRelease {
        FreeEngineRelease(
            build: "t", archive: "a", sha256: "", bases: [], bundleName: "T.app", wineTree: "w",
            renderer: RendererRelease(
                name: "r", archive: "r", sha256: "", bases: [], tree: "r",
                files: ["x86_64-windows/d3d11.dll": table["dxmt-shipped"] ?? table["dxmt-d3d11"]!,
                        "x86_64-windows/winemetal.dll": table["winemetal"]!],
                natives: ["x86_64-windows/d3d11.dll": table["dxmt-d3d11"]!]),
            macDriver: table["mac"]!,
            stock: ["x86_64-windows/d3d11.dll": table["stock-d3d11"]!],
            dxvk: BackendRelease(
                name: "d", archive: "d", sha256: "", bases: [], tree: "d",
                files: ["x86_64-windows/d3d11.dll": table["dxvk-d3d11"]!])
        )
    }

    private func hash(_ text: String) -> String { Digest.sha256(of: Data(text.utf8)) }

    @Test("Layout paths keep Wine's D3D DLLs in lib/wine and put the backends beside it")
    func layoutPaths() {
        let r = FreeEngine.current.renderer
        #expect(r.installPath(of: "x86_64-windows/winemetal.dll") == "lib/wine/x86_64-windows/winemetal.dll")
        #expect(r.installPath(of: "i386-windows/winemetal.dll") == "lib/wine/i386-windows/winemetal.dll")
        #expect(r.installPath(of: "x86_64-unix/winemetal.so") == "lib/wine/x86_64-unix/winemetal.so")
        for name in ["dxgi", "d3d11", "d3d10core"] {
            for arch in ["x86_64-windows", "i386-windows"] {
                #expect(r.installPath(of: "\(arch)/\(name).dll")
                    == "lib/notproton-backends/dxmt/\(arch)/\(name).dll")
            }
        }
        #expect(FreeEngine.dxvkDirectory == "lib/notproton-backends/dxvk")
    }

    @Test("The hash table covers stock Wine, DXMT, DXVK and the mac driver, with no overlap")
    func hashTableCoverage() {
        let release = FreeEngine.current
        let table = FreeEngine.expectedFiles(release)
        for arch in ["x86_64-windows", "i386-windows"] {
            for name in ["dxgi", "d3d11", "d3d10core", "d3d12"] {
                #expect(table["lib/wine/\(arch)/\(name).dll"] == release.stock["\(arch)/\(name).dll"])
            }
            for name in ["dxgi", "d3d11", "d3d10core"] {
                #expect(table["lib/notproton-backends/dxmt/\(arch)/\(name).dll"] != nil)
            }
            for name in ["d3d11", "d3d10core"] {
                #expect(table["lib/notproton-backends/dxvk/\(arch)/\(name).dll"] != nil)
            }
            #expect(table["lib/wine/\(arch)/winemetal.dll"] != nil)
        }
        #expect(table["lib/wine/x86_64-unix/winemetal.so"] != nil)
        #expect(table[FreeEngine.macDriverPath] == release.macDriver)
        #expect(table.count == release.stock.count + release.renderer.files.count + release.dxvk.files.count + 1)
        // DXMT's D3D DLLs must differ from Wine's, or the migration check could not tell them apart.
        for (path, hash) in release.renderer.files where !path.contains("winemetal") {
            #expect(release.stock[path] != hash)
            // Installed without the builtin marker, so the table pins the stripped copy.
            #expect(table[release.renderer.installPath(of: path)] == release.renderer.natives[path])
        }
    }

    @Test("Verification reports a tampered, missing or legacy file")
    func detectsTampering() throws {
        let root = try makeEngines()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = release(table: [
            "dxmt-d3d11": hash("dxmt"), "winemetal": hash("wm"), "mac": hash("mac"),
            "stock-d3d11": hash("stock"), "dxvk-d3d11": hash("dxvk"),
        ])
        #expect(!FreeEngine.hasRenderer(root: root, release: r))

        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        try touch(root, "lib/wine/x86_64-windows/winemetal.dll", "wm")
        try touch(root, "lib/notproton-backends/dxmt/x86_64-windows/d3d11.dll", "dxmt")
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "dxvk")
        try touch(root, FreeEngine.macDriverPath, "mac")
        #expect(FreeEngine.hasRenderer(root: root, release: r))
        #expect(!FreeEngine.hasLegacyLayout(root: root, release: r))

        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "tampered")
        #expect(FreeEngine.layoutProblems(root: root, release: r) == ["lib/wine/x86_64-windows/d3d11.dll"])
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "tampered")
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
        try touch(root, "lib/notproton-backends/dxvk/x86_64-windows/d3d11.dll", "dxvk")
        try FileManager.default.removeItem(at: root.appending(path: "lib/notproton-backends/dxmt"))
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
    }

    @Test("An engine with DXMT's DLLs baked into lib/wine is the old layout and no longer counts as installed")
    func migrationDetection() throws {
        let root = try makeEngines()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = release(table: [
            "dxmt-d3d11": hash("dxmt"), "winemetal": hash("wm"), "mac": hash("mac"),
            "stock-d3d11": hash("stock"), "dxvk-d3d11": hash("dxvk"),
        ])
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "dxmt")
        try touch(root, "lib/wine/x86_64-windows/winemetal.dll", "wm")
        try touch(root, FreeEngine.macDriverPath, "mac")
        #expect(FreeEngine.hasLegacyLayout(root: root, release: r))
        #expect(!FreeEngine.hasRenderer(root: root, release: r))
        #expect(FreeEngine.layoutProblems(root: root, release: r).contains("lib/wine/x86_64-windows/d3d11.dll"))
        // A stock engine that simply has no backends yet is not "legacy", only incomplete.
        try touch(root, "lib/wine/x86_64-windows/d3d11.dll", "stock")
        #expect(!FreeEngine.hasLegacyLayout(root: root, release: r))
    }

    @Test("DXVK is pinned to a GitHub release asset with a hash for every DLL, both architectures")
    func dxvkPins() {
        let dxvk = FreeEngine.current.dxvk
        #expect(dxvk.bases.allSatisfy { $0.host() == "github.com" && $0.path().contains("Gcenx/DXVK-macOS") })
        #expect(dxvk.sha256.count == 64)
        #expect(dxvk.archive.hasSuffix(".tar.gz"))
        #expect(Set(dxvk.files.keys) == [
            "x86_64-windows/d3d10core.dll", "x86_64-windows/d3d11.dll",
            "i386-windows/d3d10core.dll", "i386-windows/d3d11.dll",
        ])
        #expect(dxvk.files.values.allSatisfy { $0.count == 64 })
        #expect(Set(dxvk.files.values).count == dxvk.files.count)
    }

    @Test("Runs against the real DXVK archive when cached")
    func unpacksRealDxvk() throws {
        let archive = FreeEngine.downloads.appending(path: FreeEngine.current.dxvk.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngine.current.dxvk.sha256 else { return }
        let work = try makeEngines()
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try Shell.run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)])
        #expect(result.status == 0)
        for (path, hash) in FreeEngine.current.dxvk.files {
            #expect(Digest.sha256IfPresent(work.appending(path: "\(FreeEngine.current.dxvk.tree)/\(path)")) == hash)
        }
    }

    @Test("DXMT is the pinned master build on Bridgeplay's release, shared by both free engines")
    func dxmtPins() {
        let dxmt = FreeEngine.current.renderer
        #expect(dxmt.archive == "dxmt-e94c312.tar.gz")
        #expect(dxmt.sha256 == "8de0d5b7eb2b96315f6ec8e259c05423ab43212e776196147b30d9f44927f7f0")
        #expect(dxmt.tree == "e94c312")
        #expect(dxmt.bases.map(\.absoluteString)
            == ["https://github.com/raymondchins/Bridgeplay/releases/download/dxmt-e94c312"])
        // docs/DXMT.md, minus nvapi64, nvngx and the WIP d3d12.
        #expect(dxmt.files == [
            "x86_64-unix/winemetal.so": "1d0a1258cbb696e1323d1fde77ebef7fedf5ea32a554bb777a9916321dedc195",
            "x86_64-windows/d3d10core.dll": "14fef5785b9c83ab1d440d9d8de9d2d875420b9ae468c282737fcd44bb75336b",
            "x86_64-windows/d3d11.dll": "f2ee8959c19548fb66c5b2a3802ff84967107d2faa3391bafb38c1363ece8a8b",
            "x86_64-windows/dxgi.dll": "75436305876c11f4b7e8535fc32b0007e157b062dbd1534c1757c310a44bd99e",
            "x86_64-windows/winemetal.dll": "33dd95086ab29ed03f876c47589b04a1e4a5891c6cbb5af6129309414aa8b0f7",
            "i386-windows/d3d10core.dll": "7cbefea0f3b766024b85413ec75a2cc32e0431bbcc5f966b0b7515b4d785f3e7",
            "i386-windows/d3d11.dll": "842b5a3868230e1b3eb829581b362f4ff56c86b318a3ce5b5307fa071485b58d",
            "i386-windows/dxgi.dll": "51d01ce7f2b9edacaaa3490d838a95bf060ff04db7f42fe746cb62174c484bca",
            "i386-windows/winemetal.dll": "6ddeb053c5510cffafdabfd27c8a67950f2e37308e6b9f9d1a0c44b9119ac456",
        ])
        #expect(!dxmt.files.keys.contains { $0.contains("d3d12") || $0.contains("nv") })
        #expect(Set(dxmt.natives.keys) == Set(dxmt.files.keys.filter { !RendererRelease.isWinemetal($0) }))
        #expect(FreeEngineWinecx.current.renderer.sha256 == dxmt.sha256)
        #expect(FreeEngineWinecx.current.renderer.files == dxmt.files)
    }

    @Test("Stripping the builtin marker turns a builtin PE into a native one and refuses anything else")
    func stripsBuiltinMarker() throws {
        let dir = try scratchDirectory("pe")
        defer { try? FileManager.default.removeItem(at: dir) }
        var image = Data(repeating: 0, count: 0x80)
        image[0] = 0x4d
        image[1] = 0x5a
        image.replaceSubrange(0x40 ..< 0x51, with: FreeEngine.builtinMarker)
        var stripped = image
        try FreeEngine.stripBuiltinMarker(&stripped)
        #expect(Array(stripped[0x40 ..< 0x50]) == FreeEngine.dosStub)
        #expect(stripped.count == image.count)
        #expect(stripped[0x50...] == image[0x50...])
        #expect(!WinecxD3DMetal.isBuiltin(try write(stripped, in: dir)))
        #expect(WinecxD3DMetal.isBuiltin(try write(image, in: dir)))
        // Already native: refused, so a pin mismatch cannot be papered over.
        #expect(throws: StepFailure.self) { try FreeEngine.stripBuiltinMarker(&stripped) }
    }

    private func write(_ data: Data, in dir: URL) throws -> URL {
        let url = dir.appending(path: "\(UUID().uuidString).dll")
        try data.write(to: url)
        return url
    }

    // Downloads the real tarball into Bridgeplay's engine cache (where the app and the other
    // real-archive tests look for it) unless it is already there. NOTPROTON_OFFLINE=1 skips
    // the download, and the test then runs only against a cached copy.
    @Test("The real DXMT master tarball downloads, matches every pin and installs as natives")
    func downloadsAndUnpacksRealDxmt() async throws {
        let dxmt = FreeEngine.current.renderer
        let cached = FreeEngine.downloads.appending(path: dxmt.archive)
        if Digest.sha256IfPresent(cached) != dxmt.sha256,
           ProcessInfo.processInfo.environment["NOTPROTON_OFFLINE"] == "1" { return }
        let archive = try await PinnedDownload.obtain(
            file: dxmt.archive, sha256: dxmt.sha256, bases: dxmt.bases,
            into: FreeEngine.downloads, step: FreeEngine.step, from: "GitHub"
        )
        #expect(Digest.sha256IfPresent(archive) == dxmt.sha256)

        let work = try makeEngines()
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try Shell.run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)])
        #expect(result.status == 0)
        let tree = work.appending(path: dxmt.tree)
        for (path, hash) in dxmt.files {
            #expect(Digest.sha256IfPresent(tree.appending(path: path)) == hash, "\(path)")
        }

        let root = work.appending(path: "root")
        try FreeEngine.installRenderer(dxmt, from: tree, root: root, step: FreeEngine.step)
        for path in dxmt.files.keys {
            let installed = root.appending(path: dxmt.installPath(of: path))
            #expect(Digest.sha256IfPresent(installed) == dxmt.installedHash(of: path), "\(path)")
            // winemetal stays a builtin beside its unix half; the D3D DLLs load as natives.
            if path.hasSuffix(".dll") {
                #expect(WinecxD3DMetal.isBuiltin(installed) == RendererRelease.isWinemetal(path), "\(path)")
            }
        }
        // The WIP D3D12 backend and the DLSS pair are never staged.
        let staged = try FileManager.default.subpathsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(!staged.contains { $0.hasSuffix("d3d12.dll") || $0.contains("nvapi") || $0.contains("nvngx") })
    }

    @Test("Shipped game fixes are located in the payload and installed beside the user's own")
    func gamefixesDefaultInstall() throws {
        let work = try makeEngines()
        defer { try? FileManager.default.removeItem(at: work) }
        let payload = work.appending(path: "payload")
        try touch(payload, "gamefixes/1245620.conf", "BACKEND=dxmt\n")
        try touch(payload, "gamefixes/42.conf", "BACKEND=dxvk\n")
        try touch(payload, "gamefixes/.gitkeep", "")
        try touch(payload, "gamefixes/README", "x")

        let located = try InstallPayload.locateGamefixes(in: payload)
        #expect(located.map(\.lastPathComponent) == ["1245620.conf", "42.conf"])

        let support = work.appending(path: "support")
        let defaults = support.appending(path: "gamefixes-default")
        try touch(support, "gamefixes-default/stale.conf", "old")
        try touch(support, "gamefixes/mine.conf", "KEEP=1")
        for source in located {
            try SteamInstaller.installIfChanged(DeploymentContent.File(
                source: source, destination: defaults.appending(path: source.lastPathComponent),
                name: source.lastPathComponent))
        }
        SteamInstaller.pruneGamefixes(keeping: located.map(\.lastPathComponent), in: defaults)

        let names = try FileManager.default.contentsOfDirectory(atPath: defaults.path(percentEncoded: false)).sorted()
        #expect(names == ["1245620.conf", "42.conf"])
        #expect(try String(contentsOf: defaults.appending(path: "42.conf"), encoding: .utf8) == "BACKEND=dxvk\n")
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "gamefixes/mine.conf").path(percentEncoded: false)))
        #expect(SupportPaths.gamefixesDefault.lastPathComponent == "gamefixes-default")
        #expect(SupportPaths.gamefixesDefault.path(percentEncoded: false)
            == SupportPaths.support.path(percentEncoded: false) + "/gamefixes-default")
    }
}
