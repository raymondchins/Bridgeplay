import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Free WineCX engine")
struct FreeEngineWinecxTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "np-winecx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Each pinned release names a free build Bridgeplay knows how to patch",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func releaseIsSupported(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let build = try #require(SupportedRunners.build(id: id))
        #expect(build == release.runner)
        #expect(build.isFree)
        #expect(Set(NtdllPatcher.patches(for: build).map(\.arch)) == [.x86_64Windows, .i386Windows])
        #expect(NtdllPatcher.patches(for: build).map(\.payloadResource).allSatisfy { $0.hasSuffix(id) })
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256)?.id == build.id)
        #expect(build.tools.count == 1)
        #expect(build.tools.first?.display == "\(build.releaseVersion) (msync, D3DMetal)")
        #expect(build.tools.first?.flavor == .rosetta)
        #expect(release.bundleName == "\(build.releaseVersion).app")
    }

    @Test("11.17 is the current release with its own tool; 11.15 keeps bridgeplay-proton-winecx")
    func currentAndPrevious() throws {
        #expect(FreeEngineWinecx.current.build == "winecx-11.17")
        #expect(FreeEngineWinecx.previous.build == "winecx-11.15")
        #expect(FreeEngineWinecx.current.runner.tools.map(\.name) == ["bridgeplay-proton-winecx-11.17"])
        #expect(FreeEngineWinecx.previous.runner.tools.map(\.name) == ["bridgeplay-proton-winecx"])
        let current = FreeEngineWinecx.current.runner
        let previous = FreeEngineWinecx.previous.runner

        // Installing 11.17 adds a tool and never moves bridgeplay-proton-winecx, which every
        // existing prefix's build record ties to winecx-11.15. 11.17 lists first, so it is
        // what games without a mapping get.
        let both = SupportedRunners.tools(for: [current, previous])
        #expect(both.map(\.name) == ["bridgeplay-proton-winecx-11.17", "bridgeplay-proton-winecx"])
        #expect(both.map(\.build) == ["winecx-11.17", "winecx-11.15"])
        #expect(SupportedRunners.tools(for: [previous]).map(\.build) == ["winecx-11.15"])
        #expect(SupportedRunners.tools(for: [current]).map(\.name) == ["bridgeplay-proton-winecx-11.17"])
    }

    @Test("Both free engines stay separate builds with their own loaders and tools")
    func coexistsWithWineHQ() throws {
        let free = SupportedRunners.all.filter(\.isFree)
        #expect(Set(free.map(\.id)) == Set([FreeEngine.current.build] + FreeEngineWinecx.releases.map(\.build)))
        #expect(Set(free.map(\.loaderSHA256)).count == free.count)
        #expect(Set(free.flatMap(\.tools).map(\.name)).count == free.flatMap(\.tools).count)
        #expect(Set(FreeEngineWinecx.releases.map(\.bundleName) + [FreeEngine.current.bundleName]).count
            == FreeEngineWinecx.releases.count + 1)
    }

    // The license gate keys on the loader hash alone: a CrossOver-shaped tree whose loader
    // is anything else still needs CodeWeavers' license, wherever it sits.
    @Test("A tree that only looks like WineCX is not free")
    func lookalikeNeedsLicense() throws {
        let engines = try makeDirectory("engines")
        defer { try? FileManager.default.removeItem(at: engines) }

        for release in FreeEngineWinecx.releases {
            let root = FreeEngineWinecx.bundle(for: release, engines: engines)
                .appending(path: "Contents/SharedSupport/CrossOver")
            let loader = CrossOverSource.unixLoader(inRoot: root)
            try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not winecx".utf8).write(to: loader)
            try Data("\(release.build)\n".utf8).write(to: FreeEngineWinecx.msyncMarker(in: root))

            #expect(CrossOverLicense.freeBuild(at: root) == nil)
            #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
            #expect(!FreeEngineWinecx.isInstalled(release, engines: engines))
            #expect(FreeEngineWinecx.release(forRoot: root) == nil)
        }
    }

    @Test("Backends follow the compat_run.sh layout and never shadow lib/wine")
    func backendLayout() {
        let backends = FreeEngineWinecx.current.backends
        #expect(!backends.isEmpty)
        #expect(Set(backends.map(\.destination)).count == backends.count)
        for file in backends {
            let parts = file.destination.split(separator: "/").map(String.init)
            #expect(parts.count == 3, "\(file.destination)")
            // DXMT comes from the master tarball, never the archive's 0.80.
            #expect(parts[0] == "dxvk", "\(file.destination)")
            #expect(!file.source.hasPrefix("DXMT/"))
            #expect(["x86_64-windows", "i386-windows"].contains(parts[1]), "\(file.destination)")
            #expect(!["nvapi64.dll", "nvapi.dll", "nvngx.dll"].contains(parts[2]))
            #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit))
            #expect(FreeEngineWinecx.backend(file.destination, in: URL(filePath: "/r")).path(percentEncoded: false)
                == "/r/lib/notproton-backends/\(file.destination)")
        }
        let table = FreeEngineWinecx.expectedFiles()
        for arch in ["x86_64-windows", "i386-windows"] {
            for backend in ["dxmt", "dxvk"] {
                #expect(table["lib/notproton-backends/\(backend)/\(arch)/d3d11.dll"] != nil)
            }
            #expect(table["lib/notproton-backends/dxmt/\(arch)/d3d11.dll"]
                == FreeEngine.dxmt.natives["\(arch)/d3d11.dll"])
            #expect(table["lib/wine/\(arch)/winemetal.dll"] == FreeEngine.dxmt.files["\(arch)/winemetal.dll"])
        }
        #expect(table["lib/wine/x86_64-unix/winemetal.so"] == FreeEngine.dxmt.files["x86_64-unix/winemetal.so"])
        #expect(table[FreeEngine.macDriverPath] == FreeEngineWinecx.current.macDriver)
        #expect(Set(FreeEngineWinecx.current.d3dStock.keys) == Set(WinecxD3DMetal.forwarders))
        #expect(FreeEngineWinecx.msyncMarker(in: URL(filePath: "/r")).path(percentEncoded: false)
            == "/r/.notproton-msync")
        #expect(WinecxD3DMetal.enabledMarker(in: URL(filePath: "/r")).path(percentEncoded: false)
            == "/r/lib/notproton-backends/d3dmetal.enabled")
    }

    // winemac-patch/winecx-d3dmetal-retina.patch: an engine with winecx's own winemac.so is
    // outdated, and the copy Bridgeplay installs is the one it pins.
    @Test("The patched winemac.so ships with the app and replaces winecx's own",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func patchedMacDriver(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let bundled = try #require(Bundle.module.url(forResource: "winemac-\(release.build)", withExtension: "so"))
        #expect(Digest.sha256IfPresent(bundled) == release.macDriver)

        let root = try makeDirectory("macdriver")
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appending(path: FreeEngine.macDriverPath)
        try FileManager.default.createDirectory(at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("winecx's own winemac.so".utf8).write(to: driver)
        #expect(FreeEngineWinecx.layoutProblems(root: root, release: release).contains(FreeEngine.macDriverPath))

        try FreeEngine.installMacDriver(root: root, build: release.build, sha256: release.macDriver,
                                        step: FreeEngineWinecx.step)
        #expect(Digest.sha256IfPresent(driver) == release.macDriver)
        #expect(!FreeEngineWinecx.layoutProblems(root: root, release: release).contains(FreeEngine.macDriverPath))
        #expect(throws: StepFailure.self) {
            try FreeEngine.installMacDriver(root: root, build: release.build, sha256: String(repeating: "0", count: 64),
                                            step: FreeEngineWinecx.step)
        }
    }

    // docs/WINECX.md, Controllers: winebus.so with SDL2 in lib/wine, and the libSDL2 it
    // dlopens by leaf name in lib/, where its @loader_path/../../ rpath points.
    @Test("The SDL2 winebus.so and its libSDL2 ship with the app and are laid into the engine",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func gamepadSupport(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let files = release.gamepad
        var paths: Set<String> = ["lib/wine/x86_64-unix/winebus.so", "lib/libSDL2-2.0.0.dylib"]
        // 11.17 also ships winebus.sys with sdl_bus_load_mappings fixed (winebus-patch/).
        if release.build == "winecx-11.17" { paths.insert("lib/wine/x86_64-windows/winebus.sys") }
        #expect(Set(files.map(\.path)) == paths)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in files {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }

        let root = try makeDirectory("gamepad")
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = root.appending(path: "lib/wine/x86_64-unix/winebus.so")
        try FileManager.default.createDirectory(at: bus.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("winecx's own winebus.so, built without SDL2".utf8).write(to: bus)
        let before = FreeEngineWinecx.layoutProblems(root: root, release: release)
        for file in files { #expect(before.contains(file.path), "\(file.path)") }

        try FreeEngineWinecx.installBundled(files, root: root)
        let after = FreeEngineWinecx.layoutProblems(root: root, release: release)
        for file in files {
            #expect(Digest.sha256IfPresent(root.appending(path: file.path)) == file.sha256, "\(file.path)")
            #expect(!after.contains(file.path), "\(file.path)")
        }
        let wrong = files.map {
            WinecxBundledFile(resource: $0.resource, ext: $0.ext, path: $0.path, sha256: String(repeating: "0", count: 64))
        }
        #expect(throws: StepFailure.self) { try FreeEngineWinecx.installBundled(wrong, root: root) }
    }

    // docs/WINECX.md, Own host name: 11.17 ships ws2_32.dll with getaddrinfo on the local
    // host name returning no loopback first (ws2_32-patch/); 11.15 keeps the runtime's.
    @Test("The own-host-name ws2_32 ships with the app and is laid into the 11.17 engine",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func ownHostNameNetwork(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let files = release.network
        let expected: Set<String> = release.build == "winecx-11.17" ? ["lib/wine/x86_64-windows/ws2_32.dll"] : []
        #expect(Set(files.map(\.path)) == expected)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in files {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }
        guard !files.isEmpty else { return }

        let root = try makeDirectory("network")
        defer { try? FileManager.default.removeItem(at: root) }
        let dll = root.appending(path: "lib/wine/x86_64-windows/ws2_32.dll")
        try FileManager.default.createDirectory(at: dll.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("winecx's own ws2_32.dll".utf8).write(to: dll)
        #expect(FreeEngineWinecx.layoutProblems(root: root, release: release).contains(files[0].path))

        try FreeEngineWinecx.installBundled(files, root: root)
        #expect(Digest.sha256IfPresent(dll) == files[0].sha256)
        #expect(!FreeEngineWinecx.layoutProblems(root: root, release: release).contains(files[0].path))
    }

    // ngx-signer-patch: 11.17 ships crypt32 and wintrust that let Streamline accept Apple's
    // NGX bridge; 11.15 keeps the runtime's.
    @Test("The NGX signer crypt32 and wintrust ship with the app and are pinned for 11.17",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func ngxSigner(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let expected: Set<String> = release.build == "winecx-11.17"
            ? ["lib/wine/x86_64-windows/crypt32.dll", "lib/wine/x86_64-windows/wintrust.dll",
               "lib/notproton-backends/nvapi-shim/x86_64-windows/nvapi64.dll",
               "lib/wine/x86_64-unix/win32u.so", "lib/wine/x86_64-windows/wined3d.dll"] : []
        #expect(Set(release.nvidia.map(\.path)) == expected)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in release.nvidia {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }
    }

    // hide-wine-exports-patch: 11.17 ships kernel32 and kernelbase that can hide ntdll's
    // wine_* exports; 11.15 keeps the runtime's.
    @Test("The hide-Wine-exports kernel32 and kernelbase ship with the app and are pinned for 11.17",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func hideWineExports(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let expected: Set<String> = release.build == "winecx-11.17"
            ? ["lib/wine/x86_64-windows/kernel32.dll", "lib/wine/x86_64-windows/kernelbase.dll"] : []
        #expect(Set(release.loader.map(\.path)) == expected)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in release.loader {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }
    }

    // winecoreaudio-patch: 11.17 ships a winecoreaudio.so with half-period output pulls.
    @Test("The patched winecoreaudio ships with the app and is pinned for 11.17",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func audio(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let expected: Set<String> = release.build == "winecx-11.17" ? ["lib/wine/x86_64-unix/winecoreaudio.so"] : []
        #expect(Set(release.audio.map(\.path)) == expected)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in release.audio {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }
    }

    // d3dx11-patch: 11.17 ships d3dx11_43 and d3dx11_42 exporting D3DX11CreateThreadPump.
    @Test("The patched d3dx11 DLLs ship with the app and are pinned for 11.17",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func d3dx(id: String) throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        let expected: Set<String> = release.build == "winecx-11.17"
            ? ["lib/wine/x86_64-windows/d3dx11_43.dll", "lib/wine/i386-windows/d3dx11_43.dll",
               "lib/wine/x86_64-windows/d3dx11_42.dll", "lib/wine/i386-windows/d3dx11_42.dll"] : []
        #expect(Set(release.d3dx.map(\.path)) == expected)
        let table = FreeEngineWinecx.expectedFiles(release)
        for file in release.d3dx {
            let bundled = try #require(Bundle.module.url(forResource: file.resource, withExtension: file.ext))
            #expect(Digest.sha256IfPresent(bundled) == file.sha256, "\(file.resource)")
            #expect(table[file.path] == file.sha256, "\(file.path)")
        }
    }

    @Test("Each free engine is current, outdated or missing on its own pins")
    func perEngineState() throws {
        let winehqBuild = try #require(SupportedRunners.build(id: FreeEngine.current.build))
        let winecxBuild = try #require(SupportedRunners.build(id: FreeEngineWinecx.current.build))
        let winehq = CrossOverInstall(bundle: URL(filePath: "/e/WineHQ 11.15.app"), releaseVersion: nil,
                                      support: .supported(winehqBuild))
        let winecx = CrossOverInstall(bundle: URL(filePath: "/e/WineCX 11.17.app"), releaseVersion: nil,
                                      support: .supported(winecxBuild))
        let both = [winehq, winecx]
        #expect(FreeEngineStatus.state(build: winehqBuild.id, installs: both, current: [winecxBuild.id]) == .outdated)
        #expect(FreeEngineStatus.state(build: winecxBuild.id, installs: both, current: [winecxBuild.id]) == .current)
        #expect(FreeEngineStatus.state(build: winecxBuild.id, installs: [winehq], current: [winehqBuild.id]) == .missing)
        // Neither engine is judged by the other's pins: these empty trees match neither.
        #expect(!FreeEngineStatus.isCurrent(winehq) && !FreeEngineStatus.isCurrent(winecx))
        #expect(FreeEngineStatus.capture(both).current.isEmpty)
        // Steam lists one tool per engine.
        let tools = SupportedRunners.tools(for: [winehqBuild, winecxBuild]).map(\.display)
        #expect(Set(tools) == ["WineHQ 11.15 - Rosetta", "WineCX 11.17 (msync, D3DMetal)"])
        // The 11.15 engine is judged by its own pins, not by 11.17's.
        let previousBuild = try #require(SupportedRunners.build(id: FreeEngineWinecx.previous.build))
        let previous = CrossOverInstall(bundle: URL(filePath: "/e/WineCX 11.15.app"), releaseVersion: nil,
                                        support: .supported(previousBuild))
        #expect(!FreeEngineStatus.isCurrent(previous))
        #expect(FreeEngineStatus.state(build: previousBuild.id, installs: [previous], current: [previousBuild.id])
            == .current)
    }

    @Test("Downloads come only from the pinned GitHub release mirrors")
    func pinnedSources() {
        #expect(FreeEngineWinecx.current.sha256 == "a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331")
        #expect(FreeEngineWinecx.previous.sha256 == "6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87")
        for release in FreeEngineWinecx.releases {
            #expect(release.bases.allSatisfy { $0.host() == "github.com" })
            #expect(release.bases.allSatisfy { $0.path().hasSuffix(release.runtime) })
            #expect(FreeEngineWinecx.downloads(for: release).lastPathComponent == "winecx-\(release.runtime)")
        }
    }

    // MARK: - D3DMetal linking

    // A stand-in for Apple's redist/lib: the names and the builtin marker, none of the code.
    private func makePayload(in folder: URL, version: String? = "3.0", builtin: Bool = true) throws -> URL {
        let fm = FileManager.default
        let lib = folder
        let external = lib.appending(path: "external")
        let framework = external.appending(path: "D3DMetal.framework")
        try fm.createDirectory(at: framework.appending(path: "Versions/A/Resources"), withIntermediateDirectories: true)
        if let version {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try plist.write(to: framework.appending(path: "Versions/A/Resources/Info.plist"))
        }
        try Data("dylib".utf8).write(to: external.appending(path: "libd3dshared.dylib"))
        let pe = lib.appending(path: "wine/x86_64-windows")
        try fm.createDirectory(at: pe, withIntermediateDirectories: true)
        var image = Data(repeating: 0, count: 0x80)
        image[0] = 0x4d
        image[1] = 0x5a
        if builtin { image.replaceSubrange(0x40 ..< 0x51, with: Array("Wine builtin DLL".utf8) + [0]) }
        let unix = lib.appending(path: "wine/x86_64-unix")
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        // GPTK 4.0 beta 2: the four forwarders plus nvapi64 and nvngx-on-metalfx, each unix
        // half a relative link to libd3dshared.
        for name in WinecxD3DMetal.forwarders + ["nvapi64.dll", "nvngx-on-metalfx.dll"] {
            try image.write(to: pe.appending(path: name))
            try fm.createSymbolicLink(
                atPath: unix.appending(path: WinecxD3DMetal.unixName(of: name)).path(percentEncoded: false),
                withDestinationPath: "../../external/libd3dshared.dylib")
        }
        return lib
    }

    // Wine's four originals, as text whose hashes the test pins.
    private static let stockText = Dictionary(uniqueKeysWithValues: WinecxD3DMetal.forwarders.map { ($0, "wine's own \($0)") })
    private static let stock = stockText.mapValues { Digest.sha256(of: Data($0.utf8)) }

    private func makeEngineRoot(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let root = folder.appending(path: "CrossOver")
        let external = root.appending(path: "lib/external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("winecx readme".utf8).write(to: external.appending(path: "README"))
        let builtins = root.appending(path: "lib/wine/x86_64-windows")
        try fm.createDirectory(at: builtins, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        for (name, text) in Self.stockText {
            try Data(text.utf8).write(to: builtins.appending(path: name))
        }
        return root
    }

    private func destination(of link: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))
    }

    @Test("A Game Porting Toolkit is found in each shape users have it in, user folder first")
    func locatesPayloadShapes() throws {
        let base = try makeDirectory("shapes")
        defer { try? FileManager.default.removeItem(at: base) }

        let lib = try makePayload(in: base.appending(path: "plain"))
        let redist = try makePayload(in: base.appending(path: "volume/redist/lib"))
        let app = try makePayload(in: base.appending(path: "GPTK.app/Contents/Resources/wine/lib"))
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(WinecxD3DMetal.payloadRoot(under: lib) == lib)
        #expect(WinecxD3DMetal.payloadRoot(under: base.appending(path: "volume"))?.standardizedFileURL
            == redist.standardizedFileURL)
        #expect(WinecxD3DMetal.payloadRoot(under: base.appending(path: "GPTK.app"))?.standardizedFileURL
            == app.standardizedFileURL)
        #expect(WinecxD3DMetal.payloadRoot(under: empty) == nil)

        let found = try #require(WinecxD3DMetal.locate(in: [empty, base.appending(path: "volume"), lib]))
        #expect(found.libRoot.standardizedFileURL == redist.standardizedFileURL)
        #expect(found.version == "3.0")

        let roots = WinecxD3DMetal.searchRoots(home: URL(filePath: "/Users/u"))
        #expect(roots.map { $0.path(percentEncoded: false) } == [
            "/Users/u/Library/Application Support/bridgeplay/gptk/",
            "/Applications/Game Porting Toolkit.app/",
            "/Users/u/Applications/Game Porting Toolkit.app/",
        ])
    }

    @Test("Forwarders without the builtin marker, or a payload missing pieces, are refused")
    func rejectsIncompletePayloads() throws {
        let base = try makeDirectory("reject")
        defer { try? FileManager.default.removeItem(at: base) }

        let native = try makePayload(in: base.appending(path: "native"), builtin: false)
        #expect(!WinecxD3DMetal.isPayloadRoot(native))

        let partial = try makePayload(in: base.appending(path: "partial"))
        try FileManager.default.removeItem(at: partial.appending(path: "wine/x86_64-windows/d3d12.dll"))
        #expect(!WinecxD3DMetal.isPayloadRoot(partial))

        let noFramework = try makePayload(in: base.appending(path: "noframework"))
        try FileManager.default.removeItem(at: noFramework.appending(path: "external/D3DMetal.framework"))
        #expect(!WinecxD3DMetal.isPayloadRoot(noFramework))

        #expect(WinecxD3DMetal.locate(in: [native, partial, noFramework]) == nil)
    }

    @Test("Linking makes Apple's forwarders the builtins, as links, with Wine's originals set aside")
    func linksPayload() throws {
        let base = try makeDirectory("link")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        let payload = try #require(WinecxD3DMetal.locate(in: [lib]))
        try WinecxD3DMetal.link(payload, root: root, stock: Self.stock)

        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(WinecxD3DMetal.linkedSource(root: root) == lib.standardizedFileURL.path(percentEncoded: false))
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        let source = lib.standardizedFileURL
        #expect(try destination(of: root.appending(path: "lib/external/libd3dshared.dylib"))
            == source.appending(path: "external/libd3dshared.dylib").path(percentEncoded: false))
        #expect(try destination(of: root.appending(path: "lib/external/D3DMetal.framework"))
            == source.appending(path: "external/D3DMetal.framework").path(percentEncoded: false))
        for name in WinecxD3DMetal.forwarders + ["nvapi64.dll", "nvapi.dll", "nvngx.dll"] {
            let from = WinecxD3DMetal.sourceName(of: name)
            #expect(try destination(of: root.appending(path: "lib/wine/x86_64-windows/\(name)"))
                == source.appending(path: "wine/x86_64-windows/\(from)").path(percentEncoded: false))
            let so = WinecxD3DMetal.unixName(of: name)
            #expect(try destination(of: root.appending(path: "lib/wine/x86_64-unix/\(so)"))
                == source.appending(path: "wine/x86_64-unix/\(WinecxD3DMetal.unixName(of: from))").path(percentEncoded: false))
            // Through Apple's own relative link, onto the shared library.
            #expect(try Data(contentsOf: root.appending(path: "lib/wine/x86_64-unix/\(so)")) == Data("dylib".utf8))
        }
        for name in WinecxD3DMetal.forwarders {
            let saved = root.appending(path: "lib/notproton-backends/wine-stock/x86_64-windows/\(name)")
            #expect(Digest.sha256IfPresent(saved) == Self.stock[name])
        }
        // nvngx-on-metalfx is linked as nvngx, never under its own name.
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/wine/x86_64-windows/nvngx-on-metalfx.dll").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/notproton-backends/d3dmetal").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))

        let marker = try String(contentsOf: WinecxD3DMetal.enabledMarker(in: root), encoding: .utf8)
        #expect(marker.contains("version=3.0\n"))
        #expect(marker.contains("libd3dshared=lib/external/libd3dshared.dylib\n"))
        #expect(marker.contains("model=builtin\n"))

        // Relinking is idempotent.
        try WinecxD3DMetal.link(payload, root: root, stock: Self.stock)
        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
    }

    @Test("GPTK 4.0 beta 3's d3d12core replaces Wine's own while linked and gives it back on unlink")
    func linksReplacedForwarder() throws {
        let base = try makeDirectory("d3d12core")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let apple = lib.appending(path: "wine/x86_64-windows/d3d12core.dll")
        try fm.copyItem(at: lib.appending(path: "wine/x86_64-windows/d3d12.dll"), to: apple)
        try fm.createSymbolicLink(
            atPath: lib.appending(path: "wine/x86_64-unix/d3d12core.so").path(percentEncoded: false),
            withDestinationPath: "../../external/libd3dshared.dylib")
        let root = try makeEngineRoot(in: base)
        let live = root.appending(path: "lib/wine/x86_64-windows/d3d12core.dll")
        try Data("vkd3d d3d12core".utf8).write(to: live)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)

        try WinecxD3DMetal.link(try #require(WinecxD3DMetal.locate(in: [lib])), root: root, stock: Self.stock)
        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        #expect(try destination(of: live) == apple.standardizedFileURL.path(percentEncoded: false))
        #expect(try Data(contentsOf: root.appending(path: "lib/wine/x86_64-unix/d3d12core.so")) == Data("dylib".utf8))
        let saved = root.appending(path: "lib/notproton-backends/wine-stock/x86_64-windows/d3d12core.dll")
        #expect(try Data(contentsOf: saved) == Data("vkd3d d3d12core".utf8))

        WinecxD3DMetal.unlink(root: root)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        #expect((try? fm.destinationOfSymbolicLink(atPath: live.path(percentEncoded: false))) == nil)
        #expect(try Data(contentsOf: live) == Data("vkd3d d3d12core".utf8))
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/wine/x86_64-unix/d3d12core.so").path(percentEncoded: false)))

        // A GPTK without one (4.0 beta 2) leaves Wine's in place.
        try fm.removeItem(at: apple)
        try WinecxD3DMetal.link(try #require(WinecxD3DMetal.locate(in: [lib])), root: root, stock: Self.stock)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        #expect(try Data(contentsOf: live) == Data("vkd3d d3d12core".utf8))
    }

    @Test("Unlinking puts Wine's originals back byte for byte and removes only links")
    func unlinksCleanly() throws {
        let base = try makeDirectory("unlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        try WinecxD3DMetal.link(try #require(WinecxD3DMetal.locate(in: [lib])), root: root, stock: Self.stock)

        try fm.removeItem(at: lib)
        #expect(!WinecxD3DMetal.isLinked(root: root))
        // Still the linked shape, only dangling: refresh is what clears it.
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)

        WinecxD3DMetal.unlink(root: root)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        #expect(!fm.fileExists(atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
        for (name, text) in Self.stockText {
            let live = root.appending(path: "lib/wine/x86_64-windows/\(name)")
            #expect((try? fm.destinationOfSymbolicLink(atPath: live.path(percentEncoded: false))) == nil)
            #expect(try Data(contentsOf: live) == Data(text.utf8))
        }
        #expect(try fm.contentsOfDirectory(atPath: root.appending(path: "lib/wine/x86_64-unix").path(percentEncoded: false)).isEmpty)
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/notproton-backends/wine-stock").path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: root.appending(path: "lib/external/libd3dshared.dylib").path(percentEncoded: false))) == nil)
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))

        // A real file in lib/external is never removed, only links are.
        let real = root.appending(path: "lib/external/libd3dshared.dylib")
        try Data("placed by hand".utf8).write(to: real)
        WinecxD3DMetal.unlink(root: root)
        #expect(fm.fileExists(atPath: real.path(percentEncoded: false)))
    }

    @Test("Only the stock and the linked layout pass; a tampered builtin blocks linking")
    func toleratesExactlyTwoStates() throws {
        let base = try makeDirectory("states")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        let payload = try #require(WinecxD3DMetal.locate(in: [lib]))

        let dxgi = root.appending(path: "lib/wine/x86_64-windows/dxgi.dll")
        try Data("tampered".utf8).write(to: dxgi)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock) == ["lib/wine/x86_64-windows/dxgi.dll"])
        #expect(throws: StepFailure.self) { try WinecxD3DMetal.link(payload, root: root, stock: Self.stock) }
        // The failed link left nothing behind and moved nothing aside.
        #expect(!fm.fileExists(atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
        for name in ["d3d10.dll", "d3d11.dll", "d3d12.dll"] {
            #expect(Digest.sha256IfPresent(root.appending(path: "lib/wine/x86_64-windows/\(name)")) == Self.stock[name])
        }
        try Data(Self.stockText["dxgi.dll"]!.utf8).write(to: dxgi)

        // A stray unix half or a set-aside copy without the marker is neither state.
        let stray = root.appending(path: "lib/wine/x86_64-unix/d3d12.so")
        try fm.createSymbolicLink(at: stray, withDestinationURL: lib.appending(path: "external/libd3dshared.dylib"))
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock) == ["lib/wine/x86_64-unix/d3d12.so"])
        try fm.removeItem(at: stray)

        try WinecxD3DMetal.link(payload, root: root, stock: Self.stock)
        // Linked, but one forwarder swapped for a real file: refused.
        let d3d11 = root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")
        try fm.removeItem(at: d3d11)
        try Data("copied apple file".utf8).write(to: d3d11)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock) == ["lib/wine/x86_64-windows/d3d11.dll"])
    }

    @Test("Refresh never writes into a tree that is not WineCX")
    func refreshOnlyTouchesWinecx() throws {
        let base = try makeDirectory("refresh")
        defer { try? FileManager.default.removeItem(at: base) }

        let lib = try makePayload(in: base.appending(path: "gptk"))
        let root = try makeEngineRoot(in: base)
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("crossover loader".utf8).write(to: loader)

        #expect(WinecxD3DMetal.refresh(root: root, roots: [lib]) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: WinecxD3DMetal.enabledMarker(in: root).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "lib/notproton-backends").path(percentEncoded: false)))
    }

    // MARK: - Against the real archive

    // Runs once a release's archive is in Bridgeplay's cache, or at NOTPROTON_WINECX_ARCHIVE.
    private static func realArchive(_ release: WinecxRelease) -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["NOTPROTON_WINECX_ARCHIVE"].map { URL(filePath: $0) },
            FreeEngineWinecx.downloads(for: release).appending(path: release.archive),
        ].compactMap { $0 }
        return candidates.first { Digest.sha256IfPresent($0) == release.sha256 }
    }

    @Test("Unpacking the real archive yields a free, patchable engine with the runtime contract",
          arguments: FreeEngineWinecx.releases.map(\.build))
    func unpacksRealArchive(id: String) async throws {
        let release = try #require(FreeEngineWinecx.release(build: id))
        guard let archive = Self.realArchive(release) else { return }
        // Fetched into the engine cache the way FreeEngineWinecx.install does, when missing.
        let dxmt = FreeEngine.dxmt
        let renderer = try await PinnedDownload.obtain(
            file: dxmt.archive, sha256: dxmt.sha256, bases: dxmt.bases,
            into: FreeEngine.downloads, step: FreeEngineWinecx.step, from: "GitHub"
        )
        let fm = FileManager.default
        let base = try makeDirectory("real")
        defer { try? fm.removeItem(at: base) }

        let engines = base.appending(path: "engines")
        let gptk = try makePayload(in: base.appending(path: "gptk"))
        let install = try FreeEngineWinecx.unpack(
            archive, renderer: renderer, release: release, engines: engines, gptkRoots: [gptk]
        )
        guard case .supported(let build) = install.support else {
            Issue.record("unpacked engine is \(install.support)")
            return
        }
        let root = install.crossOverRoot
        #expect(build.id == release.build)
        #expect(install.isFree)
        #expect(FreeEngineWinecx.isInstalled(release, engines: engines))
        #expect(FreeEngineWinecx.hasBackends(root: root, release: release))
        #expect(CrossOverLicense.check(crossOverRoot: root).licensed)
        try RunnerInstaller.verifyClone(build: build, root: root)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: root, arch: patch.arch)
            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }

        #expect(FreeEngineWinecx.layoutProblems(root: root, release: release).isEmpty)
        // Master's winemetal replaced the archive's, and its DLLs are natives.
        for (path, hash) in FreeEngineWinecx.expectedFiles(release) {
            #expect(Digest.sha256IfPresent(root.appending(path: path)) == hash, "\(path)")
        }
        #expect(!WinecxD3DMetal.isBuiltin(root.appending(path: "lib/notproton-backends/dxmt/x86_64-windows/d3d11.dll")))
        #expect(WinecxD3DMetal.isBuiltin(root.appending(path: "lib/wine/x86_64-windows/winemetal.dll")))
        #expect(try String(contentsOf: FreeEngineWinecx.msyncMarker(in: root), encoding: .utf8) == "\(release.build)\n")

        // The fixture GPTK was linked as the builtins, with Wine's own set aside under their pins.
        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(fm.fileExists(atPath: root.appending(path: "lib/external/README").path(percentEncoded: false)))
        for (name, hash) in release.d3dStock {
            #expect(Digest.sha256IfPresent(root.appending(path: "\(WinecxD3DMetal.stockPath)/\(name)")) == hash)
        }

        // A runner cloned from it carries the same links, and a rescan reaches both trees.
        let runners = base.appending(path: "runners")
        let cloned = try RunnerInstaller.clone(from: install, runners: runners)
        let runnerRoot = SupportPaths.clonedRoot(forBuild: cloned.id, runners: runners)
        #expect(WinecxD3DMetal.isLinked(root: runnerRoot))
        #expect(FreeEngineWinecx.layoutProblems(root: runnerRoot, release: release).isEmpty)
        try fm.removeItem(at: gptk)
        #expect(SystemStatus.relinkGameportingToolkit(engines: engines, runners: runners, roots: [gptk]) == nil)
        for tree in [root, runnerRoot] {
            #expect(!WinecxD3DMetal.isLinked(root: tree))
            #expect(!fm.fileExists(atPath: WinecxD3DMetal.enabledMarker(in: tree).path(percentEncoded: false)))
            #expect(FreeEngineWinecx.layoutProblems(root: tree, release: release).isEmpty, "\(tree)")
            for (name, hash) in release.d3dStock {
                #expect(Digest.sha256IfPresent(tree.appending(path: "lib/wine/x86_64-windows/\(name)")) == hash)
            }
        }
        let again = try makePayload(in: base.appending(path: "gptk2"))
        #expect(SystemStatus.relinkGameportingToolkit(engines: engines, runners: runners, roots: [again])
            == again.standardizedFileURL.path(percentEncoded: false))
        #expect(WinecxD3DMetal.isLinked(root: root) && WinecxD3DMetal.isLinked(root: runnerRoot))
    }

    // MARK: - Against the user's own Game Porting Toolkit

    // Runs only when a GPTK sits in Bridgeplay's gptk folder. It is only read: the links go
    // into a throwaway engine tree under the repository's scratch/.
    @Test("Linking the real Game Porting Toolkit resolves every link and leaves it untouched")
    func linksRealGameportingToolkit() throws {
        let gptk = WinecxD3DMetal.userFolder
        guard WinecxD3DMetal.payloadRoot(under: gptk) != nil else { return }
        let fm = FileManager.default
        let before = try snapshot(of: gptk)

        let scratch = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../scratch/gptk-link-test-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let root = try makeEngineRoot(in: scratch)

        let payload = try #require(WinecxD3DMetal.locate(in: [gptk]))
        #expect(payload.version != nil)
        try WinecxD3DMetal.link(payload, root: root, stock: Self.stock)
        #expect(WinecxD3DMetal.isLinked(root: root))
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        let shared = try Data(contentsOf: payload.libRoot.appending(path: "external/libd3dshared.dylib"))
        for name in WinecxD3DMetal.forwarders + ["nvapi64.dll", "nvapi.dll", "nvngx.dll"] {
            let pe = root.appending(path: "lib/wine/x86_64-windows/\(name)")
            #expect(WinecxD3DMetal.isBuiltin(pe), "\(name)")
            #expect(try Data(contentsOf: root.appending(path: "lib/wine/x86_64-unix/\(WinecxD3DMetal.unixName(of: name))"))
                == shared, "\(name)")
        }
        #expect(!fm.fileExists(atPath: root.appending(path: "lib/wine/x86_64-windows/nvngx-on-metalfx.dll").path(percentEncoded: false)))
        // Only links: no file in the engine tree holds Apple's bytes.
        let walker = try #require(fm.enumerator(atPath: root.path(percentEncoded: false)))
        for case let path as String in walker {
            let attributes = try fm.attributesOfItem(atPath: root.appending(path: path).path(percentEncoded: false))
            if attributes[.type] as? FileAttributeType == .typeRegular {
                #expect(!path.contains("D3DMetal") && !path.hasSuffix(".dylib"), "\(path)")
            }
        }

        WinecxD3DMetal.unlink(root: root)
        #expect(WinecxD3DMetal.layoutProblems(root: root, stock: Self.stock).isEmpty)
        #expect(try snapshot(of: gptk) == before)
    }

    // Path, type, size and modification time of everything below a folder.
    private func snapshot(of folder: URL) throws -> [String] {
        let fm = FileManager.default
        let walker = try #require(fm.enumerator(atPath: folder.path(percentEncoded: false)))
        var lines: [String] = []
        for case let path as String in walker {
            let a = try fm.attributesOfItem(atPath: folder.appending(path: path).path(percentEncoded: false))
            lines.append("\(path) \(a[.type] ?? "") \(a[.size] ?? "") \(a[.modificationDate] ?? "")")
        }
        return lines.sorted()
    }

    // #1295: setup said "missing" for a file that could also be unreadable or changed.
    @Test("A bundled file that is missing, unreadable or changed says which check failed")
    func bundledSourceFailures() throws {
        let dir = try makeDirectory("bundled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data("pinned bundled file".utf8)
        let fixture = dir.appending(path: "fixture.dll")
        try content.write(to: fixture)
        let bundle = try #require(Bundle(url: dir))
        let pin = Digest.sha256(of: content)

        func file(_ resource: String, _ sha256: String) -> WinecxBundledFile {
            WinecxBundledFile(resource: resource, ext: "dll", path: "lib/wine/x86_64-windows/\(resource).dll",
                              sha256: sha256)
        }
        func detail(_ file: WinecxBundledFile) -> String? {
            do {
                _ = try FreeEngineWinecx.bundledSource(file, in: bundle)
                return nil
            } catch {
                return (error as? StepFailure)?.detail
            }
        }

        #expect(try FreeEngineWinecx.bundledSource(file("fixture", pin), in: bundle).lastPathComponent == "fixture.dll")
        #expect(detail(file("absent", pin))?.contains("missing its absent.dll") == true)
        #expect(detail(file("fixture", String(repeating: "0", count: 64)))?.contains("doesn't match") == true)

        let root = try makeDirectory("bundled-root")
        defer { try? FileManager.default.removeItem(at: root) }
        try FreeEngineWinecx.installBundled([file("fixture", pin)], root: root, bundle: bundle)
        #expect(Digest.sha256IfPresent(root.appending(path: "lib/wine/x86_64-windows/fixture.dll")) == pin)

        let path = fixture.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        #expect(detail(file("fixture", pin))?.contains("can't read") == true)
    }
}
