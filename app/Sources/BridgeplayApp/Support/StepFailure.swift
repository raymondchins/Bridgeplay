import Foundation

struct StepFailure: LocalizedError {
    let step: String
    let detail: String
    // A failure that another try a little later may not hit, such as Steam's updater still
    // writing into Steam.app.
    var retryable = false

    var errorDescription: String? { "\(step): \(detail)" }
}
