// Install function needs to shell out, this handles it

import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let outputLost: Bool
    let timedOut: Bool

    init(status: Int32, stdout: String, stderr: String, outputLost: Bool = false, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.outputLost = outputLost
        self.timedOut = timedOut
    }

    var succeeded: Bool { status == 0 && !timedOut }
}

struct CommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return String(localized: "\(command) failed with status \(status).") }
        return String(localized: "\(command) failed with status \(status): \(detail)")
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {

    private static let outputDrainTimeout: DispatchTimeInterval = .seconds(10)

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        drainTimeout: DispatchTimeInterval = outputDrainTimeout,
        timeout: DispatchTimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()

        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            AppLog.note("\(executable) did not finish in time, stopping it")
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(5)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        if group.wait(timeout: .now() + drainTimeout) == .timedOut {
            AppLog.note("\(executable) exited but left its output open")
            return CommandResult(
                status: process.terminationStatus, stdout: "", stderr: "", outputLost: true,
                timedOut: timedOut)
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self),
            timedOut: timedOut
        )
    }

    @discardableResult
    static func check(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        drainTimeout: DispatchTimeInterval = outputDrainTimeout,
        timeout: DispatchTimeInterval? = nil
    ) throws -> String {
        let result = try run(
            executable, arguments, environment: environment, currentDirectory: currentDirectory,
            drainTimeout: drainTimeout, timeout: timeout)
        guard result.succeeded else {
            let reason = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CommandFailure(
                command: (executable as NSString).lastPathComponent,
                status: result.status,
                stderr: reason.isEmpty && result.outputLost
                    ? String(localized: "Its output was still open when it exited, so none was captured.")
                    : reason
            )
        }
        return result.stdout
    }

    // For the wine tools
    static func detach(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func logged(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        to log: URL
    ) throws -> Int32 {
        guard FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: log.path(percentEncoded: false)]) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // This account's processes only, unless allUsers: Steam.app is shared by every account
    // on the Mac, so a Steam another account runs still holds the bundle open.
    static func processIsRunning(
        named name: String, allUsers: Bool = false, pgrep: String = "/usr/bin/pgrep",
        drainTimeout: DispatchTimeInterval = outputDrainTimeout
    ) -> Bool {
        let owner = allUsers ? [] : ["-U", String(getuid())]
        guard let result = try? run(pgrep, ["-x"] + owner + [name], drainTimeout: drainTimeout)
        else { return false }
        return result.succeeded
    }
}
