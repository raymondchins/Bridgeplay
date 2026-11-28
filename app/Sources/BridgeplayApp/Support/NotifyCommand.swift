import Foundation
import UserNotifications

// Posts one notification under Bridgeplay's own name and icon, for the run script:
// `open -n -g -b com.bridgeplay.Bridgeplay --args --notify <title> <subtitle> <body>`.
// Runs before the migration and the log so a game launch never waits on either, and exits
// without opening a window. macOS asks once whether Bridgeplay may send notifications.
enum NotifyCommand {
    static let flag = "--notify"
    // `--notify-result <file> --notify <title> <body>`: the background agent's form. The
    // helper writes "delivered" or "failed" there before it exits, since `open` can't pass
    // an exit status back.
    static let resultFlag = "--notify-result"
    static let deliveredMark = "delivered"

    static func requested(_ arguments: [String] = CommandLine.arguments) -> [String]? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return Array(arguments[(index + 1)...])
    }

    static func resultFile(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: resultFlag), index + 1 < arguments.count,
              arguments.firstIndex(of: flag).map({ index < $0 }) ?? false
        else { return nil }
        return URL(filePath: arguments[index + 1])
    }

    static func arguments(_ parts: [String], result: URL) -> [String] {
        [resultFlag, result.path(percentEncoded: false), flag] + parts
    }

    static func run(_ parts: [String]) -> Never {
        let result = resultFile()
        Task.detached {
            let delivered = await post(parts)
            if let result {
                try? Data((delivered ? deliveredMark : "failed").utf8).write(to: result, options: .atomic)
            }
            exit(delivered ? 0 : 1)
        }
        dispatchMain()
    }

    private static func post(_ parts: [String]) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let text = Self.text(parts)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return (try? await center.add(request)) != nil
    }

    // The dylib sends English (Steam opened without Bridgeplay), which is a catalogue key and
    // shows in the player's language. The run script sends text it already translated, which
    // is no key and shows as it is.
    static func text(_ parts: [String], bundle: Bundle = .main) -> (title: String, subtitle: String, body: String) {
        let shown = { (text: String) in bundle.localizedString(forKey: text, value: text, table: nil) }
        let title = shown(parts.first ?? "Bridgeplay")
        if parts.count > 2 {
            return (title, shown(parts[1]), shown(parts[2...].joined(separator: " ")))
        }
        return (title, "", parts.count == 2 ? shown(parts[1]) : "")
    }
}
