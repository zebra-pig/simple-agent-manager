import SwiftUI

// Every user-facing string in the app goes through the String Catalog
// (Localizable.xcstrings): SwiftUI literals are extracted automatically,
// strings built in code use String(localized:). The Rust core sends no wording,
// only values like UserError, which are given words here.

extension Date {
    init(millis: Int64) { self.init(timeIntervalSince1970: TimeInterval(millis) / 1000) }
}

extension UserError {
    var message: String {
        switch self {
        case .offline: String(localized: "Can't reach the server. Check your connection and try again.")
        case .sessionEnded: String(localized: "Your session has ended. Please sign in again.")
        case let .invalidServer(input): String(localized: "\(input) is not a server address.")
        case .httpsRequired: String(localized: "The server address must start with https://.")
        case .signInExpired: String(localized: "The sign-in code expired. Please try again.")
        case let .server(message): message
        case let .unexpected(detail): String(localized: "Something went wrong (\(detail)).")
        }
    }
}

func statusLabel(_ session: ChatSession) -> String {
    switch session.status {
    case .active: session.isIdle ? String(localized: "Waiting for you") : String(localized: "Working")
    case .sleeping: String(localized: "Sleeping", comment: "Session or task status")
    case .stopped: String(localized: "Stopped", comment: "Session or task status")
    case .failed: String(localized: "Failed", comment: "Session or task status")
    case .unknown: String(localized: "Unknown", comment: "Session or task status")
    }
}

struct StatusDot: View {
    let session: ChatSession

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(statusLabel(session))
    }

    private var color: Color {
        switch session.status {
        case .active: session.isIdle ? .orange : .green
        case .sleeping: .blue
        case .failed: .red
        case .stopped, .unknown: .gray
        }
    }
}

/// `TaskStatus` values (TASK_STATUSES in packages/shared/src/types/task.ts) for people.
func taskStatusLabel(_ status: String) -> String {
    switch status {
    case "draft": String(localized: "Draft", comment: "Session or task status")
    case "ready": String(localized: "Ready", comment: "Session or task status")
    case "queued": String(localized: "Queued", comment: "Session or task status")
    case "delegated": String(localized: "Delegated", comment: "Session or task status")
    case "in_progress": String(localized: "In progress", comment: "Session or task status")
    case "sleeping": String(localized: "Sleeping", comment: "Session or task status")
    case "completed": String(localized: "Completed", comment: "Session or task status")
    case "failed": String(localized: "Failed", comment: "Session or task status")
    case "cancelled": String(localized: "Cancelled", comment: "Session or task status")
    default: humanized(status)
    }
}

/// Execution steps (TASK_EXECUTION_STEPS) are progress detail; shown humanized, not translated.
func humanized(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
}
