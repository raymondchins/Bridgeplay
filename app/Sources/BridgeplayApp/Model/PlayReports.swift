import Foundation
import Observation

// One-tap compatibility reports. After a game session the app asks how it ran; the answer
// goes to bridgeplay.dev/api/report, which posts it to GitHub Discussions for the player, so
// no GitHub account is needed. With auto-share on, sessions whose outcome is clear from the
// log are reported without asking.
struct ReportPayload: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case tap, auto }

    var appid: String
    var status: ReportStatus
    var install: String
    var source: Source
    var name: String
    var chip: String
    var memory: String
    var macos: String
    var version: String
    var engine: String?
    var backend: String?
    var session: String
    // What the player wrote after Has Issues or Didn't Run, and a few facts about the Mac
    // (GameReport.setup). Older endpoints ignore both.
    var note: String?
    var issue: ReportIssue?
    var model: String?
    var setup: [String: String]?
    var log: String?
    var wineLog: String?

    // Newest lines kept. These count characters, not bytes, so encoded() is what keeps the
    // JSON under the endpoint's 1 MB cap.
    static let logLimit = 550_000
    static let wineLogLimit = 350_000
    static let maximumEncodedSize = 1_000_000

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        let full = try encoder.encode(self)
        guard full.count > Self.maximumEncodedSize else { return full }

        var trimmed = self
        trimmed.log = nil
        trimmed.wineLog = nil
        var result = try encoder.encode(trimmed)
        guard result.count <= Self.maximumEncodedSize else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Report metadata exceeds the upload limit."))
        }

        var lower = 0
        var upper = max(log?.count ?? 0, wineLog?.count ?? 0)
        while lower <= upper {
            let limit = lower + (upper - lower) / 2
            trimmed.log = log.map { String($0.suffix(limit)) }
            trimmed.wineLog = wineLog.map { GameReport.wineTail($0, limit: limit) }
            let candidate = try encoder.encode(trimmed)
            if candidate.count <= Self.maximumEncodedSize {
                result = candidate
                lower = limit + 1
            } else {
                upper = limit - 1
            }
        }
        return result
    }

    static func make(name: String, appID: String, status: ReportStatus, source: Source, session: GameSession,
                     log: String?, wineLog: String?, machine: GameReport.Machine, install: String,
                     note: String? = nil, issue: ReportIssue? = nil) -> ReportPayload {
        let launch: (engine: String?, backend: String?) = log.map(GameReport.lastLaunch) ?? (nil, nil)
        var summary = session.summary(log: log, wineLog: wineLog)
        if let newer = machine.newerRelease { summary += ". A newer Bridgeplay was out: \(newer)" }
        if source == .auto { summary += ". Status inferred from the log" }
        return ReportPayload(
            appid: appID, status: status, install: install, source: source, name: name,
            chip: GameReport.chip(machine.chip), memory: GameReport.memory(machine.memoryBytes),
            macos: machine.macOS, version: machine.bridgeplay, engine: launch.engine, backend: launch.backend,
            session: summary,
            note: note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(1000)) },
            issue: status == .bronze ? issue : nil,
            model: machine.model,
            setup: machine.setup.isEmpty ? nil : machine.setup,
            log: log.map { String(GameReport.redacted($0).suffix(logLimit)) },
            wineLog: wineLog.map { GameReport.wineTail(GameReport.redacted($0), limit: wineLogLimit) })
    }
}

// Sends reports, keeping each one on disk until the endpoint takes it, so a report made
// offline goes out on a later scan.
struct ReportSender: Sendable {

    enum Outcome: Equatable { case sent, retryLater, dropped }

    var endpoint: URL
    var queue: URL
    var session: URLSession = .shared
    var retryAfter: TimeInterval = 15 * 60

    static let defaultEndpoint = URL(string: "https://bridgeplay.dev/api/report")!

    // `defaults write <bundle id> ReportEndpoint <url>` points a build at a test server.
    static var standard: ReportSender {
        let custom = UserDefaults.standard.string(forKey: "ReportEndpoint").flatMap(URL.init(string:))
        return ReportSender(endpoint: custom ?? defaultEndpoint, queue: SupportPaths.support.appending(path: "reports-pending"))
    }

    func submit(_ payload: ReportPayload) async -> Outcome {
        let body: Data
        do {
            body = try payload.encoded()
        } catch {
            AppLog.note("play report: could not encode the report: \(error.localizedDescription)")
            return .dropped
        }
        let file = queue.appending(path: "\(payload.appid)-\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
            try body.write(to: file, options: .atomic)
        } catch {
            AppLog.note("play report: could not queue the report: \(error.localizedDescription)")
            return await post(body)
        }
        return await send(file)
    }

    // Queued reports whose last try is older than retryAfter.
    func retryPending(now: Date = Date()) async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: queue, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let tried = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let tried, now.timeIntervalSince(tried) < retryAfter { continue }
            _ = await send(file)
        }
    }

    private func send(_ file: URL) async -> Outcome {
        let outcome = await post(try? Data(contentsOf: file))
        switch outcome {
        case .sent, .dropped:
            try? FileManager.default.removeItem(at: file)
        case .retryLater:
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path(percentEncoded: false))
        }
        return outcome
    }

    private func post(_ body: Data?) async -> Outcome {
        guard var body else { return .dropped }
        if body.count > ReportPayload.maximumEncodedSize {
            guard let payload = try? JSONDecoder().decode(ReportPayload.self, from: body),
                  let bounded = try? payload.encoded() else { return .dropped }
            body = bounded
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .sent
            case 408, 429, 500...: return .retryLater
            default:
                AppLog.note("play report: the endpoint refused the report (HTTP \(code))")
                return .dropped
            }
        } catch {
            return .retryLater
        }
    }
}

@MainActor
@Observable
final class PlayReports {

    static let shared = PlayReports()

    struct Nudge: Equatable, Identifiable {
        let prefix: WinePrefix
        let session: GameSession
        var id: String { PlayReports.key(prefix, session) }
    }

    // What the consent sheet is for: one answer, several from Report Your Games…, or
    // turning auto-share on.
    enum ConsentRequest: Equatable { case answer(ReportStatus, note: String?, issue: ReportIssue? = nil), bulk([String], ReportStatus), autoShare }

    private(set) var nudges: [Nudge] = []
    var consentRequest: ConsentRequest?

    var nudge: Nudge? { nudges.first }

    // Report Your Games…: nil while the sheet is closed.
    private(set) var bulk: [Found]?
    private(set) var bulkLoading = false

    // AppIDs a maintainer verified on a Mac with this Mac's chip (VerifiedGames).
    var verifiedHere: Set<String> = []

    // A few seconds of thanks after an answer. Sending happens in the background, and a
    // report made offline goes out later, so it says the report is on its way.
    private(set) var thanking = false
    private var thanksGeneration = 0

    private let defaults: UserDefaults
    private let sender: @Sendable () -> ReportSender
    private let version: String
    private var scanning = false

    private static let consentKey = "PlayReportsConsent"
    private static let autoShareKey = "PlayReportsAutoShare"
    private static let handledKey = "PlayReportsHandled"
    private static let installKey = "PlayReportsInstallID"
    private static let askedKey = "PlayReportsAskedVersion"   // appID: Bridgeplay version
    private static let answerKey = "PlayReportsLastAnswer"    // appID: ReportStatus
    private static let neverKey = "PlayReportsNeverAsk"       // [appID]

    init(defaults: UserDefaults = .standard, version: String = ProductVersion.short,
         sender: @escaping @Sendable () -> ReportSender = { .standard }) {
        self.defaults = defaults
        self.version = version
        self.sender = sender
        autoShare = defaults.bool(forKey: Self.autoShareKey) && defaults.bool(forKey: Self.consentKey)
    }

    private(set) var autoShare: Bool

    var hasConsent: Bool { defaults.bool(forKey: Self.consentKey) }

    // Random and only used by the endpoint for rate limiting; it is not in the report.
    var installID: String {
        if let id = defaults.string(forKey: Self.installKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installKey)
        return id
    }

    nonisolated static func key(_ prefix: WinePrefix, _ session: GameSession) -> String {
        "\(prefix.appID)|\(session.id)"
    }

    func isHandled(_ key: String) -> Bool {
        defaults.stringArray(forKey: Self.handledKey)?.contains(key) ?? false
    }

    private func markHandled(_ key: String) {
        var handled = defaults.stringArray(forKey: Self.handledKey) ?? []
        handled.removeAll { $0 == key }
        handled.append(key)
        defaults.set(Array(handled.suffix(300)), forKey: Self.handledKey)
    }

    // A game is asked about (or auto-shared) once per Bridgeplay version, never after "Don't
    // Ask About This Game", and once more in the same version if it crashed after the last
    // answer was Smooth.
    func shouldAsk(_ item: Found) -> Bool {
        let appID = item.prefix.appID
        if verifiedHere.contains(appID) { return false }
        if (defaults.stringArray(forKey: Self.neverKey) ?? []).contains(appID) { return false }
        if defaults.dictionary(forKey: Self.askedKey)?[appID] as? String != version { return true }
        return lastAnswer(appID) == .platinum && item.session.crashed(wineLog: item.wineLog)
    }

    func lastAnswer(_ appID: String) -> ReportStatus? {
        (defaults.dictionary(forKey: Self.answerKey)?[appID] as? String).flatMap(ReportStatus.init(rawValue:))
    }

    private func recordAsked(_ appID: String, answer: ReportStatus?) {
        var asked = defaults.dictionary(forKey: Self.askedKey) ?? [:]
        asked[appID] = version
        defaults.set(asked, forKey: Self.askedKey)
        guard let answer else { return }
        var answers = defaults.dictionary(forKey: Self.answerKey) ?? [:]
        answers[appID] = answer.rawValue
        defaults.set(answers, forKey: Self.answerKey)
    }

    func setAutoShare(_ on: Bool) {
        if on, !hasConsent {
            consentRequest = .autoShare
            return
        }
        autoShare = on
        defaults.set(on, forKey: Self.autoShareKey)
    }

    // The player picked an answer on the card; the first one asks for consent.
    func answer(_ status: ReportStatus, note: String? = nil, issue: ReportIssue? = nil) {
        guard let nudge else { return }
        guard hasConsent else {
            consentRequest = .answer(status, note: note, issue: issue)
            return
        }
        advance(past: nudge)
        recordAsked(nudge.prefix.appID, answer: status)
        send(nudge, status: status, source: .tap, note: note, issue: issue)
        thanksGeneration += 1
        let generation = thanksGeneration
        thanking = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            if generation == thanksGeneration { thanking = false }
        }
    }

    func consent(alsoAutoShare: Bool) {
        defaults.set(true, forKey: Self.consentKey)
        let request = consentRequest
        consentRequest = nil
        if alsoAutoShare || request == .autoShare { setAutoShare(true) }
        if case .answer(let status, let note, let issue) = request { answer(status, note: note, issue: issue) }
        if case .bulk(let appIDs, let status) = request { answerBulk(appIDs, status) }
    }

    // Games for Report Your Games…: every game with a finished session in its log, however
    // old, minus those answered for this version, Don't Ask games and verified ones.
    func bulkCandidates(_ found: [Found]) -> [Found] {
        let never = defaults.stringArray(forKey: Self.neverKey) ?? []
        let asked = defaults.dictionary(forKey: Self.askedKey) ?? [:]
        return found.filter { item in
            let appID = item.prefix.appID
            return !never.contains(appID) && asked[appID] as? String != version && !verifiedHere.contains(appID)
        }
        .sorted { $0.session.ended > $1.session.ended }
    }

    func openBulk() {
        bulk = []
        bulkLoading = true
        Task {
            let found = await Task.detached {
                PlayReports.findSessions(prefixes: PrefixStore.all(), maxAge: nil, onlyWorthAsking: false)
            }.value
            if bulk != nil { showBulk(found) }
        }
    }

    func showBulk(_ found: [Found]) {
        bulk = bulkCandidates(found)
        bulkLoading = false
    }

    func closeBulk() { bulk = nil }

    // One answer for several games from the sheet; the first send asks for consent.
    func answerBulk(_ appIDs: [String], _ status: ReportStatus) {
        guard let list = bulk else { return }
        let items = list.filter { appIDs.contains($0.prefix.appID) }
        guard !items.isEmpty else { return }
        guard hasConsent else {
            consentRequest = .bulk(appIDs, status)
            return
        }
        bulk = list.filter { !appIDs.contains($0.prefix.appID) }
        for item in items {
            recordAsked(item.prefix.appID, answer: status)
            markHandled(Self.key(item.prefix, item.session))
            nudges.removeAll { $0.prefix.appID == item.prefix.appID }
        }
        submitAll(items.map { ($0, status) }, source: .tap)
    }

    // Report This Game…: ask about the game now, from its last session if the log has one.
    func ask(about prefix: WinePrefix) {
        Task {
            let found = await Task.detached { () -> GameSession? in
                let url = PrefixLog.launch.url(for: prefix)
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      let log = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return GameSession.last(in: log, modified: modified)
            }.value
            nudges.removeAll { $0.prefix.id == prefix.id }
            nudges.insert(Nudge(prefix: prefix, session: found ?? .byHand()), at: 0)
        }
    }

    func dismiss() {
        guard let nudge else { return }
        advance(past: nudge)
        recordAsked(nudge.prefix.appID, answer: nil)
    }

    // "Don't Ask About This Game". Report This Game… still works for it.
    func neverAsk() {
        guard let nudge else { return }
        let appID = nudge.prefix.appID
        var never = defaults.stringArray(forKey: Self.neverKey) ?? []
        if !never.contains(appID) { never.append(appID) }
        defaults.set(never, forKey: Self.neverKey)
        advance(past: nudge)
        nudges.removeAll { $0.prefix.appID == appID }
    }

    private func advance(past nudge: Nudge) {
        markHandled(nudge.id)
        nudges.removeAll { $0.id == nudge.id }
    }

    struct Found: Sendable {
        let prefix: WinePrefix
        let session: GameSession
        let log: String
        let wineLog: String?
    }

    // Reads every prefix's last session. Run off the main thread.
    nonisolated static func findSessions(prefixes: [WinePrefix], now: Date = Date(),
                                         maxAge: TimeInterval? = 3 * 86400, onlyWorthAsking: Bool = true) -> [Found] {
        prefixes.compactMap { prefix in
            let url = PrefixLog.launch.url(for: prefix)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  maxAge.map({ now.timeIntervalSince(modified) < $0 }) ?? true,
                  let log = try? String(contentsOf: url, encoding: .utf8),
                  let session = GameSession.last(in: log, modified: modified) else { return nil }
            let wineLog = try? String(contentsOf: PrefixLog.wine.url(for: prefix), encoding: .utf8)
            guard !onlyWorthAsking || session.worthAsking(now: now, wineLog: wineLog) else { return nil }
            return Found(prefix: prefix, session: session, log: log, wineLog: wineLog)
        }
        .sorted { $0.session.ended > $1.session.ended }
    }

    // On launch and whenever the app comes forward. Never blocks the UI.
    func scan() {
        guard !scanning else { return }
        scanning = true
        let sender = sender()
        Task {
            defer { scanning = false }
            let chip = GameReport.chip(GameReport.thisMac.chip)
            verifiedHere = await Task.detached { await VerifiedGames.load(chip: chip) }.value
            let found = await Task.detached { PlayReports.findSessions(prefixes: PrefixStore.all()) }.value
            handle(found)
            await sender.retryPending()
        }
    }

    func handle(_ found: [Found]) {
        for item in found {
            let key = Self.key(item.prefix, item.session)
            guard !isHandled(key), !nudges.contains(where: { $0.id == key }), shouldAsk(item) else { continue }
            if autoShare, let status = item.session.inferredStatus(wineLog: item.wineLog) {
                markHandled(key)
                recordAsked(item.prefix.appID, answer: status)
                submit(item, status: status, source: .auto)
            } else {
                // A newer session of the same game replaces the older question.
                nudges.removeAll { $0.prefix.id == item.prefix.id }
                nudges.append(Nudge(prefix: item.prefix, session: item.session))
            }
        }
    }

    private func send(_ nudge: Nudge, status: ReportStatus, source: ReportPayload.Source, note: String? = nil,
                      issue: ReportIssue? = nil) {
        let prefix = nudge.prefix, session = nudge.session
        Task {
            let logs = await Task.detached {
                (try? String(contentsOf: PrefixLog.launch.url(for: prefix), encoding: .utf8),
                 try? String(contentsOf: PrefixLog.wine.url(for: prefix), encoding: .utf8))
            }.value
            submitAll([(Found(prefix: prefix, session: session, log: logs.0 ?? "", wineLog: logs.1), status)],
                      source: source, note: note, issue: issue)
        }
    }

    private func submit(_ item: Found, status: ReportStatus, source: ReportPayload.Source) {
        submitAll([(item, status)], source: source)
    }

    // Redacting a large log takes a moment, so payloads are built off the main thread, and
    // sent one after another so a batch stays within the endpoint's rate limits.
    private func submitAll(_ items: [(Found, ReportStatus)], source: ReportPayload.Source, note: String? = nil,
                           issue: ReportIssue? = nil) {
        var machine = GameReport.thisMac
        machine.setup = GameReport.setup()
        let sender = sender(), install = installID
        Task.detached {
            for (item, status) in items {
                var machine = machine
                if let reg = try? String(contentsOf: item.prefix.pfx.appending(path: "user.reg"), encoding: .utf8) {
                    machine.setup["retina"] = GameReport.retina(reg)
                }
                let payload = ReportPayload.make(
                    name: item.prefix.title, appID: item.prefix.appID, status: status, source: source, session: item.session,
                    log: item.log.isEmpty ? nil : item.log, wineLog: item.wineLog, machine: machine, install: install,
                    note: note, issue: issue)
                let outcome = await sender.submit(payload)
                AppLog.note("play report: \(payload.appid) \(payload.status.rawValue) (\(payload.source.rawValue)): \(outcome)")
            }
        }
    }
}
