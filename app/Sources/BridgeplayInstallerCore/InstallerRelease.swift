import CryptoKit
import Foundation

public struct InstallerDownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let total: Int64?
    /// Bytes per second, when the source reports it (curl's meter).
    public let speed: Double?

    public init(received: Int64, total: Int64?, speed: Double? = nil) {
        self.received = received
        self.total = total
        self.speed = speed
    }

    /// One line of curl's progress meter, shown while the components step downloads Steam:
    /// "  45 4200k   45 1890k    0     0  2105k      0  0:00:01  0:00:00  0:00:01 2105k"
    public init?(curlMeter line: String) {
        let fields = line.split(separator: " ")
        guard fields.count == 12, Int(fields[0]) != nil, let total = Self.curlBytes(fields[1]),
              let received = Self.curlBytes(fields[3]), let speed = Self.curlBytes(fields[11]) else { return nil }
        self.init(received: received, total: total > 0 ? total : nil, speed: Double(speed))
    }

    private static func curlBytes(_ text: Substring) -> Int64? {
        let units: [Character: Double] = ["k": 1024, "M": 1_048_576, "G": 1_073_741_824]
        if let unit = text.last.flatMap({ units[$0] }), let value = Double(text.dropLast()) { return Int64(value * unit) }
        return Int64(text)
    }
}

/// A Bridgeplay release whose archive is authenticated by the public key shipped in the app.
public struct InstallerRelease: Sendable, Equatable {
    public static let appcastURL = URL(
        string: "https://github.com/raymondchins/Bridgeplay/releases/latest/download/appcast.xml"
    )!

    public let build: Int
    public let shortVersion: String
    public let minimumOS: String
    public let archiveURL: URL
    public let archiveLength: Int64
    public let signature: Data
    let verificationKey: Data

    public init(
        build: Int,
        shortVersion: String,
        minimumOS: String,
        archiveURL: URL,
        archiveLength: Int64,
        signature: Data
    ) throws {
        try self.init(
            build: build,
            shortVersion: shortVersion,
            minimumOS: minimumOS,
            archiveURL: archiveURL,
            archiveLength: archiveLength,
            signature: signature,
            verificationKey: Data(base64Encoded: Self.encodedSigningKey)!
        )
    }

    init(
        build: Int,
        shortVersion: String,
        minimumOS: String,
        archiveURL: URL,
        archiveLength: Int64,
        signature: Data,
        verificationKey: Data
    ) throws {
        guard build > 0, Self.isVersion(shortVersion), Self.isVersion(minimumOS),
              archiveLength > 0, archiveLength <= Self.maximumArchiveLength,
              signature.count == 64, verificationKey.count == 32, Self.isReleaseArchive(archiveURL) else {
            throw InstallerError.invalidRelease
        }
        self.build = build
        self.shortVersion = shortVersion
        self.minimumOS = minimumOS
        self.archiveURL = archiveURL
        self.archiveLength = archiveLength
        self.signature = signature
        self.verificationKey = verificationKey
    }

    /// Parse the first release in Bridgeplay's Sparkle feed.
    public static func parse(appcast: Data) throws -> InstallerRelease {
        let reader = AppcastReader()
        let parser = XMLParser(data: appcast)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        let sourceText = String(data: appcast, encoding: .utf8) ?? ""
        guard appcast.count <= 256_000,
              !sourceText.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !sourceText.localizedCaseInsensitiveContains("<!ENTITY"),
              parser.parse(), let attributes = reader.enclosure,
              let buildText = reader.build, let shortVersion = reader.shortVersion,
              let minimumOS = reader.minimumOS, reader.hardwareRequirements == "arm64" else {
            throw InstallerError.invalidRelease
        }

        guard buildText.utf8.allSatisfy({ (48...57).contains($0) }), let build = Int(buildText),
              let lengthText = attributes["length"],
              lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(lengthText),
              let signatureText = attributes["sparkle:edSignature"],
              let signature = Data(base64Encoded: signatureText),
              let urlText = attributes["url"], let url = URL(string: urlText) else {
            throw InstallerError.invalidRelease
        }

        return try InstallerRelease(
            build: build,
            shortVersion: shortVersion,
            minimumOS: minimumOS,
            archiveURL: url,
            archiveLength: length,
            signature: signature
        )
    }

    public static func latest(
        from appcastURL: URL = appcastURL,
        session: URLSession = .shared
    ) async throws -> InstallerRelease {
        guard Self.isAppcastURL(appcastURL) else { throw InstallerError.invalidRelease }
        var request = URLRequest(url: appcastURL)
        request.timeoutInterval = 30
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw InstallerError.networkFailure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, Self.isGitHubResponseURL(finalURL) else {
            throw InstallerError.invalidRelease
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 256_000 else { throw InstallerError.invalidRelease }
            data.append(byte)
        }
        return try parse(appcast: data)
    }

    /// Download the signed archive to a temporary file, verify it, then move it into place.
    /// The destination archive exists only after the complete file passes its EdDSA check.
    /// (Reading the response byte by byte held a fast connection to about 0.5 MB/s.)
    public func download(
        to destination: URL,
        session: URLSession = .shared,
        control: InstallerDownloadControl? = nil,
        progress: @escaping @Sendable (InstallerDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard destination.isFileURL else { throw InstallerError.invalidDestination }
        let archiveURL = destination.appending(path: "Bridgeplay.zip")
        var request = URLRequest(url: self.archiveURL)
        request.timeoutInterval = 60

        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await InstallerFileDownload.run(request, total: archiveLength, control: control, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InstallerError.networkFailure(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        // 206: a resumed download (InstallerFileDownload).
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              let finalURL = http.url, Self.isArchiveResponseURL(finalURL) else {
            throw InstallerError.invalidRelease
        }
        if response.expectedContentLength > Self.maximumArchiveLength { throw InstallerError.archiveTooLarge }
        try verifyArchive(at: temporary)
        try Task.checkCancellation()

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: archiveURL)
            try FileManager.default.moveItem(at: temporary, to: archiveURL)
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw InstallerError.writeFailure(error.localizedDescription)
        }
        progress(InstallerDownloadProgress(received: archiveLength, total: archiveLength))
        return archiveURL
    }

    func verifyArchive(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize,
              Int64(fileSize) == archiveLength,
              fileSize <= Self.maximumArchiveLength else {
            throw InstallerError.invalidArchiveLength
        }
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        try Self.verify(archive, signature: signature, publicKey: verificationKey)
    }

    static let maximumArchiveLength: Int64 = 1_073_741_824

    static let encodedSigningKey = "KrO6vVqAJozBSnfrLuyhBU/Kfhg8klI8ftl7CQ2sV98="

    static func verify(_ data: Data, signature: Data, publicKey: Data) throws {
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            guard key.isValidSignature(signature, for: data) else { throw InstallerError.signatureMismatch }
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.invalidRelease
        }
    }

    static func isReleaseArchive(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.host == "github.com",
              url.port == nil || url.port == 443 else { return false }
        return url.path.hasPrefix("/raymondchins/Bridgeplay/releases/download/")
            && url.lastPathComponent == "Bridgeplay.zip"
    }

    private static func isAppcastURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && url.path == "/raymondchins/Bridgeplay/releases/latest/download/appcast.xml"
    }

    private static func isGitHubResponseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    private static func isArchiveResponseURL(_ url: URL) -> Bool {
        isGitHubResponseURL(url)
    }

    private static func isVersion(_ text: String) -> Bool {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        return (2...3).contains(components.count)
            && components.allSatisfy {
                !$0.isEmpty && UInt64($0) != nil
                    && $0.utf8.allSatisfy { (48...57).contains($0) }
            }
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    private(set) var enclosure: [String: String]?
    private(set) var build: String?
    private(set) var shortVersion: String?
    private(set) var minimumOS: String?
    private(set) var hardwareRequirements: String?
    private var readingItem = false
    private var sawItem = false
    private var capturedElement: String?
    private var capturedText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item", !sawItem {
            sawItem = true
            readingItem = true
            return
        }
        guard readingItem else { return }
        if elementName == "enclosure", enclosure == nil {
            enclosure = attributeDict
        }
        if ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion",
            "sparkle:hardwareRequirements"].contains(elementName) {
            capturedElement = elementName
            capturedText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturedElement != nil else { return }
        capturedText += string
        if capturedText.utf8.count > 128 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard capturedElement != nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        capturedText += text
        if capturedText.utf8.count > 128 { parser.abortParsing() }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard readingItem else { return }
        if elementName == capturedElement {
            let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "sparkle:version": build = value
            case "sparkle:shortVersionString": shortVersion = value
            case "sparkle:minimumSystemVersion": minimumOS = value
            case "sparkle:hardwareRequirements": hardwareRequirements = value
            default: break
            }
            capturedElement = nil
            capturedText = ""
        }
        if elementName == "item" { readingItem = false }
    }
}

public enum InstallerError: LocalizedError, Sendable {
    case invalidRelease
    case networkFailure(String)
    case invalidDestination
    case archiveTooLarge
    case invalidArchiveLength
    case signatureMismatch
    case writeFailure(String)
    case unsupportedSystem(minimum: String)
    case invalidInstallation(String)
    case otherAppInstalled(String)
    case downgrade(current: Int, offered: Int)
    case alreadyCurrent
    case appIsRunning
    case installLocked
    case appValidation(String)
    case replacementFailure(String)
    case componentsFailure(String)

    /// What a download caught between a release's archive and .sig swaps fails with.
    var mayBeReleaseSwap: Bool {
        switch self {
        case .invalidRelease, .invalidArchiveLength, .signatureMismatch: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "The Bridgeplay release information could not be verified."
        case .networkFailure(let detail): "Bridgeplay could not reach its release server. \(detail)"
        case .invalidDestination: "Choose a local folder for Bridgeplay."
        case .archiveTooLarge: "The Bridgeplay download is larger than expected."
        case .invalidArchiveLength: "The Bridgeplay download is incomplete or has an unexpected size."
        case .signatureMismatch: "The Bridgeplay download did not pass its signature check."
        case .writeFailure(let detail): "The verified Bridgeplay download could not be saved. \(detail)"
        case .unsupportedSystem(let minimum): "This Bridgeplay release needs macOS \(minimum) or later."
        case .invalidInstallation(let detail): "The Bridgeplay installation could not be read. \(detail)"
        case .otherAppInstalled(let name): "Another app is already at the install location (\(name)). Choose another location or move it first."
        case .downgrade(let current, let offered): "Bridgeplay \(offered) is older than the installed build \(current)."
        case .alreadyCurrent: "This Bridgeplay version is already installed."
        case .appIsRunning: "Quit Bridgeplay before installing its update, then try again."
        case .installLocked: "Another Bridgeplay installation is in progress. Finish it before trying again."
        case .appValidation(let detail): "The downloaded Bridgeplay app could not be validated. \(detail)"
        case .replacementFailure(let detail): "Bridgeplay could not replace the existing app. \(detail)"
        case .componentsFailure(let detail): "Steam, the graphics or the engine could not be set up. \(detail)"
        }
    }
}

func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = lhs.split(separator: ".").compactMap { UInt64($0) }
    let right = rhs.split(separator: ".").compactMap { UInt64($0) }
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : 0
        let b = index < right.count ? right[index] : 0
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
    }
    return .orderedSame
}
