// Allow list of CrossOver builds the runner clones from. The ntdll hook sites
// are hardcoded RVAs, so a build not pinned here would be patched at the wrong
// offsets. New builds go in after running ntdll-patch/resolve.py and pinning
// the hashes.

import Foundation

enum WineArch: String, Sendable, CaseIterable {
    case x86_64Windows = "x86_64-windows"
    case i386Windows = "i386-windows"
    case aarch64Windows = "aarch64-windows"
}

struct RunnerBuild: Sendable, Equatable, Identifiable {
    // CFBundleVersion, which also names the directory under runners/ and keys
    // the ntdll hash tables. Changing it orphans an installed runner.
    let bundleVersion: String

    // CFBundleShortVersionString. CrossOver inverts the usual pair and sets this
    // to the build date, so it is the string the download page shows. Display
    // only, never identity.
    let releaseVersion: String

    let flavor: String?

    let loaderSHA256: String

    let cleanNtdll: [WineArch: String]
    let patchedNtdll: [WineArch: String]

    var tools: [CompatTool] = []

    // A free WineHQ engine Bridgeplay downloads itself rather than a CrossOver
    // install. It has no license to check.
    var isFree = false

    // A CrossOver Preview build. Its release version is the build date.
    var isPreview = false

    var rebuilds: [RunnerRebuild] = []

    var id: String { flavor.map { "\(bundleVersion)-\($0)" } ?? bundleVersion }

    func matching(loaderSHA256 hash: String) -> RunnerBuild? {
        if hash == loaderSHA256 { return self }
        guard let rebuild = rebuilds.first(where: { $0.loaderSHA256 == hash }) else { return nil }
        return RunnerBuild(
            bundleVersion: bundleVersion, releaseVersion: releaseVersion, flavor: flavor,
            loaderSHA256: rebuild.loaderSHA256, cleanNtdll: rebuild.cleanNtdll,
            patchedNtdll: rebuild.patchedNtdll, tools: tools, isFree: isFree, isPreview: isPreview, rebuilds: rebuilds
        )
    }

    var flavorName: String { flavor?.uppercased() ?? "Rosetta" }

    var displayVersion: String { "\(releaseVersion) \(flavorName)" }
}

// The version of CrossOver offered in China has different hashes but is identical in the ways that matter
struct RunnerRebuild: Sendable, Equatable {
    let loaderSHA256: String
    let cleanNtdll: [WineArch: String]
    let patchedNtdll: [WineArch: String]
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }

        // CrossOver's FEX build needs Tahoe. Its Rosetta tool runs on Sequoia.
        static let fexAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    let name: String
    let flavor: Flavor
    let display: String

    var id: String { name }

    var prefixArch: PrefixArch { flavor == .fex ? .arm64 : .x86_64 }
}

struct InstalledTool: Sendable, Hashable, Identifiable {
    let tool: CompatTool
    let build: String

    var id: String { tool.name }
    var name: String { tool.name }
    var display: String { tool.display }
}

enum SupportedRunners {

    // First entry is what windows-only games get when Steam has no mapping.
    static let toolPreference = [
        legacyToolName, "bridgeplay-proton-fex", "bridgeplay-proton-fex-rosetta", "bridgeplay-proton-preview",
        "bridgeplay-proton-fex-41069", "bridgeplay-proton-fex-rosetta-41069", "bridgeplay-proton-preview-41069",
        "bridgeplay-proton-fex-41073", "bridgeplay-proton-fex-rosetta-41073", "bridgeplay-proton-preview-41073", "bridgeplay-proton-26.3", "bridgeplay-proton-winecx-11.17",
        "bridgeplay-proton-winecx", "bridgeplay-proton-winehq",
    ]

    // The single tool name 1.0.x used, 'notproton' before 3.0.
    static let legacyToolName = "bridgeplay-proton"

    // The only builds that can own the 'bridgeplay-proton' tool name.
    static let legacyHolders = ["27.0.0.40921-fex", "27.0.0.40921", "27.0.0.41069-fex", "27.0.0.41069"]

    enum LegacyHolder: Equatable, Sendable {
        case build(String)
        case nobody
    }

    static func tools(
        for builds: [RunnerBuild], legacy: LegacyHolder = .nobody,
        fexAvailable: Bool = CompatTool.Flavor.fexAvailable, keeping kept: Set<String> = []
    ) -> [InstalledTool] {
        let installed = Set(builds.map(\.id))
        let holder: String? = switch legacy {
        case .build(let id): id
        case .nobody: nil
        }
        let served = all.filter { installed.contains($0.id) }.flatMap { build in
            build.tools.enumerated().map { index, tool in
                let name = build.id == holder && index == 0 ? legacyToolName : tool.name
                return InstalledTool(
                    tool: CompatTool(name: name, flavor: tool.flavor, display: tool.display), build: build.id
                )
            }
        }.filter { $0.tool.flavor != .fex || fexAvailable || kept.contains($0.name) }
        func rank(_ tool: InstalledTool) -> Int {
            toolPreference.firstIndex(of: tool.name) ?? toolPreference.count
        }
        return served.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static let all: [RunnerBuild] = [
        RunnerBuild(
            bundleVersion: "26.3.0.39832",
            releaseVersion: "26.3",
            flavor: nil,
            loaderSHA256: "b5edb0444b5b25ba0aa5091be1cba11680130895c338cc8044101bce98802a63",
            cleanNtdll: [
                .x86_64Windows: "6dff64c00793ce92124f1316985c63783f539f26b392975c70f57637458d2387",
                .i386Windows: "2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2",
            ],
            patchedNtdll: [
                .x86_64Windows: "c0e21a9a5250f0a97c08d3c3e1798566255387213e2553b1e555264fb9ded97e",
                .i386Windows: "e641d7b2e81ee13877823494679ba2d87e0d61b8a87e8a1ce92b4fe73631ae74",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-26.3", flavor: .rosetta, display: "CrossOver 26.3"),
            ],
            rebuilds: [
                // crossoverchina.com
                RunnerRebuild(
                    loaderSHA256: "35aeb1a75a48f3b053dbf2395deac33c530a0b0b7db0bc6357362348af9514ce",
                    cleanNtdll: [
                        .x86_64Windows: "1c4799bb3769ba1392c2298e4904ce0b080f040940b2a273f4eaa0906b231a93",
                        .i386Windows: "21e7d0a6d6868f1853489f5a9798e706509a20a65ee370f50b37ab7b1cdcaae3",
                    ],
                    patchedNtdll: [
                        .x86_64Windows: "3725117cc103acd9d2713535e41733563f340e27604e1abdea5afbdc2c2be65a",
                        .i386Windows: "6d9ef05089fea07d1f4cbebe27df1f9a92dbc8eb245033db9f5e40a943175d5b",
                    ]
                ),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: nil,
            loaderSHA256: "b59d5fdccb62d425230a4e4d157c50c25b63ff586832c60cc5b12b4d6053ab80",
            cleanNtdll: [
                .x86_64Windows: "04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377",
                .i386Windows: "94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b",
            ],
            patchedNtdll: [
                .x86_64Windows: "b6a98622fb8f7e6a998bc038f442b17d257da3df5e9e135f0c35f7bbc46ea5d6",
                .i386Windows: "25bfde1f50ee96485763968ef10b9d9ad35e38214232f17ebdc009b098af44a0",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-preview", flavor: .rosetta, display: "CrossOver 2026 08 21-X86 - Rosetta"),
            ],
            isPreview: true
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: "fex",
            loaderSHA256: "7a6ea337c9caf2217454bec9537371e5d8ca302406bbed40b65316c1a636c4ab",
            cleanNtdll: [
                .x86_64Windows: "f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58",
                .i386Windows: "09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7",
                .aarch64Windows: "7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071",
            ],
            patchedNtdll: [
                .x86_64Windows: "fa8cd8fe7c4c19effade92d55b00fa946b630ab13cbb6721076848238c1dcf6a",
                .i386Windows: "e799ea02418294588ee353a90b967358be316a3044ff9515b28aa1ce07e63981",
                .aarch64Windows: "f40810193a5ef2520774288f354a8604f5ba91828315f643b3ee6688b873dc3f",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-fex", flavor: .fex, display: "CrossOver 2026 08 21-ARM64 - FEX"),
                CompatTool(name: "bridgeplay-proton-fex-rosetta", flavor: .rosetta, display: "CrossOver 2026 08 21-ARM64 - Rosetta"),
            ],
            isPreview: true
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41069",
            releaseVersion: "20261006",
            flavor: nil,
            loaderSHA256: "8286bfd0c6d2ae337e11784926d371a9f7ed7e8da870bd2f435c2bce8eb3c148",
            cleanNtdll: [
                .x86_64Windows: "5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9",
                .i386Windows: "e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3",
            ],
            patchedNtdll: [
                .x86_64Windows: "9569625387cf179d306b004c556273e2ec15811b2cfd51f21d078e2a0aa06f7f",
                .i386Windows: "0d8e3ebb57b3173f675eef5e3a0950052c592efa10a7a10193b0beb811b55ea5",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-preview-41069", flavor: .rosetta, display: "CrossOver 2026 10 06-X86 - Rosetta"),
            ],
            isPreview: true
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41069",
            releaseVersion: "20261006",
            flavor: "fex",
            loaderSHA256: "ef2b9a0ad185d8caa2960a97c135a75b8b85ca62425599e35cf672f787fba64c",
            cleanNtdll: [
                .x86_64Windows: "1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e",
                .i386Windows: "66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5",
                .aarch64Windows: "77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852",
            ],
            patchedNtdll: [
                .x86_64Windows: "7548abd874656f6a6455e7fac659020ed755d92f4e1929a33097bbde964699f5",
                .i386Windows: "e16b0199db721a08201b1512476b9eff255624d2faf3696fa57ff74b1a54be5c",
                .aarch64Windows: "7623c0b33350f511b431d39c7ec0c0d4f5def4183acef0eee5d4a5c694898956",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-fex-41069", flavor: .fex, display: "CrossOver 2026 10 06-ARM64 - FEX"),
                CompatTool(name: "bridgeplay-proton-fex-rosetta-41069", flavor: .rosetta, display: "CrossOver 2026 10 06-ARM64 - Rosetta"),
            ],
            isPreview: true
        ),
        RunnerBuild(
            bundleVersion: "winehq-11.15",
            releaseVersion: "WineHQ 11.15",
            flavor: nil,
            loaderSHA256: "8aa25e55f28a0634a7df04c02dd719d4bc20de645cf42b9ba7d0e3b7d8f66a80",
            cleanNtdll: [
                .x86_64Windows: "682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2",
                .i386Windows: "49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1",
            ],
            patchedNtdll: [
                .x86_64Windows: "08a825e8236e79c909fae3934ca5e8a195a344d06f8affb6e13cdf1bd9ffa783",
                .i386Windows: "88f9a1d16dd7127100eab902156390ec2a5ec67770cfddd3fd3f1237c9965309",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-winehq", flavor: .rosetta, display: "WineHQ 11.15 - Rosetta"),
            ],
            isFree: true
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41073",
            releaseVersion: "20261015",
            flavor: nil,
            loaderSHA256: "57144ccad16e75a171d48ea4b20974183e76c1cd5f5022bfc4b8917016b126b5",
            cleanNtdll: [
                .x86_64Windows: "f489347e59d4e8b43c2b0d2abbff9ee31e2059d45fd75fc04e2f4c0d8b04464a",
                .i386Windows: "5249b95eea6df765257b2e5212831f511d8f66134abe3c231b8e73d8f5b4707e",
            ],
            patchedNtdll: [
                .x86_64Windows: "901bff9138707d90efecc592bd9bd3062075a350add4b3a283b089c1da635a61",
                .i386Windows: "7d3df0ee9dd61693293ba74a8d2c588b4dce26fb7f7a78c0c5ed5bdc58869e14",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-preview-41073", flavor: .rosetta, display: "CrossOver 2026 10 15-X86 - Rosetta"),
            ],
            isPreview: true
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41073",
            releaseVersion: "20261015",
            flavor: "fex",
            loaderSHA256: "f4cedebfb30efc1e91e46ee25296abeb526fe7d814041d7cc6ca693bd4b8cb7b",
            cleanNtdll: [
                .x86_64Windows: "3d24426735defd222fd9518b094b738dc1c12afd13efc41a855013ed0f825129",
                .i386Windows: "3ee764335e50709285361e2542731385f0b06e593a76aa84a3c328c278164c4f",
                .aarch64Windows: "a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408",
            ],
            patchedNtdll: [
                .x86_64Windows: "2b47ed8c19d1d15d0f82519d39d64bf34113b285c4ada325bb64c5e587326d33",
                .i386Windows: "3f4b0d9589c1f374e3c2fd135263f2bf3c8300e09dd010fd778936dd71e894ad",
                .aarch64Windows: "2efb13f3303adc2c8ee61b93e027e4e94730a2e6b0162c7e6aebd4104200f07c",
            ],
            tools: [
                CompatTool(name: "bridgeplay-proton-fex-41073", flavor: .fex, display: "CrossOver 2026 10 15-ARM64 - FEX"),
                CompatTool(name: "bridgeplay-proton-fex-rosetta-41073", flavor: .rosetta, display: "CrossOver 2026 10 15-ARM64 - Rosetta"),
            ],
            isPreview: true
        ),
    ] + FreeEngineWinecx.runnerBuilds

    static func build(loaderSHA256 hash: String) -> RunnerBuild? {
        all.lazy.compactMap { $0.matching(loaderSHA256: hash) }.first
    }

    static func build(id: String) -> RunnerBuild? {
        all.first { $0.id == id }
    }

    static func displayVersion(forID id: String) -> String {
        build(id: id)?.displayVersion ?? id
    }

    // The CrossOver versions to tell someone to use, for a row already titled CrossOver:
    // "26.3 or Preview 20260821, 20261006, or 20261015". Free engines aren't CrossOver.
    static var crossOverVersions: String {
        let crossOver = all.filter { !$0.isFree }
        let releases = versions(of: crossOver.filter { !$0.isPreview })
        let previews = versions(of: crossOver.filter(\.isPreview))
        var named = releases.isEmpty ? [] : [releases.formatted(.list(type: .or))]
        if !previews.isEmpty { named.append("Preview \(previews.formatted(.list(type: .or)))") }
        return named.formatted(.list(type: .or))
    }

    static var freeEngineVersions: String {
        versions(of: all.filter(\.isFree)).formatted(.list(type: .or))
    }

    static var versionList: String {
        versions(of: all).joined(separator: ", ")
    }

    // Release versions in table order, each once (flavors of a build share one).
    private static func versions(of builds: [RunnerBuild]) -> [String] {
        var seen = Set<String>()
        return builds.map(\.releaseVersion).filter { seen.insert($0).inserted }
    }
}
