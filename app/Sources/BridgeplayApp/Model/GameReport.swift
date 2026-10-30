import AppKit
import IOKit.ps
import SystemConfiguration

// What a compatibility report says about this Mac and the game's last launch, and the
// redaction its public log copy goes through. Sent by PlayReports.
enum GameReport {

    // The options of the Mac chip and memory dropdowns in .github/ISSUE_TEMPLATE/game-report.yml,
    // so reports from the app and from the form read the same.
    static let chips = ["M1", "M1 Pro", "M1 Max", "M1 Ultra", "M2", "M2 Pro", "M2 Max", "M2 Ultra",
                        "M3", "M3 Pro", "M3 Max", "M3 Ultra", "M4", "M4 Pro", "M4 Max",
                        "M5", "M5 Pro", "M5 Max"]
    static let memorySizes = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]
    static let backends = ["dxmt", "dxvk", "wined3d", "d3dmetal"]

    struct Machine: Equatable {
        var chip: String
        var memoryBytes: UInt64
        var macOS: String
        var bridgeplay: String
        var model: String? = nil
        var setup: [String: String] = [:]
        // A newer release the updater found, "0.7.38 (55)".
        var newerRelease: String?
    }

    static var thisMac: Machine {
        Machine(chip: SetupChecks.chipName, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                macOS: SetupChecks.macOSDisplay,
                bridgeplay: ProductVersion.build.map { "\(ProductVersion.short) (\($0))" } ?? ProductVersion.short,
                model: sysctl("hw.model"),
                newerRelease: LatestRelease.newer(than: ProductVersion.build))
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    // Facts about the Mac when the report is made, which is soon after the game ran:
    // displays: "2: built-in 3456x2234 120 Hz, 2560x1440 60 Hz", lowPower: "on"/"off",
    // thermal: "nominal"…"critical", power: "battery"/"plugged in", gpuCores: "16".
    @MainActor static func setup() -> [String: String] {
        let screens = NSScreen.screens.map { screen -> String in
            let pixels = screen.convertRectToBacking(screen.frame).size
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let builtIn = id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            return "\(builtIn ? "built-in " : "")\(Int(pixels.width))x\(Int(pixels.height)) \(screen.maximumFramesPerSecond) Hz"
        }
        var setup = ["lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"]
        if !screens.isEmpty { setup["displays"] = "\(screens.count): " + screens.joined(separator: ", ") }
        setup["thermal"] = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            setup["power"] = type == kIOPSBatteryPowerValue ? "battery" : "plugged in"
        }
        let gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if gpu != 0 {
            defer { IOObjectRelease(gpu) }
            if let cores = IORegistryEntryCreateCFProperty(gpu, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                setup["gpuCores"] = String(cores)
            }
        }
        return setup
    }

    // Whether the game's prefix runs in Retina mode, so a game can render at the display's full
    // pixel size (displays) instead of half: the biggest resolution factor behind a low frame rate.
    static func retina(_ userReg: String) -> String {
        var inDriver = false
        for line in userReg.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") { inDriver = line.hasPrefix(#"[Software\\Wine\\Mac Driver]"#) }
            else if inDriver, line.hasPrefix(#""RetinaMode"="#) { return line.lowercased().contains(#"="y""#) ? "on" : "off" }
        }
        return "off"
    }

    // "Apple M5 Max" → "M5 Max"; a chip the form doesn't list is "Other".
    static func chip(_ brand: String) -> String {
        let name = brand.replacingOccurrences(of: "Apple ", with: "").trimmingCharacters(in: .whitespaces)
        return chips.contains(name) ? name : "Other"
    }

    static func memory(_ bytes: UInt64) -> String {
        let gb = Int((Double(bytes) / 1_073_741_824).rounded())
        return memorySizes.contains(gb) ? "\(gb) GB" : "Other"
    }

    // The engine and backend of the most recent launch in bridgeplay-run.log:
    //   runner: build winecx-11.17 (WineCX 11.17 (msync, D3DMetal)) at /…
    //   graphics: backend=d3dmetal (carried over from the last launch)
    // A run aborted before launch (another tool picked to try a fix, refused by the prefix
    // check) never ran the game, so it does not replace the run before it. A log of nothing
    // but aborted runs still names what was tried.
    static func lastLaunch(in log: String) -> (engine: String?, backend: String?) {
        var engine: String?, backend: String?
        var run: (engine: String?, backend: String?) = (nil, nil)
        var aborted = false
        var tried: (engine: String?, backend: String?) = (nil, nil)
        func finishRun() {
            tried = (run.engine ?? tried.engine, run.backend ?? tried.backend)
            if !aborted {
                engine = run.engine ?? engine
                backend = run.backend ?? backend
            }
            run = (nil, nil)
            aborted = false
        }
        for line in log.split(separator: "\n") {
            if line.hasPrefix("=== bridgeplay run ") {
                finishRun()
            } else if line.hasPrefix("runner: build "), let open = line.firstIndex(of: "("),
               let close = line.range(of: ") at ", options: .backwards) {
                run.engine = String(line[line.index(after: open)..<close.lowerBound])
            } else if line.hasPrefix("graphics: backend=") {
                let value = line.dropFirst("graphics: backend=".count).prefix { !$0.isWhitespace }
                if backends.contains(String(value)) { run.backend = String(value) }
            } else if line.hasPrefix("=== aborted ") {
                aborted = true
            }
        }
        finishRun()
        return (engine ?? tried.engine, backend ?? tried.backend)
    }

    // Reports are public. Besides the home folder, run logs carry the Steam account name
    // and a video token in the passed-through Steam environment, the SteamID64 in Steam API
    // lines, the macOS user name in lsof output, and external drive names in library paths.
    // DSB_TOKEN only appears in logs from 0.7.51 and earlier, which can still be attached.
    static func redacted(_ log: String, home: String = NSHomeDirectory(), user: String = NSUserName(),
                         computerNames: [String] = thisMacNames) -> String {
        var text = home.isEmpty ? log : log.replacingOccurrences(of: home, with: "~")
        let rules: [(String, String)] = [
            (#"(?m)^(SteamUser|SteamAppUser|STEAMVIDEOTOKEN|DSB_TOKEN)=.*$"#, "$1=<redacted>"),
            (#"\b7656119\d{10}\b"#, "<steamid>"),
            (#"\[U:1:\d+\]"#, "[U:1:<redacted>]"),
            // The account ID, which is the SteamID64 less a constant.
            (#"(?i)(userdata[/\\]+)\d+"#, "$1<id>"),
            (#"[\w.+-]{1,64}@[\w-]{1,63}(\.[\w-]{1,63})+"#, "<email>"),
            (#"/Volumes/(?!Preboot/|Macintosh HD/)[^/\n:]+"#, "/Volumes/<drive>"),
            // Wine's view of a home folder whose name differs from the account name.
            (#"(?i)\b([A-Za-z]:\\+Users\\+)(?!(?:crossover|public|steamuser)\b)[^\\\s:'"]+"#, "$1<user>"),
            // Any other Mac home folder: another account, or the home path spelled differently.
            (#"(?<![\w.~])/Users/(?!Shared(?=[/\s:'"]|$))[^/\s:'"]+"#, "/Users/<user>"),
        ]
        for name in [user] + computerNames where name.count >= 3 {
            text = text.replacingOccurrences(of: #"\b\#(NSRegularExpression.escapedPattern(for: name))\b"#,
                                             with: name == user ? "<user>" : "<computer>",
                                             options: [.regularExpression, .caseInsensitive])
        }
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    // Wine's lines for a process that crashed or could not start, as exit_crash_lines in
    // compat_run.sh matches them.
    static let wineErrorPattern =
        #"Unhandled (page fault|exception|illegal instruction|stack overflow)|^wine: (Call from|could not|cannot|failed)|err:module:(import_dll|LdrInitializeThunk)|wine client error"#

    static func wineErrorLines(in text: Substring, limit: Int) -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n") where found.count < limit {
            // The cheap test first: a long log has hundreds of thousands of lines.
            guard line.contains("Unhandled") || line.hasPrefix("wine: ") || line.contains("err:module:")
                    || line.contains("wine client error"),
                  line.range(of: wineErrorPattern, options: .regularExpression) != nil else { continue }
            let kept = String(line.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.contains(kept) { found.append(kept) }
        }
        return found
    }

    // The newest `limit` characters of a Wine log. Wine's error lines from the part that
    // doesn't fit go first, so a crash early in a long session still reaches the report.
    static func wineTail(_ log: String, limit: Int) -> String {
        guard log.count > limit else { return log }
        // The heading takes room from the tail, and the part that gives way is searched too.
        var keep = limit
        while true {
            let cut = log.index(log.endIndex, offsetBy: -keep)
            let early = wineErrorLines(in: log[..<cut], limit: 20)
            guard !early.isEmpty else { return String(log[cut...]) }
            let head = "--- Wine error lines from earlier in this log ---\n" + early.joined(separator: "\n")
                + "\n--- end of the log ---\n"
            if head.count + keep <= limit { return head + String(log[cut...]) }
            if keep == 0 { return String(head.prefix(limit)) }
            keep = max(0, limit - head.count)
        }
    }

    static var thisMacNames: [String] {
        [SCDynamicStoreCopyComputerName(nil, nil), SCDynamicStoreCopyLocalHostName(nil)]
            .compactMap { $0 as String? }
    }
}
