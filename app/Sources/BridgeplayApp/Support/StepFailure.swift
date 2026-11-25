import Foundation

struct StepFailure: LocalizedError {
    let step: String
    let detail: String
    // A failure that another try a little later may not hit, such as Steam's updater still
    // writing into Steam.app.
    var retryable = false
    // Set when Wine processes from a runner caused the failure, so Status can offer to stop them.
    var busyRunner: RunnerActivity?

    var errorDescription: String? { "\(step): \(detail)" }
}
