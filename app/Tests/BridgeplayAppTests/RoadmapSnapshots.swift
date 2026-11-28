import AppKit
import BridgeplayUI
import SwiftUI
import Testing

@testable import BridgeplayApp

// Renders the roadmap's UI changes to PNGs for review when NOTPROTON_SNAPSHOTS names an output
// folder. Every page reads fixture Steam libraries in a temporary folder; nothing on this Mac
// is written outside it.
@Suite("Roadmap snapshots", .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_SNAPSHOTS"] != nil),
       .serialized)
@MainActor
struct RoadmapSnapshots {

    private let out = URL(filePath: ProcessInfo.processInfo.environment["NOTPROTON_SNAPSHOTS"] ?? "/tmp", directoryHint: .isDirectory)

    // MARK: Rendering

    private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appending(path: "\(name).png"))
    }

    // An alert sheet's glass frame doesn't draw offscreen (it comes out white), so its content
    // is drawn on a plain panel in the glass's place.
    private func sheetImage(_ sheet: NSWindow, dark: Bool) throws -> NSBitmapImageRep {
        let content = try #require(sheet.contentView)
        let inner = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: inner)
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: inner.pixelsWide, pixelsHigh: inner.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let full = NSRect(x: 0, y: 0, width: inner.pixelsWide, height: inner.pixelsHigh)
        let scale = CGFloat(inner.pixelsWide) / content.bounds.width
        let shape = NSBezierPath(roundedRect: full.insetBy(dx: scale / 2, dy: scale / 2), xRadius: 22 * scale, yRadius: 22 * scale)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        shape.fill()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
        shape.lineWidth = scale
        shape.stroke()
        inner.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // A sheet is its own window: drawn over its parent, below the title bar, as macOS shows it.
    private func composite(_ base: NSBitmapImageRep, _ sheet: NSBitmapImageRep, scale: CGFloat, top: CGFloat) throws -> NSBitmapImageRep {
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let full = NSRect(x: 0, y: 0, width: base.pixelsWide, height: base.pixelsHigh)
        base.draw(in: full)
        NSColor.black.withAlphaComponent(0.25).setFill()
        full.fill(using: .sourceAtop)
        let w = CGFloat(sheet.pixelsWide), h = CGFloat(sheet.pixelsHigh)
        sheet.draw(in: NSRect(x: (full.width - w) / 2, y: full.height - top * scale - h, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    @discardableResult
    private func render(_ view: some View, _ name: String, size: CGSize,
                        status: SystemStatus = SystemStatus(), fixture: Fixture? = nil,
                        dark: Bool = true, chrome: NSWindow.StyleMask = [.borderless],
                        wait: TimeInterval = 1.0, scrollToEnd: Bool = false,
                        then: ((Fixture?) -> Void)? = nil) async throws -> Bool {
        _ = NSApplication.shared
        SnapshotLanguage.install()
        defer { SnapshotLanguage.uninstall() }
        let prefixes = fixture?.prefixes ?? Fixture.emptyPrefixes()
        let games = fixture?.games ?? GamesModel(libraries: { [] })
        let host = NSHostingView(rootView: view.environment(status).environment(prefixes).environment(games)
            .environment(\.locale, SnapshotLanguage.locale))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: chrome,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        try await settle(wait)
        var sheetShown = false
        if let then {
            then(fixture)
            try await settle(1.2)
        }
        if scrollToEnd, let content = window.contentView {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            for scroll in scrollViews(content) {
                guard let document = scroll.documentView else { continue }
                let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle(0.4)
        }
        window.displayIfNeeded()
        var rep = try capture(window)
        if let sheet = window.attachedSheet {
            sheetShown = true
            sheet.displayIfNeeded()
            let sheetRep = try sheetImage(sheet, dark: dark)
            let scale = CGFloat(rep.pixelsWide) / window.frame.width
            let titlebar = window.frame.height - window.contentLayoutRect.height
            rep = try composite(rep, sheetRep, scale: scale, top: titlebar)
            try write(sheetRep, "\(name)-sheet")
        }
        try write(rep, name)
        return sheetShown
    }

    // Suspends so main-actor work (a view's .task) runs, and spins the run loop for AppKit.
    private func settle(_ seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            spin(0.05)
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func panel(_ name: String, dark: Bool = true, _ configure: (ProgressPanel) -> Void) async throws {
        _ = NSApplication.shared
        SnapshotLanguage.install()
        defer { SnapshotLanguage.uninstall() }
        Self.useMarkAsIcon()
        let panel = ProgressPanel(title: "Bridgeplay", activates: false)
        panel.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        configure(panel)
        panel.panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.panel.orderFrontRegardless()
        defer { panel.panel.orderOut(nil) }
        try await settle(0.6)
        panel.panel.displayIfNeeded()
        try write(try capture(panel.panel), name)
    }

    // The test bundle has no app icon; the panel shows the mark the real icon is made of.
    private static func useMarkAsIcon() {
        let renderer = ImageRenderer(content: BridgeplayMark(size: 64).padding(4))
        renderer.scale = 2
        if let image = renderer.nsImage { NSApp.applicationIconImage = image }
    }

    // MARK: Fixtures

    private static let now = Date()

    private static func ready(steamOpen: Bool = true) -> StatusSnapshot {
        var health = HealthReading()
        var report = SteamHealth()
        report.mode = .active
        report.channel = "stable"
        report.written = now.addingTimeInterval(-600)
        health.health = report
        health.freshness = steamOpen ? .live : .lastStart
        var snapshot = StatusSnapshot(
            steam: .installed(version: AppVersion.bundled),
            steamRunning: steamOpen,
            updateBlocked: false,
            crossOver: [],
            runner: .ready(builds: [FreeEngineWinecx.current.build]),
            payload: PayloadState(expected: 40, present: 40, missing: [], overlayShimPresent: true,
                                  iconmakerPresent: true, appinfoPresent: true, signatureDatabase: "2026-11-20",
                                  legacyCompatPresent: 0, legacyCompatExpected: 0, manifestProblem: nil),
            installedRunners: [],
            installContent: .current,
            currentFreeEngines: [FreeEngineWinecx.current.build],
            gptkSource: "/Users/you/Library/Application Support/Bridgeplay/gptk"
        )
        snapshot.steamRunningHere = steamOpen
        snapshot.health = health
        return snapshot
    }

    private func hero(_ name: String, _ snapshot: StatusSnapshot, dark: Bool = true) async throws {
        let status = SystemStatus()
        status.snapshot = snapshot
        try await render(StatusHero(snapshot: snapshot).frame(width: 860), name, size: CGSize(width: 860, height: 170),
                   status: status, dark: dark)
    }

    // MARK: Wave 1

    @Test func statusHero() async throws {
        var paused = Self.ready(steamOpen: false)
        paused.health.paused = true
        paused.health.health?.mode = .off

        var breaker = Self.ready(steamOpen: false)
        breaker.health.health?.mode = .passive
        breaker.health.health?.strikes = 2

        var pauseList = Self.ready(steamOpen: false)
        pauseList.health.health?.mode = .passive
        pauseList.health.health?.modeReason = "pause_list"
        pauseList.health.health?.pauseFixedIn = "0.7.69"

        // RootView forces the dark appearance, so the hero is only ever seen dark.
        try await hero("F6a-hero-ready-steam-open", Self.ready())
        try await hero("F6a-hero-ready-steam-closed", Self.ready(steamOpen: false))
        try await hero("F6a-hero-paused", paused)
        try await hero("E1-hero-off-after-crash-loop", breaker)
        try await hero("E1-hero-paused-for-steam-build", pauseList)
    }

    // The whole Status page: hero, Last Launch card and the toolkit row without GPTK.
    @Test func statusPage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // This Mac's engines and Steam rows (read only), with the fixture's hero state on top.
        var snapshot = StatusSnapshot.capture(bundledVersion: AppVersion.bundled)
        let ready = Self.ready()
        snapshot.installContent = .current
        snapshot.steam = ready.steam
        snapshot.steamRunning = true
        snapshot.steamRunningHere = true
        snapshot.health = ready.health
        snapshot.gptkSource = nil
        snapshot.recentLaunches = LastLaunch.scan(libraries: fixture.libraries, now: Self.now, userdata: fixture.userdata)
        #expect(snapshot.recentLaunches.contains { $0.verdict.failed })
        let status = SystemStatus()
        status.snapshot = snapshot
        try await render(RootView(pane: .constant(.status)), "B3-status-page-last-launch",
                         size: CGSize(width: 1000, height: 1540), status: status, fixture: fixture,
                         chrome: [.titled, .fullSizeContentView])
    }

    @Test func settings() async throws {
        let status = SystemStatus()
        status.snapshot = Self.ready()
        try await render(SettingsView(), "F6b-settings", size: CGSize(width: 600, height: 640), status: status)
    }

    // The same row SettingsView builds, in the states a debug build can't reach (it has no
    // login agent, so the real page reads "Not available in this copy").
    @Test func backgroundCheckRow() async throws {
        let rows = VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Steam") {
                    StatusRow(title: String(localized: "Background Check"),
                              value: String(localized: "Alerts while Bridgeplay is closed."),
                              toggle: .constant(false))
                    StatusRow(title: String(localized: "Background Check"),
                              value: String(localized: "Alerts when Steam drops Bridgeplay."),
                              menu: [StatusAction(label: String(localized: "Auto-Restore")) {}],
                              toggle: .constant(true))
                    StatusRow(title: String(localized: "Background Check"),
                              value: String(localized: "Restores Bridgeplay after Steam quits."),
                              menu: [StatusAction(label: String(localized: "Notify Only")) {}],
                              toggle: .constant(true))
                    StatusRow(title: String(localized: "Background Check"),
                              value: String(localized: "Allow it in Login Items."),
                              tone: .warning,
                              action: StatusAction(label: String(localized: "Open Login Items")) {},
                              toggle: .constant(true))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(BP.bg)
        .font(BP.sans(13))
        .tint(BP.accent)
        try await render(rows, "E4-settings-background-check-states", size: CGSize(width: 600, height: 340))
    }

    private func wizard(_ name: String, height: CGFloat = 580, scrollToEnd: Bool = false, risks: Bool = false,
                        _ configure: (SetupAssistant) -> Void) async throws {
        let model = SetupAssistant(preview: .fresh)
        configure(model)
        try await render(SetupAssistantView(model: model, revealed: .max, showingRisks: risks), name,
                         size: CGSize(width: 780, height: height), scrollToEnd: scrollToEnd)
    }

    // Every step on a Mac that still needs setup, for reviewing the copy.
    @Test func setupSteps() async throws {
        try await wizard("S1-setup-mac") { $0.step = .mac }
        try await wizard("S2-setup-graphics") { m in
            m.step = .graphics
            m.gptk = nil
        }
        try await wizard("S3-setup-steam") { m in
            m.step = .steam
            m.steamInstalled = false
            m.steamAccess = .homeApplications
        }
        try await wizard("S3b-setup-steam-risks", risks: true) { m in
            m.step = .steam
            m.steamInstalled = true
        }
        try await wizard("S4-setup-finish") { m in
            m.step = .finish
            m.trust = .done
            m.trustInLoginKeychain = true
        }
        try await wizard("S4b-setup-app-management") { m in
            m.step = .finish
            m.tasks[0].state = .done
            m.tasks[1].state = .failed("macOS needs your permission first.")
            m.needsAppManagement = true
        }
        try await wizard("S5-setup-done") { $0.step = .done }
        try await wizard("S5b-setup-done-end", scrollToEnd: true) { $0.step = .done }
    }

    @Test func setupDeadEnds() async throws {
        try await wizard("F3-setup-full-disk") { m in
            m.step = .mac
            m.freeBytes = 1_200_000_000
        }
        try await wizard("F3-setup-steam-other-account", scrollToEnd: true) { m in
            m.step = .mac
            m.steamAccess = .otherAccount
        }
        try await wizard("F3-setup-steam-home-applications") { m in
            m.step = .steam
            m.steamInstalled = false
            m.steamAccess = .homeApplications
        }
        try await wizard("F3-setup-download-out-of-space") { m in
            m.step = .finish
            m.freeBytes = 1_200_000_000
            m.tasks[0].state = .failed(m.spaceMessage)
        }
    }

    @Test func setupWithoutToolkit() async throws {
        try await wizard("G3-setup-graphics-without-gptk") { m in
            m.step = .graphics
            m.gptk = nil
        }
        try await wizard("G3-setup-graphics-download-has-no-gptk", scrollToEnd: true) { m in
            m.step = .graphics
            m.gptk = nil
            m.toolkitAttempt = .components(.notInDownload)
            m.message = m.toolkitPlan.message
        }
        try await wizard("G3-setup-done-without-gptk") { m in
            m.step = .done
            m.gptk = nil
        }
    }

    // Prefixes page and the questions its model asks (Trash, Clear Shader Cache, no Trash).
    @Test func prefixes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.load()
        func page(_ name: String, pane: Pane = .prefixes, _ ask: ((PrefixesModel) -> Void)? = nil) async throws -> Bool {
            try await render(RootView(pane: .constant(pane)), name, size: CGSize(width: 1100, height: 640),
                       fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 2.5,
                       then: ask.map { ask in { _ in ask(fixture.prefixes) } })
        }
        _ = try await page("F5a-prefixes-page")
        let cyberpunk = try #require(fixture.prefixes.prefixes.first { $0.appID == "1091500" })
        do { let shown = try await page("F5a-prefixes-move-to-trash") { $0.pendingConfirmation = .delete([cyberpunk]) }; #expect(shown) }
        do { let shown = try await page("D5-prefixes-clear-shader-cache") { $0.pendingConfirmation = .clearShaderCache([cyberpunk]) }; #expect(shown) }
        do { let shown = try await page("F5a-prefixes-no-trash-delete-permanently") { $0.pendingConfirmation = .deletePermanently([cyberpunk], []) }; #expect(shown) }
        _ = try await page("F5b-backups-page", pane: .backups)
        let backup = try #require(fixture.prefixes.backups.first)
        do { let shown = try await page("F5b-backups-restore", pane: .backups) { $0.pendingConfirmation = .restore(backup) }; #expect(shown) }
    }

    // The report bar a finished game shows, with the new Works After a Tweak answer.
    @Test func reportBar() async throws {
        let library = SteamLibrary(root: URL(filePath: "/nonexistent"))
        let prefix = WinePrefix(appID: "292030", name: "The Witcher 3: Wild Hunt", library: library, lastUsed: nil)
        let session = GameSession(id: "s", started: Self.now.addingTimeInterval(-5_400), ended: Self.now,
                                  exitStatus: 0, stoppedBySteam: true)
        try await render(PlayReportCard(nudge: PlayReports.Nudge(prefix: prefix, session: session)).frame(width: 980),
                   "A5-report-bar-works-after-a-tweak", size: CGSize(width: 980, height: 80))
    }

    // MARK: Wave 2

    @Test func games() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.load()
        try await render(RootView(pane: .constant(.games)), "F4a-games-page",
                         size: CGSize(width: 1100, height: 560), fixture: fixture,
                         chrome: [.titled, .fullSizeContentView], wait: 2.5)
        try await render(RootView(pane: .constant(.games)), "F4a-games-page-800",
                         size: CGSize(width: 800, height: 560), fixture: fixture,
                         chrome: [.titled, .fullSizeContentView], wait: 2.5)
        let empty = try Fixture(games: false)
        defer { empty.remove() }
        await empty.load()
        try await render(RootView(pane: .constant(.games)), "F4a-games-page-empty", size: CGSize(width: 1100, height: 480),
                   fixture: empty, chrome: [.titled, .fullSizeContentView], wait: 1.5)
    }

    @Test func uninstall() async throws {
        let home = URL(filePath: "/Users/you", directoryHint: .isDirectory)
        func item(_ path: String, _ bytes: Int64? = nil, note: String? = nil) -> UninstallItem {
            UninstallItem(url: home.appending(path: path), bytes: bytes, note: note)
        }
        let internalLibrary = SteamLibrary(root: home.appending(path: "Library/Application Support/Steam"), volume: "Macintosh HD")
        let external = SteamLibrary(root: URL(filePath: "/Volumes/Games SSD/SteamLibrary"), volume: "Games SSD")
        let plan = UninstallPlan(
            remove: [
                item("Library/Application Support/Bridgeplay", 1_840_000_000),
                item("Library/Application Support/Steam/compatibilitytools.d/\(FreeEngineWinecx.currentTool ?? "")", 912_000_000),
                item("Library/Application Support/Steam/compatibilitytools.d/Bridgeplay-DXMT", 64_000_000),
                item("Library/LaunchAgents/com.bridgeplay.Bridgeplay.background.plist", 1_214),
                item("Library/Caches/com.bridgeplay.Bridgeplay", 38_000_000),
                item("Library/Preferences/com.bridgeplay.Bridgeplay.plist", 3_480),
            ],
            steamModified: true,
            steamKeptOffline: true,
            prefixes: [
                UninstallPrefix(prefix: WinePrefix(appID: "1091500", name: "Cyberpunk 2077", library: internalLibrary, lastUsed: nil), bytes: 1_420_000_000),
                UninstallPrefix(prefix: WinePrefix(appID: "292030", name: "The Witcher 3: Wild Hunt", library: external, lastUsed: nil), bytes: 812_000_000),
                UninstallPrefix(prefix: WinePrefix(appID: "1145360", name: "Hades", library: internalLibrary, lastUsed: nil), bytes: 356_000_000),
            ],
            keeps: [
                item("Applications/Bridgeplay.app", note: String(localized: "Trash it after it quits")),
                item("Library/Application Support/Bridgeplay Gamefixes", 2_100_000, note: nil),
            ],
            otherUsers: ["Steven"]
        )
        try await render(UninstallPlanSheet(plan: plan) { _ in }, "I11-uninstall-plan", size: CGSize(width: 520, height: 700))
        try await render(UninstallPlanSheet(plan: plan) { _ in }, "I11-uninstall-plan-prefixes", size: CGSize(width: 520, height: 700),
                         scrollToEnd: true)

        let checklist = UninstallChecklist(
            removed: plan.remove, trashed: [UninstallItem(url: plan.prefixes[2].prefix.root)],
            remains: [item("Applications/Bridgeplay.app", note: String(localized: "Trash it after it quits"))],
            otherUsers: ["Steven"],
            verification: UninstallVerification(signature: .valve, app: URL(filePath: "/Applications/Steam.app"),
                                                leftInSteam: [], leftForUser: []))
        try await render(UninstallChecklistSheet(checklist: checklist) {}, "I11-uninstall-checklist", size: CGSize(width: 520, height: 640))
    }

    // The launch panel's question after two minutes with no window, and what follows.
    @Test func launchPanels() async throws {
        let message = LaunchProgress.message(game: "The Witcher 3: Wild Hunt")
        try await panel("B1-launch-panel-waiting") { $0.show(message: message, phase: LaunchProgress.phase(.start)) }
        try await panel("B1-launch-panel-keep-waiting-or-stop") {
            $0.show(message: message, phase: LaunchProgress.phase(.start), note: LaunchProgress.hangNote, buttons: [
                PanelButton(title: String(localized: "Stop Game")) {},
                PanelButton(title: String(localized: "Keep Waiting")) {},
            ])
        }
        try await panel("B1-launch-panel-stopping") { $0.show(message: message, phase: LaunchProgress.stopping) }

        // LaunchEndedPanel.present's layout: why it stopped, with a next step.
        func ended(_ name: String, _ code: String, seconds: Int, game: String) async throws {
            let record = try #require(LaunchRecord.parse(
                "code=\(code)\nexit=1\nseconds=\(seconds)\nstopped=game\nended=\(Int(Self.now.timeIntervalSince1970))\n"))
            let ending = try #require(LaunchEnding(record: record, now: Self.now))
            try await panel(name) {
                $0.show(message: ending.verdict.sentence, phase: "\(game) · \(LastLaunch.duration(seconds: ending.seconds))", buttons: [
                    PanelButton(title: String(localized: "Close")) {},
                    PanelButton(title: ending.button) {},
                ])
            }
        }
        try await ended("B1-launch-ended-crashed", "crashed", seconds: 95, game: "The Witcher 3: Wild Hunt")
        try await ended("A1-launch-ended-anti-cheat", "anticheat_driver", seconds: 4, game: "Apex Legends")
    }

    // MARK: Every screen at the window's default and minimum sizes

    private static func engine(_ release: WinecxRelease) -> CrossOverInstall {
        CrossOverInstall(bundle: URL(filePath: "/Users/you/Library/Application Support/Bridgeplay/engines/\(release.bundleName)"),
                         releaseVersion: release.runner.releaseVersion, support: .supported(release.runner), isEngine: true)
    }

    // Ready, with the previous WineCX set up and the current one offered (or both set up).
    private static func engines(current: Bool) -> StatusSnapshot {
        var snapshot = ready()
        snapshot.crossOver = (current ? [engine(FreeEngineWinecx.current)] : []) + [engine(FreeEngineWinecx.previous)]
        let builds = snapshot.crossOver.compactMap { FreeEngineStatus.buildID(of: $0) }
        snapshot.runner = .ready(builds: builds)
        snapshot.currentFreeEngines = Set(builds)
        snapshot.installedRunners = (current ? [FreeEngineWinecx.current.runner] : []) + [FreeEngineWinecx.previous.runner]
        return snapshot
    }

    private static let sizes: [(String, CGSize)] = [("900", CGSize(width: 900, height: 760)), ("800", CGSize(width: 800, height: 600))]

    @Test func heroUpgradeOffer() async throws {
        try await hero("U1-hero-upgrade-offer-steam-open", Self.engines(current: false))
        var closed = Self.engines(current: false)
        closed.steamRunning = false
        closed.steamRunningHere = false
        closed.health.freshness = .lastStart
        try await hero("U1-hero-upgrade-offer-steam-closed", closed)
    }

    @Test func screens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.load()
        for current in [false, true] {
            var snapshot = Self.engines(current: current)
            snapshot.recentLaunches = LastLaunch.scan(libraries: fixture.libraries, now: Self.now, userdata: fixture.userdata)
            let status = SystemStatus()
            status.snapshot = snapshot
            let tag = current ? "both-engines" : "upgrade-offer"
            for (width, size) in Self.sizes {
                try await render(RootView(pane: .constant(.status)), "U2-status-\(tag)-\(width)", size: size, status: status,
                                 fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 1.5)
            }
            try await render(RootView(pane: .constant(.status)), "U2-status-\(tag)-full", size: CGSize(width: 900, height: 2200),
                             status: status, fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 1.5)
            try await render(RootView(pane: .constant(.status)), "U2-status-\(tag)-full-800", size: CGSize(width: 800, height: 2300),
                             status: status, fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 1.5)
        }
        let status = SystemStatus()
        status.snapshot = Self.engines(current: false)
        for pane in [Pane.games, .gameDefaults, .prefixes, .backups, .guide] {
            for (width, size) in Self.sizes {
                try await render(RootView(pane: .constant(pane)), "U3-\(pane.rawValue)-\(width)", size: size, status: status,
                                 fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 2.0)
            }
        }
        try await render(RootView(pane: .constant(.gameDefaults)), "U3-gameDefaults-full", size: CGSize(width: 900, height: 2000),
                         status: status, fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 2.0)
        try await render(RootView(pane: .constant(.guide)), "U3-guide-full", size: CGSize(width: 900, height: 2600),
                         status: status, fixture: fixture, chrome: [.titled, .fullSizeContentView], wait: 2.0)
        try await render(SettingsView(), "U4-settings-full", size: CGSize(width: 600, height: 1100), status: status)
    }
}

// Two Steam libraries with six games in a temporary folder, and the models reading them.
@MainActor
private final class Fixture {
    let root: URL
    let internalLibrary: SteamLibrary
    let external: SteamLibrary
    let prefixes: PrefixesModel
    let games: GamesModel
    var libraries: [SteamLibrary] { [internalLibrary, external] }
    var userdata: URL { root.appending(path: "userdata") }
    var caches: URL { root.appending(path: "caches") }

    static func emptyPrefixes() -> PrefixesModel {
        PrefixesModel(libraries: { [] }, installedTools: { [] },
                      rebuild: { _, _, _ in nil }, makeBackup: { _ in URL(filePath: "/nonexistent") },
                      trash: { _ in throw CocoaError(.featureUnsupported) }, caches: nil)
    }

    init(games withGames: Bool = true) throws {
        root = URL.temporaryDirectory.appending(path: "bp-roadmap-shots-\(UUID().uuidString)")
        internalLibrary = SteamLibrary(root: root.appending(path: "Steam"), volume: "Macintosh HD")
        external = SteamLibrary(root: root.appending(path: "SteamLibrary"), volume: "Games SSD")
        let fm = FileManager.default
        for library in [internalLibrary, external] {
            try fm.createDirectory(at: library.compatdata, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appending(path: "caches"), withIntermediateDirectories: true)
        let libs = [internalLibrary, external]
        let tools = [InstalledTool(tool: CompatTool(name: "winecx-11.17", flavor: .rosetta, display: "Bridgeplay (WineCX 11.17)"), build: "winecx-11.17")]
        let cacheRoot = root.appending(path: "caches")
        prefixes = PrefixesModel(libraries: { libs }, installedTools: { tools },
                                 rebuild: { _, _, _ in nil }, makeBackup: { _ in URL(filePath: "/nonexistent") },
                                 trash: { _ in throw CocoaError(.featureUnsupported) }, caches: cacheRoot)
        let user = root.appending(path: "userdata")
        games = GamesModel(libraries: { libs }, userdata: user, iconCache: root.appending(path: "librarycache"))
        guard withGames else { return }

        let now = Date()
        try game("1091500", "Cyberpunk 2077", in: internalLibrary, mb: 46, used: now.addingTimeInterval(-3 * 3600),
                 record: "code=ok\nexit=0\nseconds=5400\nstopped=steam\nbackend=d3dmetal\nengine=winecx-11.17\nwindow=21\n",
                 ended: now.addingTimeInterval(-3 * 3600), shaderMB: 12, backup: now.addingTimeInterval(-6 * 86400))
        try game("292030", "The Witcher 3: Wild Hunt", in: external, mb: 31, used: now.addingTimeInterval(-5 * 3600),
                 record: "code=crashed\nexit=5\nseconds=95\nstopped=game\nbackend=dxmt-builtin\nengine=winecx-11.17\nwindow=18\n",
                 ended: now.addingTimeInterval(-5 * 3600), shaderMB: 4)
        try game("570940", "DARK SOULS: REMASTERED", in: internalLibrary, mb: 18, used: now.addingTimeInterval(-20 * 3600),
                 record: "code=quit_early\nexit=0\nseconds=12\nstopped=game\nbackend=dxvk\nengine=winecx-11.17\nwindow=\n",
                 ended: now.addingTimeInterval(-20 * 3600))
        try game("1172470", "Apex Legends", in: external, mb: nil, used: nil,
                 record: "code=anticheat_driver\nstopped=game\n", ended: now.addingTimeInterval(-26 * 3600))
        try game("1145360", "Hades", in: internalLibrary, mb: 9, used: now.addingTimeInterval(-2 * 86400),
                 record: "code=ok\nexit=0\nseconds=3100\nstopped=steam\nbackend=d3dmetal\nengine=winecx-11.17\nwindow=6\n",
                 ended: now.addingTimeInterval(-2 * 86400))
        try game("489830", "The Elder Scrolls V: Skyrim Special Edition", in: external, mb: 22,
                 used: now.addingTimeInterval(-12 * 86400), record: nil, ended: nil)
    }

    private func game(_ appID: String, _ name: String, in library: SteamLibrary, mb: Int?, used: Date?,
                      record: String?, ended: Date?, shaderMB: Int = 0, backup: Date? = nil) throws {
        let fm = FileManager.default
        try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"installdir\"\t\t\"\(name)\"\n}\n".utf8)
            .write(to: library.steamapps.appending(path: "appmanifest_\(appID).acf"))
        let folder = library.compatdata.appending(path: appID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let record, let ended {
            try Data((record + "ended=\(Int(ended.timeIntervalSince1970))\n").utf8)
                .write(to: folder.appending(path: LaunchRecord.fileName))
        }
        if let mb {
            let pfx = folder.appending(path: "pfx")
            try fm.createDirectory(at: pfx.appending(path: "drive_c/users/steamuser"), withIntermediateDirectories: true)
            try Data(count: mb * 1_000_000).write(to: pfx.appending(path: "system.reg"))
            try Data("winecx-11.17\nBridgeplay (WineCX 11.17)\n".utf8).write(to: folder.appending(path: PrefixTools.buildRecordName))
            if let used { try fm.setAttributes([.modificationDate: used], ofItemAtPath: pfx.path(percentEncoded: false)) }
        }
        if let backup {
            let stamp = PrefixStore.backupClock().string(from: backup)
            let kept = folder.appending(path: "\(PrefixStore.backupPrefix)-\(stamp)")
            try fm.createDirectory(at: kept, withIntermediateDirectories: true)
            try Data(count: 40_000_000).write(to: kept.appending(path: "system.reg"))
        }
        if shaderMB > 0 {
            let cache = ShaderCache.launcherCache(appID: appID, caches: caches)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(count: shaderMB * 1_000_000).write(to: cache.appending(path: "shaders.bin"))
        }
    }

    func load() async {
        await prefixes.load()
        await games.load()
    }

    nonisolated func remove() { try? FileManager.default.removeItem(at: root) }
}
