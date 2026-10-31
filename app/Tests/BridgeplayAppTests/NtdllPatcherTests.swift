import Foundation
import Testing

@testable import BridgeplayApp

// A stand-in PE with one file-backed section and one with nothing behind it, so the section
// walk and every refusal run without CrossOver. Deliberately not an identity mapping.
private struct StubPE {
    static let peOffset = 0x80
    static let sectionVirtualAddress = 0x1000
    static let sectionRawOffset = 0x400
    static let sectionSize = 0x4000

    // A .bss style section placed before the real one, to prove it is skipped rather
    // than matched.
    static let bssVirtualAddress = 0x200
    static let bssSize = 0x200

    static let imageSize = sectionVirtualAddress + sectionSize
    static let tableEnd = peOffset + 24 + 0xf0 + 2 * 40

    static func rva(forOffset offset: Int) -> Int {
        sectionVirtualAddress + (offset - sectionRawOffset)
    }

    static func make(machine: UInt16, magic: UInt16, imageBase: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectionRawOffset + sectionSize)

        write(&bytes, 0x3c, UInt32(peOffset))
        write(&bytes, peOffset, UInt32(0x0000_4550))
        write(&bytes, peOffset + 4, machine)

        let optionalSize: UInt16 = 0xf0
        write(&bytes, peOffset + 6, UInt16(2))
        write(&bytes, peOffset + 20, optionalSize)
        write(&bytes, peOffset + 24, magic)

        write(&bytes, peOffset + 24 + 36, UInt32(0x200))
        write(&bytes, peOffset + 24 + 56, UInt32(imageSize))
        write(&bytes, peOffset + 24 + 60, UInt32(sectionRawOffset))

        if magic == 0x20b {
            write(&bytes, peOffset + 24 + 24, imageBase)
        } else {
            write(&bytes, peOffset + 24 + 28, UInt32(truncatingIfNeeded: imageBase))
        }

        let table = peOffset + 24 + Int(optionalSize)
        write(&bytes, table + 8, UInt32(bssSize))
        write(&bytes, table + 12, UInt32(bssVirtualAddress))
        write(&bytes, table + 16, UInt32(0))
        write(&bytes, table + 20, UInt32(0))

        write(&bytes, table + 40 + 8, UInt32(sectionSize))
        write(&bytes, table + 40 + 12, UInt32(sectionVirtualAddress))
        write(&bytes, table + 40 + 16, UInt32(sectionSize))
        write(&bytes, table + 40 + 20, UInt32(sectionRawOffset))

        return Data(bytes)
    }

    private static func write<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
        }
    }
}

@Suite("ntdll patcher")
struct NtdllPatcherTests {

    private let stolen: [UInt8] = [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]

    private func stubPatch(caveSize: Int = 0x100, cavePad: UInt8 = 0) -> NtdllPatch {
        NtdllPatch(
            arch: .x86_64Windows,
            payloadResource: "detour2",
            payloadSHA256: "unused",
            caveRVA: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x800),
            payloadRVA: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x800),
            hooks: [
                NtdllHook(rva: StubPE.rva(forOffset: StubPE.sectionRawOffset + 0x100), stolen: stolen)
            ],
            caveSize: caveSize,
            cavePad: cavePad,
            machine: 0x8664,
            magic: 0x20b,
            imageBase: 0x1_7000_0000
        )
    }

    private func stubImage() -> Data {
        var bytes = [UInt8](StubPE.make(machine: 0x8664, magic: 0x20b, imageBase: 0x1_7000_0000))
        let hookOffset = StubPE.sectionRawOffset + 0x100
        for (index, byte) in stolen.enumerated() { bytes[hookOffset + index] = byte }
        return Data(bytes)
    }

    // MARK: - The patch itself

    @Test("A patch writes the detour into the cave and a reachable jump at the hook")
    func patchWritesBothSites() throws {
        let patch = stubPatch()
        let payload = Data([0x90, 0x91, 0x92, 0x93])
        let result = [UInt8](try NtdllPatcher.apply(patch, to: stubImage(), payload: payload))

        let caveOffset = StubPE.sectionRawOffset + 0x800
        #expect(Array(result[caveOffset ..< caveOffset + 4]) == [0x90, 0x91, 0x92, 0x93])

        let hookOffset = StubPE.sectionRawOffset + 0x100
        #expect(result[hookOffset] == 0xe9)

        let displacement = result[(hookOffset + 1) ..< (hookOffset + 5)]
            .reversed()
            .reduce(Int32(0)) { $0 << 8 | Int32($1) }
        #expect(Int(displacement) == patch.payloadRVA - (patch.hooks[0].rva + 5))

        // The stolen bytes past the jump are int3, not left as the tail of the
        // instruction that was overwritten.
        #expect(Array(result[(hookOffset + 5) ..< (hookOffset + stolen.count)]) == [0xcc, 0xcc, 0xcc, 0xcc])
    }

    @Test("A padding cave keeps the file length, because a PE cannot absorb inserted bytes")
    func patchDoesNotResize() throws {
        let patch = stubPatch()
        let image = stubImage()
        let result = try NtdllPatcher.apply(patch, to: image, payload: Data(repeating: 0x90, count: 64))
        #expect(result.count == image.count)
    }

    private func sectionPatch() -> NtdllPatch {
        let base = stubPatch()
        return NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: StubPE.imageSize, payloadRVA: StubPE.imageSize, hooks: base.hooks,
            caveSize: 0x1000, cavePad: 0, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase, placement: .section
        )
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        bytes[offset ..< offset + 4].reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    @Test("A section cave appends one executable page and jumps into it")
    func sectionPlacementAppendsPage() throws {
        let patch = sectionPatch()
        let image = stubImage()
        let payload = Data([0x90, 0x91, 0x92, 0x93])
        let result = [UInt8](try NtdllPatcher.apply(patch, to: image, payload: payload))

        #expect(result.count == image.count + 0x1000)
        #expect(result[StubPE.peOffset + 6] == 3)
        #expect(u32(result, StubPE.peOffset + 24 + 56) == StubPE.imageSize + 0x1000)

        let header = StubPE.tableEnd
        #expect(Array(result[header ..< header + 8]) == Array(".npdet".utf8) + [0, 0])
        #expect(u32(result, header + 8) == 0x1000)
        #expect(u32(result, header + 12) == StubPE.imageSize)
        #expect(u32(result, header + 16) == 0x1000)
        #expect(u32(result, header + 20) == image.count)
        #expect(u32(result, header + 36) == 0x6000_0020)
        #expect(Array(result[image.count ..< image.count + 4]) == [0x90, 0x91, 0x92, 0x93])

        let hookOffset = StubPE.sectionRawOffset + 0x100
        #expect(result[hookOffset] == 0xe9)
        #expect(Int(Int32(truncatingIfNeeded: u32(result, hookOffset + 1)))
            == patch.payloadRVA - (patch.hooks[0].rva + 5))
    }

    @Test("A section cave pinned somewhere other than the image end is refused")
    func sectionPlacementNeedsImageEnd() throws {
        let base = sectionPatch()
        let moved = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: base.caveRVA + 0x1000, payloadRVA: base.caveRVA + 0x1000, hooks: base.hooks,
            caveSize: base.caveSize, cavePad: 0, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase, placement: .section
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(moved, to: stubImage(), payload: Data([0x90]))
        }
    }

    @Test("A section cave with no free header slot is refused, so a second patch cannot stack")
    func sectionPlacementNeedsFreeHeader() throws {
        var bytes = [UInt8](stubImage())
        bytes[StubPE.tableEnd] = 0x2e
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(sectionPatch(), to: Data(bytes), payload: Data([0x90]))
        }
    }

    @Test("A section header slot truncated despite SizeOfHeaders is refused", arguments: [0, 1, 39])
    func sectionPlacementNeedsCompleteHeader(bytesPresent: Int) throws {
        let image = Data(stubImage().prefix(StubPE.tableEnd + bytesPresent))
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(sectionPatch(), to: image, payload: Data([0x90]))
        }
    }

    // MARK: - Refusals

    @Test("A hook site holding something else is refused")
    func wrongStolenBytesRefused() throws {
        let patch = stubPatch()
        var bytes = [UInt8](stubImage())
        bytes[StubPE.sectionRawOffset + 0x100] = 0x90

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: Data(bytes), payload: Data([0x90]))
        }
    }

    @Test("A cave with anything in it is refused, so a second patch cannot stack")
    func occupiedCaveRefused() throws {
        let patch = stubPatch()
        let payload = Data(repeating: 0x90, count: 32)
        let once = try NtdllPatcher.apply(patch, to: stubImage(), payload: payload)

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: once, payload: payload)
        }
    }

    @Test("A detour larger than the cave is refused rather than overrunning it")
    func oversizePayloadRefused() throws {
        let patch = stubPatch(caveSize: 16)
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: stubImage(), payload: Data(repeating: 0x90, count: 17))
        }
    }

    @Test("A mismatched machine, optional header or image base is refused")
    func headerMismatchRefused() throws {
        let patch = stubPatch()
        let payload = Data([0x90])

        let wrongMachine = StubPE.make(machine: 0x14c, magic: 0x20b, imageBase: 0x1_7000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongMachine, payload: payload) }

        let wrongMagic = StubPE.make(machine: 0x8664, magic: 0x10b, imageBase: 0x1_7000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongMagic, payload: payload) }

        let wrongBase = StubPE.make(machine: 0x8664, magic: 0x20b, imageBase: 0x1_8000_0000)
        #expect(throws: StepFailure.self) { try NtdllPatcher.apply(patch, to: wrongBase, payload: payload) }
    }

    @Test("A truncated file is refused instead of read past its end")
    func truncatedFileRefused() throws {
        let patch = stubPatch()
        let image = stubImage().prefix(StubPE.sectionRawOffset)

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(patch, to: Data(image), payload: Data([0x90]))
        }
    }

    // The size check on its own read an address below the cave as extra room rather than as
    // being outside it, so the detour was written into the code in front of the cave.
    @Test("A detour addressed below its cave is refused")
    func detourBelowItsCaveRefused() throws {
        let base = stubPatch()
        let below = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: base.caveRVA, payloadRVA: base.caveRVA - 0x100, hooks: base.hooks,
            caveSize: base.caveSize, cavePad: base.cavePad, machine: base.machine,
            magic: base.magic, imageBase: base.imageBase
        )

        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(below, to: stubImage(), payload: Data(repeating: 0x90, count: 0x10))
        }
    }

    @Test("An RVA in no mapped section is refused, including one inside an unbacked section")
    func unmappedRVARefused() throws {
        let base = stubPatch()
        let payload = Data([0x90])

        let beyond = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: 0x9000_0000, payloadRVA: 0x9000_0000, hooks: base.hooks, caveSize: base.caveSize,
            cavePad: base.cavePad, machine: base.machine, magic: base.magic, imageBase: base.imageBase
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(beyond, to: stubImage(), payload: payload)
        }

        // Inside the .bss style section, which has no file offset to resolve to.
        let unbacked = NtdllPatch(
            arch: base.arch, payloadResource: base.payloadResource, payloadSHA256: base.payloadSHA256,
            caveRVA: StubPE.bssVirtualAddress + 0x10, payloadRVA: StubPE.bssVirtualAddress + 0x10,
            hooks: base.hooks,
            caveSize: base.caveSize, cavePad: base.cavePad, machine: base.machine, magic: base.magic,
            imageBase: base.imageBase
        )
        #expect(throws: StepFailure.self) {
            try NtdllPatcher.apply(unbacked, to: stubImage(), payload: payload)
        }
    }

    // MARK: - Shipped payloads

    @Test("Both detour payloads ship and match the hashes they were built with")
    func shippedPayloadsMatch() throws {
        for build in SupportedRunners.all {
            for patch in NtdllPatcher.patches(for: build) {
                let payload = try NtdllPatcher.payload(for: patch)
                #expect(!payload.isEmpty)
                #expect(Digest.sha256(of: payload) == patch.payloadSHA256)
            }
        }
    }

    // A build is patched only where it has both a hash and offsets. A patch without a hash
    // runs against an unverified input, a hash without a patch promises one that never runs.
    @Test("Every build's patches line up with the arches it records hashes for")
    func patchesMatchRecordedArches() {
        for build in SupportedRunners.all {
            let patched = Set(NtdllPatcher.patches(for: build).map(\.arch))
            #expect(patched == Set(build.cleanNtdll.keys))
            #expect(patched == Set(build.patchedNtdll.keys))
        }
        #expect(!NtdllPatcher.patches(for: SupportedRunners.all[0]).isEmpty)
    }

    // MARK: - Against the real thing

    // The point of the port: the same input has to come out as the bytes apply.py and
    // apply32.py produced, which SupportedRunners records. Needs an unpatched CrossOver.
    @Test("Patching the unpatched ntdll reproduces the recorded hashes", arguments: [
        URL(filePath: "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver"),
        URL(filePath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
        // The free engine, once Bridgeplay or NOTPROTON_WINEHQ_ROOT has provided one.
        ProcessInfo.processInfo.environment["NOTPROTON_WINEHQ_ROOT"].map { URL(filePath: $0) }
            ?? SupportPaths.crossOverRoot(inBundle: FreeEngine.bundle()),
    ])
    func realNtdllReproducesRecordedHashes(root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)),
              let installed = Digest.sha256IfPresent(CrossOverSource.unixLoader(inRoot: root)),
              let build = SupportedRunners.build(loaderSHA256: installed)
        else { return }

        var reproduced: [WineArch] = []
        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: root, arch: patch.arch)
            guard let hash = Digest.sha256IfPresent(source), hash == build.cleanNtdll[patch.arch] else {
                continue
            }

            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
            reproduced.append(patch.arch)
        }

        // The bundle was identified by its loader, so every arch with a clean hash is present
        // and a run that reproduced fewer skipped rather than passed.
        #expect(reproduced.count == build.cleanNtdll.count)
    }

    // Every supported build, not whichever is installed. Refusal runs on synthetic bytes, so
    // a build's patches are checkable on a machine that could never run it.
    @Test("An input that is not the pinned build is refused before anything is written")
    func unpinnedInputRefused() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "bridgeplay-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "ntdll.dll")
        try Data(repeating: 0, count: 1024).write(to: source)

        var checked = 0
        for build in SupportedRunners.all {
            for patch in NtdllPatcher.patches(for: build) {
                let destination = directory.appending(path: "out-\(build.id)-\(patch.arch.rawValue).dll")
                #expect(throws: StepFailure.self) {
                    try NtdllPatcher.write(patch, build: build, from: source, to: destination)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test("A missing input is refused by name")
    func missingInputRefused() throws {
        let source = URL(filePath: NSTemporaryDirectory()).appending(path: "bridgeplay-absent-\(UUID().uuidString)")

        var checked = 0
        for build in SupportedRunners.all {
            for patch in NtdllPatcher.patches(for: build) {
                #expect(throws: StepFailure.self) {
                    try NtdllPatcher.write(patch, build: build, from: source, to: source)
                }
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    // The bridge here came out of apply.py and apply32.py, so staging from the same clone has
    // to be byte identical. A clean ntdll cannot be a fixture, so no runner means skip.
    private static func cleanRunnerRoot(for build: RunnerBuild) -> URL? {
        let root = SupportPaths.clonedRoot(forBuild: build.id)
        guard FileManager.default.fileExists(
            atPath: root.appending(path: "lib/wine").path(percentEncoded: false)
        ) else { return nil }

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: root, arch: patch.arch)
            guard Digest.sha256IfPresent(source) == build.cleanNtdll[patch.arch] else {
                return nil
            }
        }
        return root
    }

    @Test("Staging reproduces the bridge the python patcher produced")
    func stagingReproducesExistingBridge() throws {
        for build in SupportedRunners.all {
            guard let root = Self.cleanRunnerRoot(for: build) else { continue }
            try Self.expectStagingReproducesBridge(build: build, root: root)
        }
    }

    private static func expectStagingReproducesBridge(build: RunnerBuild, root: URL) throws {
        let fm = FileManager.default

        let scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "bridgeplay-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }

        try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: scratch)

        var compared: [WineArch] = []
        for patch in NtdllPatcher.patches(for: build) {
            let staged = NtdllPatcher.stagedCopy(of: patch.arch, build: build.id, in: scratch)
            let existing = NtdllPatcher.stagedCopy(of: patch.arch, build: build.id)

            #expect(Digest.sha256IfPresent(staged) == build.patchedNtdll[patch.arch])
            guard let live = Digest.sha256IfPresent(existing) else { continue }
            #expect(Digest.sha256IfPresent(staged) == live)
            compared.append(patch.arch)
        }

        // A staged bridge that matched nothing is a test that skipped. Asked per build rather
        // than against a fixed arch, so a bridge of another flavor does not stand this down.
        let bridgeHoldsThisBuild = build.patchedNtdll.keys.contains { arch in
            Digest.sha256IfPresent(NtdllPatcher.stagedCopy(of: arch, build: build.id)) != nil
        }
        if bridgeHoldsThisBuild {
            #expect(compared.count == build.patchedNtdll.count)
        }
    }

    @Test("Staging a second time writes nothing, so it is safe on every install")
    func stagingIsIdempotent() throws {
        for build in SupportedRunners.all {
            guard let root = Self.cleanRunnerRoot(for: build) else { continue }
            let fm = FileManager.default

            let scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "bridgeplay-stage-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: scratch) }

            // One file per patch the build defines. A build pins the arches its loader can map,
            // never all of WineArch: an x86_64 loader has no aarch64 guest.
            let first = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: scratch)
            #expect(first.count == NtdllPatcher.patches(for: build).count)

            let second = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: scratch)
            #expect(second.isEmpty)
        }
    }

    @Test("The clean source prefers the one time backup over a live file")
    func cleanSourcePrefersBackup() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "bridgeplay-root-\(UUID().uuidString)")
        let directory = root.appending(path: "lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let live = directory.appending(path: "ntdll.dll")
        try Data([0x00]).write(to: live)
        #expect(NtdllPatcher.cleanSource(inRoot: root, arch: .x86_64Windows) == live)

        let backup = directory.appending(path: "ntdll.dll.notproton-orig")
        try Data([0x00]).write(to: backup)
        #expect(NtdllPatcher.cleanSource(inRoot: root, arch: .x86_64Windows) == backup)
    }
}

@Suite("ntdll staging")
struct NtdllStagingTests {

    // A build whose patched hashes are the files already in the bridge, so staging has nothing
    // to write and the only thing under test is what it leaves behind.
    private func stagedBridge() throws -> (bridge: URL, build: RunnerBuild) {
        let bridge = FileManager.default.temporaryDirectory
            .appending(path: "np-bridge-\(UUID().uuidString)")

        var hashes: [WineArch: String] = [:]
        for arch in WineArch.allCases {
            let directory = bridge.appending(path: "wine/27.0.0.40921/\(arch.rawValue)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "ntdll.dll")
            try Data("staged \(arch.rawValue)".utf8).write(to: file)
            hashes[arch] = try Digest.sha256(of: file)
        }

        let build = RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: nil,
            loaderSHA256: "unused",
            cleanNtdll: [:],
            patchedNtdll: [
                .x86_64Windows: hashes[.x86_64Windows]!,
                .i386Windows: hashes[.i386Windows]!,
            ]
        )
        return (bridge, build)
    }

    @Test("Staging drops an ntdll left in the bridge for an arch this build does not patch")
    func stagingPrunesForeignArches() throws {
        let (bridge, build) = try stagedBridge()
        defer { try? FileManager.default.removeItem(at: bridge) }

        let written = try NtdllPatcher.stage(
            build: build, runnerRoot: bridge.appending(path: "unused"), bridge: bridge
        )
        #expect(written.isEmpty)

        let fm = FileManager.default
        for arch in [WineArch.x86_64Windows, .i386Windows] {
            let kept = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)
            #expect(fm.fileExists(atPath: kept.path(percentEncoded: false)))
        }

        let foreign = NtdllPatcher.stagedCopy(of: .aarch64Windows, build: build.id, in: bridge)
        #expect(!fm.fileExists(atPath: foreign.path(percentEncoded: false)))
    }

    @Test("Restaging installed builds reports a build it cannot stage and carries on")
    func stageInstalledCollectsFailures() throws {
        let (bridge, build) = try stagedBridge()
        defer { try? FileManager.default.removeItem(at: bridge) }
        let broken = SupportedRunners.all[0]

        let failures = NtdllPatcher.stageInstalled(
            builds: [broken, build], runners: bridge.appending(path: "runners"), bridge: bridge
        )

        #expect(failures.map(\.build) == [broken.id])
        #expect(FileManager.default.fileExists(atPath: NtdllPatcher.stagedCopy(
            of: .x86_64Windows, build: build.id, in: bridge).path(percentEncoded: false)))
    }

    @Test("Pruning keeps the listed builds and drops every other entry under wine")
    func pruneKeepsListedBuilds() throws {
        let (bridge, build) = try stagedBridge()
        defer { try? FileManager.default.removeItem(at: bridge) }
        let fm = FileManager.default
        let other = bridge.appending(path: "wine/26.3.0.39832")
        let legacy = bridge.appending(path: "wine/x86_64-windows")
        for directory in [other, legacy] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        NtdllPatcher.pruneBuilds(keeping: [build.id], in: bridge)

        #expect(fm.fileExists(atPath: NtdllPatcher.stagedCopy(
            of: .x86_64Windows, build: build.id, in: bridge).path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: other.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: legacy.path(percentEncoded: false)))
    }
}

@Suite("Pinned patch payloads")
struct PinnedPatchPayloadTests {

    @Test("Every pinned patch ships a payload that matches its pin")
    func everyPinnedPayloadResolves() throws {
        for (buildID, patches) in NtdllPatcher.byBuild {
            for patch in patches {
                #expect(throws: Never.self, "\(buildID) \(patch.arch.rawValue)") {
                    _ = try NtdllPatcher.payload(for: patch)
                }
            }
        }
    }

    @Test("Every pinned payload fits inside the cave it is written to")
    func everyPinnedPayloadFitsItsCave() throws {
        for (buildID, patches) in NtdllPatcher.byBuild {
            for patch in patches {
                let payload = try NtdllPatcher.payload(for: patch)
                let where_ = "\(buildID) \(patch.arch.rawValue)"
                #expect(patch.payloadRVA >= patch.caveRVA, "\(where_) starts before its cave")
                let end = patch.payloadRVA + payload.count
                #expect(end <= patch.caveRVA + patch.caveSize, "\(where_) overruns its cave")
            }
        }
    }
}
