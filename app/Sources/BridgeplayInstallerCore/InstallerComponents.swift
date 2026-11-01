import Foundation

/// Apple's Game Porting Toolkit, DXMT, DXVK and the default configs (not WineCX, which the
/// app downloads from dappermint): the one-click
/// installer ZIP on the `installer` release. The wizard downloads it only when this Mac lacks
/// them, checks it against the same EdDSA key as the app, then puts its contents in place
/// itself (ComponentsPlacement) rather than running the Install.command inside it.
public struct InstallerComponents: Sendable, Equatable {
    public static let archiveURL = URL(
        string: "https://github.com/raymondchins/Bridgeplay/releases/download/installer/Bridgeplay-Installer.zip"
    )!
    /// "<base64 EdDSA signature> <length>", written by scripts/release-local.sh with Sparkle's sign_update.
    public static let signatureURL = URL(
        string: "https://github.com/raymondchins/Bridgeplay/releases/download/installer/Bridgeplay-Installer.zip.sig"
    )!
    static let maximumLength: Int64 = 2_147_483_648

    public let length: Int64
    /// Where the archive comes from, for "Downloading from …".
    public var archiveHost: String { archiveURL.host() ?? "github.com" }
    public let signature: Data
    let verificationKey: Data
    var archiveURL = Self.archiveURL

    public init(signatureFile text: String) throws {
        try self.init(signatureFile: text, verificationKey: Data(base64Encoded: InstallerRelease.encodedSigningKey)!)
    }

    init(signatureFile text: String, verificationKey: Data) throws {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let signature = Data(base64Encoded: String(parts[0])), signature.count == 64,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(parts[1]),
              length > 0, length <= Self.maximumLength, verificationKey.count == 32 else {
            throw InstallerError.invalidRelease
        }
        self.length = length
        self.signature = signature
        self.verificationKey = verificationKey
    }

    /// Needed on a Mac without Game Porting Toolkit in Bridgeplay's (or the older NotProton)
    /// support folder, or without Steam.
    public static func needed(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              applications: URL = URL(fileURLWithPath: "/Applications")) -> Bool {
        let support = home.appending(path: "Library/Application Support")
        let gptk = ["bridgeplay", "notproton"].contains {
            FileManager.default.fileExists(atPath: support.appending(path: "\($0)/gptk").path)
        }
        let steam = FileManager.default.fileExists(atPath: applications.appending(path: "Steam.app").path)
        return !gptk || !steam
    }

    /// The signature published beside the archive. For testing an unpublished build, the
    /// `ComponentsSignature` and `ComponentsArchive` (a file: URL) defaults name another
    /// signature and archive; the archive must still be signed by Bridgeplay's key.
    public static func latest(session: URLSession = .shared, defaults: UserDefaults = .standard) async throws -> InstallerComponents {
        if let local = defaults.string(forKey: "ComponentsSignature") {
            var components = try InstallerComponents(signatureFile: local)
            if let path = defaults.string(forKey: "ComponentsArchive"), let url = URL(string: path), url.isFileURL {
                components.archiveURL = url
            }
            return components
        }
        var request = URLRequest(url: signatureURL)
        request.timeoutInterval = 30
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw InstallerError.networkFailure(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1024,
              let text = String(data: data, encoding: .utf8) else { throw InstallerError.invalidRelease }
        return try InstallerComponents(signatureFile: text)
    }

    /// Download to a file in `directory` and verify it. Throws without leaving the file on failure.
    public func download(to directory: URL, control: InstallerDownloadControl? = nil,
                         progress: @escaping @Sendable (InstallerDownloadProgress) -> Void = { _ in }) async throws -> URL {
        var request = URLRequest(url: archiveURL)
        request.timeoutInterval = 60
        let temporary: URL, response: URLResponse
        do { (temporary, response) = try await InstallerFileDownload.run(request, total: length, control: control, progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { throw InstallerError.networkFailure(error.localizedDescription) }
        let archive = directory.appending(path: "Bridgeplay-Installer.zip")
        do {
            guard archiveURL.isFileURL || [200, 206].contains((response as? HTTPURLResponse)?.statusCode) else { throw InstallerError.invalidRelease }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: temporary, to: archive)
            try verify(archive)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
        return archive
    }

    /// A release replaces the archive, then its .sig, a few seconds apart (release-local.sh
    /// swap_asset). A download in that gap 404s or fails its check: fetch the .sig again and retry.
    public func downloadAcrossRelease(to directory: URL, attempts: Int = 3, control: InstallerDownloadControl? = nil,
                                      progress: @escaping @Sendable (InstallerDownloadProgress) -> Void = { _ in }) async throws -> URL {
        var components = self
        for attempt in 1... {
            do { return try await components.download(to: directory, control: control, progress: progress) }
            catch let error as InstallerError where attempt < attempts && error.mayBeReleaseSwap {
                InstallerLog.write("Components \(error), fetching the signature again, try \(attempt + 1) of \(attempts)")
                try await Task.sleep(for: .seconds(10))
                components = try await Self.latest()
            }
        }
        fatalError("unreachable")
    }

    // CEILING: Ed25519 signs the whole file, so it is mapped and checked at once (~0.5 GB of
    // address space); a streamed check would need a different signature scheme.
    func verify(_ archive: URL) throws {
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard size == length else { throw InstallerError.invalidArchiveLength }
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        try InstallerRelease.verify(data, signature: signature, publicKey: verificationKey)
    }

    /// Unpack the verified archive and put Steam, GPTK, the engine archives and the configs in
    /// place (ComponentsPlacement). `status` gets each step as it starts.
    public static func install(archive: URL, work: URL, status: @escaping @Sendable (String) -> Void = { _ in },
                               download: @escaping @Sendable (InstallerDownloadProgress) -> Void = { _ in }) throws {
        let unpacked = work.appending(path: "components")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let source = unpacked.appending(path: "Bridgeplay")
        try verifyAppleSigned(gptk: source.appending(path: "gptk"))
        try ComponentsPlacement(source: source).place(status: status, download: download)
    }

    /// GPTK ships unmodified: D3DMetal.framework and every other Mach-O file must carry Apple's
    /// own signature, the check scripts/package-installer.sh makes before packaging.
    static func verifyAppleSigned(gptk: URL, check: (URL) -> Bool = { appleSigned($0) }) throws {
        let fail = { (path: String) in InstallerError.componentsFailure("\(path) is not signed by Apple.") }
        let framework = gptk.appending(path: "external/D3DMetal.framework")
        guard check(framework) else { throw fail("D3DMetal.framework") }
        var machO = 0
        let files = FileManager.default.enumerator(at: gptk, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            if file.lastPathComponent == framework.lastPathComponent {
                files?.skipDescendants()
                continue
            }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  isMachO(file) else { continue }
            guard check(file) else { throw fail(file.lastPathComponent) }
            machO += 1
        }
        guard machO > 0 else { throw InstallerError.componentsFailure("The Game Porting Toolkit in the download is incomplete.") }
    }

    static func appleSigned(_ url: URL) -> Bool {
        (try? run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=anchor apple", url.path])) != nil
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        // Mach-O in either byte order, and universal binaries.
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCE],
                [0xCA, 0xFE, 0xBA, 0xBE]].contains(Array(head))
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    line: @escaping @Sendable (String) -> Void = { _ in }) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var all = ""
        var pending = ""
        while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
            let text = String(decoding: chunk, as: UTF8.self)
            all += text
            pending += text
            while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                line(String(pending[..<newline]).trimmingCharacters(in: .whitespaces))
                pending.removeSubrange(...newline)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = all.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw InstallerError.componentsFailure(reason.map(String.init) ?? "exit \(process.terminationStatus)")
        }
        return all
    }
}

/// Pauses and resumes the installer's running download. A suspended task sends nothing and
/// times nothing out; if the server drops the idle connection, the resume picks it up again.
public final class InstallerDownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var paused = false

    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }

    public func pause() {
        lock.withLock {
            guard !paused else { return }
            paused = true
            task?.suspend()
        }
    }

    public func resume() {
        lock.withLock {
            guard paused else { return }
            paused = false
            task?.resume()
        }
    }

    /// Starts the task, or holds it suspended while paused.
    func start(_ task: URLSessionTask) {
        lock.withLock {
            self.task = task
            if !paused { task.resume() }
        }
    }

    func detach() { lock.withLock { task = nil } }
}

/// Downloads to a file with progress. A task delegate passed to `URLSession.download(for:delegate:)`
/// gets no progress callbacks, so each download gets its own session with this delegate.
/// The file is moved out of URLSession's temporary location before the callback returns.
final class InstallerFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let total: Int64
    private let progress: @Sendable (InstallerDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var saved: URL?

    private init(total: Int64, progress: @escaping @Sendable (InstallerDownloadProgress) -> Void) {
        self.total = total
        self.progress = progress
    }

    static let resumableErrors: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// A dropped connection resumes where it stopped (#143: 500 MB restarted from zero on each
    /// try). A resume the server refuses (an expired download link) starts over.
    static func run(_ request: URLRequest, total: Int64, attempts: Int = 4, control: InstallerDownloadControl? = nil,
                    progress: @escaping @Sendable (InstallerDownloadProgress) -> Void) async throws -> (URL, URLResponse) {
        var resumeData: Data?
        for attempt in 1... {
            do {
                let (file, response) = try await once(request, resumeData: resumeData, total: total, control: control, progress: progress)
                let status = (response as? HTTPURLResponse)?.statusCode
                if resumeData != nil, status != 200, status != 206, attempt < attempts {
                    try? FileManager.default.removeItem(at: file)
                    InstallerLog.write("Resume refused (\(status ?? 0)), downloading \(request.url?.lastPathComponent ?? "") again")
                    resumeData = nil
                    continue
                }
                return (file, response)
            } catch let error as URLError where attempt < attempts && resumableErrors.contains(error.code) {
                resumeData = error.downloadTaskResumeData
                InstallerLog.write("Download interrupted (\(error.localizedDescription)), \(resumeData == nil ? "restarting" : "resuming"), try \(attempt + 1) of \(attempts)")
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
        fatalError("unreachable")
    }

    private static func once(_ request: URLRequest, resumeData: Data?, total: Int64, control: InstallerDownloadControl?,
                             progress: @escaping @Sendable (InstallerDownloadProgress) -> Void) async throws -> (URL, URLResponse) {
        let delegate = InstallerFileDownload(total: total, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        defer { control?.detach() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                control?.start(task) ?? task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(InstallerDownloadProgress(received: totalBytesWritten, total: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-download-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: keep)
        lock.withLock { saved = keep }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file) = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, URL?) in
            defer { self.continuation = nil }
            return (self.continuation, saved)
        }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let file, let response = task.response {
            continuation?.resume(returning: (file, response))
        } else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}
