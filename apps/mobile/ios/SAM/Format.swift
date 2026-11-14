import SwiftUI

extension Date {
    init(millis: Int64) { self.init(timeIntervalSince1970: TimeInterval(millis) / 1000) }
}

func statusLabel(_ session: ChatSession) -> String {
    switch session.status {
    case .active: session.isIdle ? "Waiting for you" : "Working"
    case .sleeping: "Sleeping"
    case .stopped: "Stopped"
    case .failed: "Failed"
    case .unknown: "Unknown"
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

/// `TaskStatus` values (packages/shared/src/types/task.ts) for people.
func taskStatusLabel(_ status: String) -> String {
    status.replacingOccurrences(of: "_", with: " ").capitalized
}
