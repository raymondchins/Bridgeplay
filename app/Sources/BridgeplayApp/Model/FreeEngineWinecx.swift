// The second free engine: WineCX, CodeWeavers' LGPL CrossOver 26.3 Wine changes rebased
// onto upstream Wine by dappermint (github.com/dappermint/winecx) and built into a Whisky
// runtime by dappermint/winecx-gptk's CI. The current release is Wine 11.17; the 11.15 one
// stays installable and selectable beside it. Over the WineHQ engine it adds
// msync and the CrossOver hooks Apple's D3DMetal needs. DXMT (the same master build as the
// WineHQ engine, not the archive's 0.80) and DXVK are backends a game opts into; Wine's own
// Direct3D, or D3DMetal once a user's Game Porting Toolkit is linked, is the builtin.
// docs/WINECX.md.

import Foundation

struct WinecxBackendFile: Sendable, Equatable {
    // Path inside the archive, below Libraries/.
    let source: String
    // Path below lib/notproton-backends/ in the engine.
    let destination: String
    let sha256: String
}

// A file Bridgeplay ships in its own bundle and lays into the engine, checked against its pin.
struct WinecxBundledFile: Sendable, Equatable {
    // Resource name and extension in the app bundle.
    let resource: String
    let ext: String
    // Path below the engine root.
    let path: String
    let sha256: String
}

struct WinecxRelease: Sendable {
    let build: String
    // The winecx-gptk runtime version, which is what its WhiskyWineVersion.plist carries.
    let runtime: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    // Path of the Wine tree inside the archive.
    let wineTree: String
    // DXVK, copied out of the archive. The archive's DXMT 0.80 is not used.
    let backends: [WinecxBackendFile]
    // DXMT, from its own tarball: the D3D DLLs as natives under lib/notproton-backends/dxmt,
    // the winemetal pair over the archive's in lib/wine.
    let renderer: RendererRelease
    // lib/wine/x86_64-windows/<name> -> sha256 of Wine's own copy, for the four DLLs a linked
    // Game Porting Toolkit replaces (WinecxD3DMetal.forwarders).
    let d3dStock: [String: String]
    // sha256 of the winemac.so Bridgeplay ships for this build: winecx's own with
    // winemac-patch/winecx-d3dmetal-retina.patch, so D3DMetal sizes a Retina-mode
    // swapchain in Win32 pixels rather than points.
    let macDriver: String
    // Controller support. The runtime's CI built winebus.so without SDL2, so a controller
    // only reached Wine through the IOHID bus, as a raw HID device XInput does not open.
    // Bridgeplay ships winecx's winebus.so rebuilt with SDL2 and the x86_64 libSDL2 it
    // dlopens by leaf name, which dyld finds through winebus.so's @loader_path/../../
    // rpath, i.e. in lib/.
    let gamepad: [WinecxBundledFile]
    // ws2_32 rebuilt so getaddrinfo on this machine's own host name drops the loopback and
    // link-local addresses macOS lists first, as Windows never returns them
    // (ws2_32-patch/). Empty where the runtime's own ws2_32 is kept.
    let network: [WinecxBundledFile]
    // What the NVIDIA identity D3DMetal is given needs from the engine (NVAPI=1): crypt32 and
    // wintrust that let Streamline load Apple's unsigned NGX bridge (ngx-signer-patch/), a
    // native nvapi64 reporting a current driver (nvapi-shim/), and a win32u whose display
    // class DriverVersion says the same (win32u-patch/). Empty where none of it ships.
    let nvidia: [WinecxBundledFile]
    // winecoreaudio.so rebuilt so an output stream asks CoreAudio for half a period per
    // pull, not a whole one, which Wine padded with silence and was heard as crackling
    // (winecoreaudio-patch/). Empty where the runtime's own is kept.
    let audio: [WinecxBundledFile]
    // d3dx11_43 and d3dx11_42 rebuilt to export D3DX11CreateThreadPump, which games such as
    // Persona 4 Golden import and Wine leaves as a stub (d3dx11-patch/). Empty where the
    // runtime's own are kept.
    let d3dx: [WinecxBundledFile]
    // kernel32 and kernelbase rebuilt so GetProcAddress can hide ntdll's wine_* exports from
    // games that turn features off under Wine (hide-wine-exports-patch/,
    // NOTPROTON_HIDE_WINE_EXPORTS). Empty where the runtime's own are kept.
    let loader: [WinecxBundledFile]
    // The runner build this release unpacks to, keyed by its pinned loader, and the ntdll
    // detours for it (NtdllPatcher.byBuild).
    let runner: RunnerBuild
    let ntdllPatches: [NtdllPatch]
}

enum FreeEngineWinecx {

    static let step = "Download free WineCX engine"

    // What the WineCX row installs. It gets its own tool, bridgeplay-proton-winecx-11.17, beside
    // the 11.15 release, which keeps bridgeplay-proton-winecx: every existing prefix is claimed by
    // winecx-11.15, so the default tool only moves once 11.17 is verified on real games.
    static let current = v1117
    static let previous = v1115
    static let releases = [current, previous]

    // The runner build of the current release.
    static var runnerBuild: RunnerBuild { current.runner }
    static var ntdllPatches: [NtdllPatch] { current.ntdllPatches }
    static var runnerBuilds: [RunnerBuild] { releases.map(\.runner) }

    static func release(build id: String) -> WinecxRelease? {
        releases.first { $0.build == id }
    }

    // The release whose pinned loader a tree carries, which is what makes it that WineCX.
    static func release(forRoot root: URL) -> WinecxRelease? {
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        guard let hash = Digest.sha256IfPresent(loader) else { return nil }
        return releases.first { $0.runner.loaderSHA256 == hash }
    }

    // DXVK-macOS 1.10.3 is the same repack in both runtimes. nvapi64 and nvngx are left out
    // for the reason FreeEngine gives. The repack ships no dxgi, and its DLLs carry no
    // builtin marker.
    private static let dxvk: [WinecxBackendFile] = [
        WinecxBackendFile(source: "DXVK/x64/d3d10core.dll", destination: "dxvk/x86_64-windows/d3d10core.dll",
                          sha256: "0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e"),
        WinecxBackendFile(source: "DXVK/x64/d3d11.dll", destination: "dxvk/x86_64-windows/d3d11.dll",
                          sha256: "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4"),
        WinecxBackendFile(source: "DXVK/x32/d3d10core.dll", destination: "dxvk/i386-windows/d3d10core.dll",
                          sha256: "2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327"),
        WinecxBackendFile(source: "DXVK/x32/d3d11.dll", destination: "dxvk/i386-windows/d3d11.dll",
                          sha256: "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0"),
    ]

    // SDL 2.32.10 (zlib license, NOTICE) built x86_64 with winemac-patch/sdl2-iokit-gamepad-collection.patch
    // (pads whose gamepad is a secondary HID collection, e.g. GameSir G7 Pro over Bluetooth),
    // signed ad hoc, since a release build strips unsigned Mach-O resources and would break the pin.
    private static let sdl = WinecxBundledFile(
        resource: "libSDL2-2.0.0", ext: "dylib", path: "lib/libSDL2-2.0.0.dylib",
        sha256: "aeeec088bf51f9eac0dbd8e26ae994c7b8568fb42fc676835d6dc2109fc559d1")

    // runtime 4.7.3: winecx e0aa380 (Wine 11.17), built by winecx-gptk 0bf3eab, minos 26.0.
    // Over 4.5.125 it carries the later msync fixes, kernelbase's FlsGetValue2 for Unity
    // 6000.3, dxgi's CheckInterfaceSupport, the winemac client-view flush fix and the
    // Wine 11.16 and 11.17 merges.
    static let v1117 = WinecxRelease(
        build: "winecx-11.17",
        runtime: "4.7.3",
        archive: "Libraries.tar.gz",
        sha256: "a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331",
        bases: [
            URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3")!,
        ],
        bundleName: "WineCX 11.17.app",
        wineTree: "Libraries/Wine",
        backends: dxvk,
        renderer: FreeEngine.dxmt,
        d3dStock: [
            "d3d10.dll": "9a9efe0cdaad2f41b0c5fe0f216c97720cdf82b21fbbb6e59f361112cdc4ccc3",
            "d3d11.dll": "0a3d9e758a491c99d34dce1aa4ee744671d1faeef498c6dfc5d26eecb9dff7ec",
            "d3d12.dll": "974e132bcafb150bb97f33fa63199346a3b942b3e09d6d06c0cbc1755f30afa5",
            "dxgi.dll": "6f7cf2d60c991ad26b60316935bb9d3587b0c83cc01991bf55564bcfbfa47e09",
        ],
        macDriver: "aa192f846ad15d56de200fc92752eaf2d455700846ae2cf1ccc7b27b535f1c00",
        // winebus.so: winecx e0aa380 built with SONAME_LIBSDL2. winebus.sys: the same tree's
        // PE half with sdl_bus_load_mappings fixed (winebus-patch/), so a winebus "map" key
        // no longer writes past the array and takes every pad down with it.
        gamepad: [
            WinecxBundledFile(resource: "winebus-winecx-11.17", ext: "so", path: "lib/wine/x86_64-unix/winebus.so",
                              sha256: "6223c035c824c90708abbc3e733f8d1d6ed6b8b4e9a3e1a5c813493ceba50473"),
            WinecxBundledFile(resource: "winebus-winecx-11.17", ext: "sys",
                              path: "lib/wine/x86_64-windows/winebus.sys",
                              sha256: "da108d1c3788fa32807ef08c4d26d8a89812c230317ffa7ba5111e126bda607c"),
            sdl,
        ],
        // ws2_32.dll: winecx e0aa380's PE half with ws2_32-patch/winecx-own-hostname.patch.
        network: [
            WinecxBundledFile(resource: "ws2_32-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/ws2_32.dll",
                              sha256: "cb0a5670ce6dbf949ed25cca54e9f1c4930cd4c2ade895836d518d3d9073079c"),
        ],
        // crypt32.dll, wintrust.dll: winecx e0aa380's PE halves with
        // ngx-signer-patch/winecx-ngx-signer.patch.
        nvidia: [
            WinecxBundledFile(resource: "crypt32-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/crypt32.dll",
                              sha256: "27b485cc2a6bf651d8d72173e5d40dbc914666d3f8e8f6a4031a91c5ff22ebbf"),
            WinecxBundledFile(resource: "wintrust-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/wintrust.dll",
                              sha256: "256f3b7106cb8f7f390e1551f209bfb72ccf43744d6d583e5664e44d7602bfee"),
            // nvapi-shim/: a native nvapi64 that reports a newer NVIDIA driver than
            // Apple's 561.09 and passes everything else to Apple's nvapi.dll.
            WinecxBundledFile(resource: "nvapi64-shim", ext: "dll",
                              path: "lib/notproton-backends/nvapi-shim/x86_64-windows/nvapi64.dll",
                              sha256: "a80aea6347a8b1e72542e458f410d37fdedb39e194c0fcee45a5ae6cd7f571be"),
            // win32u.so: runtime 4.7.3's, with NVIDIA's DriverVersion 35.0.15.9541 (595.41) by
            // win32u-patch/patch-driver-version.sh, signed ad hoc.
            WinecxBundledFile(resource: "win32u-winecx-11.17", ext: "so",
                              path: "lib/wine/x86_64-unix/win32u.so",
                              sha256: "b012382d09b2ff1b3c0750d93867f72dd04a7c902bc4179be406b6c558ab162d"),
            // wined3d.dll: winecx e0aa380's PE half with wined3d-patch/winecx-driver-version.patch
            // (NOTPROTON_DRIVER_VERSION replaces the GeForce 8 era driver version d3d9 reports).
            WinecxBundledFile(resource: "wined3d-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/wined3d.dll",
                              sha256: "9298c83d927b3b80d0fa36f52bb5f2ecd60ec4daffff3c93d9b080293e59dfe9"),
        ],
        // winecoreaudio.so: winecx e0aa380 with winecoreaudio-patch/winecx-render-buffer.patch,
        // signed ad hoc under the runtime's identifier.
        audio: [
            WinecxBundledFile(resource: "winecoreaudio-winecx-11.17", ext: "so",
                              path: "lib/wine/x86_64-unix/winecoreaudio.so",
                              sha256: "680b267e8cf41af0868de4adf7f6760615a434a4be06b4ab0cfeece2d9240faa"),
        ],
        // d3dx11_43.dll, d3dx11_42.dll: winecx e0aa380's PE halves, both arches, with
        // d3dx11-patch/winecx-create-thread-pump.patch.
        d3dx: [
            WinecxBundledFile(resource: "d3dx11_43-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/d3dx11_43.dll",
                              sha256: "7d23cdfacc922f67dfa2eba98df277ae2ae351ad3646c3191a84966b55dbbfd3"),
            WinecxBundledFile(resource: "d3dx11_43-winecx-11.17-i386", ext: "dll",
                              path: "lib/wine/i386-windows/d3dx11_43.dll",
                              sha256: "dd4dd351f2a5880c9848d5ccf4944a0b5e7622bb7fb196544115b1f9c92d749c"),
            WinecxBundledFile(resource: "d3dx11_42-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/d3dx11_42.dll",
                              sha256: "3d97e1de9000a78e27eb5c90d0ab9b36d54fd350760063da27226d22c90c8e1b"),
            WinecxBundledFile(resource: "d3dx11_42-winecx-11.17-i386", ext: "dll",
                              path: "lib/wine/i386-windows/d3dx11_42.dll",
                              sha256: "85075f8b4f30f1a993238a0d6ab772a3a3df6c031e87ee9401c4367a527cd57c"),
        ],
        // kernel32.dll, kernelbase.dll: winecx e0aa380's PE halves with
        // hide-wine-exports-patch/winecx-hide-wine-exports.patch.
        loader: [
            WinecxBundledFile(resource: "kernel32-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/kernel32.dll",
                              sha256: "9cffe153abd3f91f7157f936377baac47c5aef9fa807e263a0f9e051c6010af3"),
            WinecxBundledFile(resource: "kernelbase-winecx-11.17", ext: "dll",
                              path: "lib/wine/x86_64-windows/kernelbase.dll",
                              sha256: "4d55600b204724046567688ca96132e49e53af1baac7a362f3e2bf285f669a8a"),
        ],
        runner: RunnerBuild(
            bundleVersion: "winecx-11.17",
            releaseVersion: "WineCX 11.17",
            flavor: nil,
            loaderSHA256: "a680abba30b4888355adb39d8b62255e43546eb33d163897260627f7741ef648",
            cleanNtdll: [
                .x86_64Windows: "8b32c9f6f71b4f15fcaccb19b0f2adab9391ae73ad539cae9e136f8ee7d24128",
                .i386Windows: "cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9",
            ],
            patchedNtdll: [
                .x86_64Windows: "4573d521671a48212670e7543aa9ebf0921e383dada69477f677f435df2bef5a",
                .i386Windows: "628d08854dc42009f63dc489005c2a49a3f1fe4c6a949dc1ac505915004e5b70",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-winecx-11.17", flavor: .rosetta, display: "WineCX 11.17 (msync, D3DMetal)"),
            ],
            isFree: true
        ),
        ntdllPatches: [
            // From ntdll-patch/resolve.py on the archive's ntdlls, payloads from build.sh and
            // build32.sh with the variant winecx-11.17. Both detours fit in .text padding.
            NtdllPatch(
                arch: .x86_64Windows,
                payloadResource: "detour2-winecx-11.17",
                payloadSHA256: "e1bbd185b19de3e23d627ae3a8bf25ed1b767bff5690102c5312a5ed3813e736",
                caveRVA: 0x83360,
                payloadRVA: 0x83360,
                hooks: [
                    NtdllHook(rva: 0x52de3,
                              stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]),
                ],
                caveSize: 3232,
                cavePad: 0x00,
                machine: 0x8664,
                magic: 0x20b,
                imageBase: 0x1_7000_0000
            ),
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32-winecx-11.17",
                payloadSHA256: "085df281ffe81c2803f44dd30df885248e5510c8560f0f20a5ae36e8446f7559",
                caveRVA: 0x808a0,
                payloadRVA: 0x808a0,
                hooks: [
                    NtdllHook(rva: 0x4f880, stolen: [0xf6, 0x45, 0xb4, 0x02, 0x75, 0x29]),
                ],
                caveSize: 1888,
                cavePad: 0x00,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000
            ),
        ]
    )

    // runtime 4.5.125 is the last wine1115 build (winecx 5b45f45, built from winecx-gptk
    // 7a0349b, minos 26.0). The same bytes are mirrored on dappermint/Whisky, which is what
    // Whisky itself downloads. It keeps the bridgeplay-proton-winecx tool.
    static let v1115 = WinecxRelease(
        build: "winecx-11.15",
        runtime: "4.5.125",
        archive: "Libraries.tar.gz",
        sha256: "6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87",
        bases: [
            URL(string: "https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.5.125")!,
            URL(string: "https://github.com/dappermint/Whisky/releases/download/v4.5.125")!,
        ],
        bundleName: "WineCX 11.15.app",
        wineTree: "Libraries/Wine",
        backends: dxvk,
        // winecx's winemac.so already exports the macdrv_functions DXMT reads, and that
        // table is unchanged between 0.80 and master, so DXMT needs no winemac-patch.
        renderer: FreeEngine.dxmt,
        d3dStock: [
            "d3d10.dll": "bcbd3fb8a59a5992bd3035babc5c046327f19cdc0669ce9e7c438c3ce3a9546d",
            "d3d11.dll": "84f5a337fdd7405bbbee5f0542427842a22aff749a3d061ba6334f10cf01dee4",
            "d3d12.dll": "c6e285308bb3241efca3d94da4746b16a526a9fb5113f61922e7bd86694bebf9",
            "dxgi.dll": "f1f24da777c65a583b29f74475c6a9464da35068d75def6cee806268def9ecbb",
        ],
        macDriver: "76d8f93839386f37e8badf0c82bb31b5ead22ac580f17896f9d2a729af0fc147",
        // winebus.so: winecx 5b45f45 built with SONAME_LIBSDL2 (docs/WINECX.md).
        gamepad: [
            WinecxBundledFile(resource: "winebus-winecx-11.15", ext: "so", path: "lib/wine/x86_64-unix/winebus.so",
                              sha256: "1bc53184f5d026ab84a26cf6ef721348fc3b028c019ff969e69eb6cf9b9d1af9"),
            sdl,
        ],
        network: [],
        nvidia: [],
        audio: [],
        d3dx: [],
        loader: [],
        // The hash-pinned loader is what makes it free, so a CrossOver install can never be
        // taken for it.
        runner: RunnerBuild(
            bundleVersion: "winecx-11.15",
            releaseVersion: "WineCX 11.15",
            flavor: nil,
            loaderSHA256: "a4b677428a6834f97f536a84d32c5da982c9a449e5d483c6be3d1c9b8f308998",
            cleanNtdll: [
                .x86_64Windows: "5710d16382c7a822ed8b1cba58d95fd86fe01905f039c296ca7224abff8f98e8",
                .i386Windows: "e1b208073c804a443e64ada577899d96a5c8eaee435813e4a30e0d143bca6e3c",
            ],
            patchedNtdll: [
                .x86_64Windows: "4efd956e573726777827cddaa89ef3b7f72d6cfd7b8e2049e41f5f5bdf4a6306",
                .i386Windows: "23ee72664f172d38d76ecb8969d5c5af7e6828864dfe298338ed0e773910bc5d",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-winecx", flavor: .rosetta, display: "WineCX 11.15 (msync, D3DMetal)"),
            ],
            isFree: true
        ),
        // From ntdll-patch/resolve.py on the archive's ntdlls, payloads from build.sh and
        // build32.sh with the variant winecx-11.15. The x86_64 hook is the CrossOver one
        // (cmp [rsp+0xf0], 0), and its .text padding holds the detour; the i386 padding does
        // not, so that one gets the appended section.
        ntdllPatches: [
            NtdllPatch(
                arch: .x86_64Windows,
                payloadResource: "detour2-winecx-11.15",
                payloadSHA256: "fde56854b9a7a32da19babe2427d19ff6a6b83de1917fe8d32aaddd2991fc6b9",
                caveRVA: 0x82b20,
                payloadRVA: 0x82b20,
                hooks: [
                    NtdllHook(rva: 0x52e43,
                              stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]),
                ],
                caveSize: 1248,
                cavePad: 0x00,
                machine: 0x8664,
                magic: 0x20b,
                imageBase: 0x1_7000_0000
            ),
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32-winecx-11.15",
                payloadSHA256: "37daf5f795535df91bc8fcbd356f22f4fd1ab379ec4acc97ddff44037d265556",
                caveRVA: 0xb9000,
                payloadRVA: 0xb9000,
                hooks: [
                    NtdllHook(rva: 0x4f7c0, stolen: [0xf6, 0x45, 0xb4, 0x02, 0x75, 0x29]),
                ],
                caveSize: 0x1000,
                cavePad: 0x00,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000,
                placement: .section
            ),
        ]
    )

    // Runtime contract with compat_run.sh: the engine root says it can run msync, and the
    // backends sit outside lib/wine, whose Direct3D builtins are Wine's own or, with
    // d3dmetal.enabled, Apple's (WinecxD3DMetal).
    static let backendsPath = "lib/notproton-backends"
    static let msyncMarkerPath = ".notproton-msync"

    static func downloads(for release: WinecxRelease = current) -> URL {
        SupportPaths.home.appending(
            path: "Library/Caches/\(SupportPaths.supportDirName)/engines/winecx-\(release.runtime)",
            directoryHint: .isDirectory
        )
    }

    static func bundle(for release: WinecxRelease = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: WinecxRelease = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return hasBackends(root: install.crossOverRoot, release: release)
    }

    static func hasBackends(root: URL, release: WinecxRelease = current) -> Bool {
        layoutProblems(root: root, release: release).isEmpty
    }

    // Every pinned file Bridgeplay lays out, relative to the engine root, with its sha256. The
    // four Direct3D DLLs D3DMetal can replace are not in here: WinecxD3DMetal.layoutProblems
    // checks them, since they are either Wine's own or links into a Game Porting Toolkit.
    static func expectedFiles(_ release: WinecxRelease = current) -> [String: String] {
        var table: [String: String] = [FreeEngine.macDriverPath: release.macDriver]
        for file in release.gamepad + release.network + release.nvidia + release.audio + release.d3dx + release.loader { table[file.path] = file.sha256 }
        for file in release.backends { table["\(backendsPath)/\(file.destination)"] = file.sha256 }
        for path in release.renderer.files.keys {
            table[release.renderer.installPath(of: path)] = release.renderer.installedHash(of: path)
        }
        return table
    }

    // Files that are absent or differ from their pin, the msync marker, and a Direct3D
    // layout that is neither stock nor a complete D3DMetal link.
    static func layoutProblems(root: URL, release: WinecxRelease = current) -> [String] {
        var problems = expectedFiles(release).filter { path, hash in
            !SignedPin.matches(root.appending(path: path), sha256: hash)
        }.keys.sorted()
        if !FileManager.default.fileExists(atPath: msyncMarker(in: root).path(percentEncoded: false)) {
            problems.append(msyncMarkerPath)
        }
        return problems + WinecxD3DMetal.layoutProblems(root: root, stock: release.d3dStock)
    }

    static func backend(_ path: String, in root: URL) -> URL {
        root.appending(path: "\(backendsPath)/\(path)")
    }

    static func msyncMarker(in root: URL) -> URL {
        root.appending(path: msyncMarkerPath)
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking WineCX"
            }
        }
    }

    static func install(
        _ release: WinecxRelease = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads(for: release), step: step, from: "GitHub",
            report: { report(.downloading($0)) }
        )
        let renderer = try await PinnedDownload.obtain(
            file: release.renderer.archive, sha256: release.renderer.sha256, bases: release.renderer.bases,
            into: FreeEngine.downloads, step: step, from: "GitHub",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        return try unpack(archive, renderer: renderer, release: release, engines: engines)
    }

    // Without a renderer archive (tests only) the engine gets no DXMT and does not count
    // as installed.
    static func unpack(
        _ archive: URL,
        renderer: URL?,
        release: WinecxRelease,
        engines: URL,
        gptkRoots: [URL] = WinecxD3DMetal.searchRoots()
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
        try FreeEngine.installMacDriver(root: root, build: release.build, sha256: release.macDriver, step: step)
        try installBundled(release.gamepad + release.network + release.nvidia + release.audio + release.d3dx + release.loader, root: root)

        let libraries = wine.deletingLastPathComponent()
        for file in release.backends {
            let source = libraries.appending(path: file.source)
            guard Digest.sha256IfPresent(source) == file.sha256 else {
                throw StepFailure(step: step, detail: "\(release.archive) has no pinned \(file.source).")
            }
            let destination = backend(file.destination, in: root)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
        // The archive's own DXMT 0.80 frontends stay out, and its winemetal pair is replaced
        // with master's: the two halves share one unix-call table and never mix versions.
        if let renderer {
            let unpacked = staging.appending(path: "renderer", directoryHint: .isDirectory)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try untar(renderer, into: unpacked)
            try FreeEngine.installRenderer(
                release.renderer, from: unpacked.appending(path: release.renderer.tree, directoryHint: .isDirectory),
                root: root, step: step)
        }
        try Data("\(release.build)\n".utf8).write(to: msyncMarker(in: root))

        // The winecx tree keeps its unix loader beside the unix libraries the way
        // CrossOver does, so like the WineHQ engine it needs no reshaping inside.
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winehq.wine.notproton.winecx",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "winecx-", with: ""),
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

        // Only links, and only to a Game Porting Toolkit the user installed. An engine
        // without one keeps Wine's own Direct3D and is complete, it just has no D3DMetal.
        WinecxD3DMetal.refresh(root: install.crossOverRoot, roots: gptkRoots)

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    // Puts each bundled file, checked against its pin, over or beside the engine's own.
    static func installBundled(_ files: [WinecxBundledFile], root: URL, bundle: Bundle = .module) throws {
        let fm = FileManager.default
        for file in files {
            let source = try bundledSource(file, in: bundle)
            let destination = root.appending(path: file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
    }

    // The app's copy of a bundled file. Each failure says which check failed (#1295 could
    // not tell a missing file from a damaged one), and the log gets the path and hashes.
    static func bundledSource(_ file: WinecxBundledFile, in bundle: Bundle = .module) throws -> URL {
        let name = "\(file.resource).\(file.ext)"
        guard let source = bundle.url(forResource: file.resource, withExtension: file.ext) else {
            AppLog.note("bundled file: \(name) not found in \(bundle.bundleURL.path(percentEncoded: false))")
            throw StepFailure(step: step, detail: "Bridgeplay is missing its \(name). Reinstall Bridgeplay.")
        }
        let path = source.path(percentEncoded: false)
        let actual: String
        do {
            actual = try Digest.sha256(of: source)
        } catch {
            AppLog.note("bundled file: \(name) at \(path) can't be read: \(error.localizedDescription)")
            throw StepFailure(step: step, detail: "Bridgeplay can't read its \(name). Reinstall Bridgeplay.")
        }
        guard actual == file.sha256 || SignedPin.matches(source, sha256: file.sha256) else {
            AppLog.note("bundled file: \(name) at \(path) has sha256 \(actual), expected \(file.sha256)")
            throw StepFailure(step: step, detail: "Bridgeplay's \(name) doesn't match its pinned checksum. Reinstall Bridgeplay.")
        }
        return source
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
