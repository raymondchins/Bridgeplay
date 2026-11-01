import Darwin
import Foundation

// A lock file beside a copy staged in a shared folder, held while the copy is made. flock holds
// across processes and users, so the CLI or another user's app never takes a live copy for one
// a force quit left behind.
struct StageLock {
    private let file: String
    private let descriptor: Int32

    init(claiming staged: URL) throws {
        file = Self.lockPath(for: staged)
        // Locked as it is made, so a sweep never finds it unheld. Readable by every user, who
        // need only open it to test the lock.
        descriptor = open(file, O_RDONLY | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // After the staged copy is gone, so a sweep that finds the copy finds the lock held.
    func release() {
        unlink(file)
        close(descriptor)
    }

    // Removes the copies whose lock nobody holds. One with no lock file comes from a build
    // before these and is left until it is older than any copy takes.
    static func sweep(in folder: URL, prefix: String, unlockedAge: TimeInterval = 3600, now: Date = .now) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(prefix) {
            var token = name.dropFirst(prefix.count)
            let isLock = token.hasSuffix(lockSuffix)
            if isLock { token = token.dropLast(lockSuffix.count) }
            guard UUID(uuidString: String(token)) != nil else { continue }
            let staged = folder.appending(path: "\(prefix)\(token)")
            let lock = lockPath(for: staged)
            let held = open(lock, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            if held >= 0 {
                defer { close(held) }
                if remove(staged) { unlink(lock) }
            } else if errno == ENOENT, !isLock {
                let made = (try? staged.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let made, now.timeIntervalSince(made) > unlockedAge { _ = remove(staged) }
            }
        }
    }

    private static let lockSuffix = ".lock"

    private static func lockPath(for staged: URL) -> String {
        staged.path(percentEncoded: false) + lockSuffix
    }

    private static func remove(_ staged: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.path(percentEncoded: false)) else { return true }
        do {
            try fm.removeItem(at: staged)
            return true
        } catch {
            AppLog.note("setup: could not remove \(staged.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}
