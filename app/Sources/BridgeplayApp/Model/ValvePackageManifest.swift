// Validation for downloaded Valve binaries

import Foundation

struct ValvePackage: Sendable, Equatable, Identifiable {
    let id: String
    let file: String
    let sha256: String
}

struct ValveFile: Sendable, Equatable, Identifiable {
    let bridgePath: String
    let package: String
    let innerPath: String
    let sha256: String

    var id: String { bridgePath }
}

struct ValveBundle: Sendable, Equatable {
    let file: String
    let sha256: String
    let innerArchive: String
    let bundleName: String
}

struct ValvePackageManifest: Sendable {
    let bases: [URL]
    let packages: [ValvePackage]
    let files: [ValveFile]
    let bundle: ValveBundle?

    func innerPaths(package id: String) -> [String] {
        var seen = Set<String>()
        return files.filter { $0.package == id }.compactMap { seen.insert($0.innerPath).inserted ? $0.innerPath : nil }
    }

    static let resourceName = "valve-packages"
    static let resourceExtension = "manifest"

    private static let step = String(localized: "Read the Valve file list")

    static func bundled() throws -> ValvePackageManifest {
        guard let url = Bundle.module.url(
            forResource: resourceName, withExtension: resourceExtension
        ) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(resourceName).\(resourceExtension) is missing from the app's resources.")
            )
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> ValvePackageManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(url.path(percentEncoded: false)) could not be read. \(error.localizedDescription)")
            )
        }
        return try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) throws -> ValvePackageManifest {
        var bases: [URL] = []
        var packages: [ValvePackage] = []
        var files: [ValveFile] = []
        var bundle: ValveBundle?
        var packageIDs = Set<String>()
        var bridgePaths = Set<String>()

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let number = index + 1

            switch fields[0] {
            case "base":
                try expect(fields.count == 2, number, String(localized: "a base and one URL"), line)
                guard let url = URL(string: fields[1]), url.scheme == "https", url.host() != nil else {
                    throw fail(number, String(localized: "does not hold an https URL: \(fields[1])"))
                }
                bases.append(url)

            case "package":
                try expect(fields.count == 4, number, String(localized: "a package, an id, a filename and a sha256"), line)
                try expectHash(fields[3], number)
                guard packageIDs.insert(fields[1]).inserted else {
                    throw fail(number, String(localized: "repeats the package id \(fields[1])."))
                }
                packages.append(ValvePackage(id: fields[1], file: fields[2], sha256: fields[3]))

            case "file":
                try expect(fields.count == 5, number, String(localized: "a file, a bridge path, a package id, an inner path and a sha256"), line)
                try expectHash(fields[4], number)
                guard bridgePaths.insert(fields[1]).inserted else {
                    throw fail(number, String(localized: "repeats the bridge path \(fields[1])."))
                }
                files.append(ValveFile(bridgePath: fields[1], package: fields[2], innerPath: fields[3], sha256: fields[4]))

            case "bundle":
                try expect(fields.count == 5, number,
                    String(localized: "a bundle, a filename, a sha256, an inner archive and a bundle name"), line)
                try expectHash(fields[2], number)
                guard bundle == nil else {
                    throw fail(number, String(localized: "declares a second bundle. One is the most that can be installed."))
                }
                bundle = ValveBundle(
                    file: fields[1], sha256: fields[2], innerArchive: fields[3], bundleName: fields[4]
                )

            default:
                throw fail(number, String(localized: "has an unknown row kind \(fields[0]). Known: base, package, file, bundle."))
            }
        }

        guard !bases.isEmpty else { throw fail(nil, String(localized: "names no CDN host to fetch from.")) }
        guard !packages.isEmpty else { throw fail(nil, String(localized: "names no package.")) }
        guard !files.isEmpty else { throw fail(nil, String(localized: "names no file.")) }

        for file in files where !packageIDs.contains(file.package) {
            throw fail(nil, String(localized: "\(file.bridgePath) names the package \(file.package), which is not declared. Declared: \(packages.map(\.id).joined(separator: ", "))."))
        }

        for package in packages where !files.contains(where: { $0.package == package.id }) {
            throw fail(nil, String(localized: "declares the package \(package.id), which no file row uses."))
        }

        var hashByInner: [String: (path: String, sha: String)] = [:]
        for file in files {
            let key = "\(file.package)/\(file.innerPath)"
            if let first = hashByInner[key], first.sha != file.sha256 {
                throw fail(nil, String(localized: "\(first.path) and \(file.bridgePath) both come from \(key) but pin different hashes."))
            }
            hashByInner[key] = (file.bridgePath, file.sha256)
        }

        return ValvePackageManifest(bases: bases, packages: packages, files: files, bundle: bundle)
    }

    private static func expect(_ condition: Bool, _ line: Int, _ shape: String, _ text: String) throws {
        guard condition else { throw fail(line, String(localized: "is not \(shape): \(text)")) }
    }

    private static func expectHash(_ value: String, _ line: Int) throws {
        let hex = "0123456789abcdef"
        guard value.count == 64, value.allSatisfy(hex.contains) else {
            throw fail(line, String(localized: "does not end in a lowercase 64 character sha256: \(value)"))
        }
    }

    private static func fail(_ line: Int?, _ detail: String) -> StepFailure {
        StepFailure(step: step, detail: line.map { String(localized: "Line \($0) \(detail)") } ?? String(localized: "The Valve file list \(detail)"))
    }
}
