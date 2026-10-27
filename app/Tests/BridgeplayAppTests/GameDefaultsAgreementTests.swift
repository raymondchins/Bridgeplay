import Foundation
import Testing

@testable import BridgeplayApp

// GameDefaults validates what it writes the way gamefix_reason in compat_run.sh reads it,
// so a value the page saves is never one the run script throws away.
@Suite("Game Defaults agreement")
struct GameDefaultsAgreementTests {

    private static func source(_ path: String) throws -> String {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repo.appending(path: path), encoding: .utf8)
    }

    struct Arm {
        var patterns: [String]
        var body: String

        func matches(_ key: String) -> Bool {
            patterns.contains { $0 == key || ($0.hasSuffix("_?*") && key.hasPrefix($0.dropLast(2))) }
        }

        // The values of its `case "$2" in a|b)`, nil when it takes any value.
        var values: Set<String>? {
            guard let start = body.range(of: "case \"$2\" in ") else { return nil }
            let rest = body[start.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { return nil }
            return Set(rest[..<close].split(separator: "|").map(String.init))
        }
    }

    // The arms of gamefix_reason's `case "$1" in`, each with the lines up to the next arm.
    static func arms(in run: String) throws -> [Arm] {
        let start = try #require(run.range(of: "gamefix_reason() {\n"))
        let end = try #require(run.range(of: "\n}\n", range: start.upperBound..<run.endIndex))
        let keyCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_?*|")
        var arms: [Arm] = []
        for line in run[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    "), !line.hasPrefix("     "),
               let close = trimmed.firstIndex(of: ")"), close != trimmed.startIndex,
               trimmed[..<close].allSatisfy({ keyCharacters.contains($0) }) {
                arms.append(Arm(patterns: trimmed[..<close].split(separator: "|").map(String.init),
                                body: String(trimmed[trimmed.index(after: close)...])))
            } else if !arms.isEmpty {
                arms[arms.count - 1].body += "\n" + trimmed
            }
        }
        return arms
    }

    @Test("Every setting's key and values are the ones the run script accepts")
    func valuesAgree() throws {
        let arms = try Self.arms(in: Self.source("dylib/feats/compat_run.sh"))
        #expect(arms.count >= 8, "found \(arms.count) arms, the parse looks wrong")
        for setting in GameDefaults.Setting.allCases {
            let key = setting.keys[0]
            let arm = try #require(arms.first { $0.matches(key) && $0.patterns != ["*"] }, "\(key) is not on the allow-list")
            if setting == .dllOverrides {
                #expect(arm.body.contains("valid_dll_overrides"))
            } else {
                #expect(arm.values == setting.accepted.map { Set($0) }, "\(key): \(String(describing: arm.values))")
            }
            if case .choice(let offered) = setting.kind {
                #expect(Set(offered).isSubset(of: arm.values ?? []), "\(key) offers a value the run script refuses")
            }
        }
    }

    @Test("Every other spelling a setting reads is one gamefix_read maps to its key")
    func aliasesAgree() throws {
        let run = try Self.source("dylib/feats/compat_run.sh")
        let start = try #require(run.range(of: "    case \"$key\" in\n      BRIDGEPLAY_"))
        let line = run[run.index(start.lowerBound, offsetBy: "    case \"$key\" in\n".count)...].prefix { $0 != "\n" }
        let close = try #require(line.firstIndex(of: ")"))
        let patterns = line[..<close].trimmingCharacters(in: .whitespaces).split(separator: "|").map(String.init)
        let alias = Arm(patterns: patterns, body: "")
        for setting in GameDefaults.Setting.allCases {
            for spelling in setting.keys.dropFirst() {
                #expect(alias.matches(spelling), "\(spelling) is not read as \(setting.keys[0])")
                #expect(spelling == "BRIDGEPLAY_" + setting.keys[0])
            }
        }
    }
}
