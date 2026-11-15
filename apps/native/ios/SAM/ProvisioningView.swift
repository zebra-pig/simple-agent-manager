import SwiftUI

/// The web chat's compact first-boot notice and four-stage track.
struct ProvisioningView: View {
    let state: ProvisioningState
    private var stage: Int { min(Int(state.stage), 3) }
    private var stages: [String] {
        [String(localized: "Provisioning VM"), String(localized: "Cloning repository"),
         String(localized: "Installing dependencies"), String(localized: "Starting agent")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(stages[stage]) · \(stage + 1) of 4")
                .font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = state.startedAt > 0
                    ? max(0, Int(context.date.timeIntervalSince1970) - Int(state.startedAt / 1000)) : 0
                Text(seconds < 60 ? String(localized: "\(seconds)s") : String(localized: "\(seconds / 60)m \(seconds % 60)s"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(detail) This usually takes 2–4 minutes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Capsule().fill(index <= stage ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var detail: String {
        switch state.step {
        case .waiting: String(localized: "Waiting for the task runner.")
        case .nodeSelection: String(localized: "Finding a server.")
        case .waitingForNodeCapacity: String(localized: "Waiting for server capacity.")
        case .nodeProvisioning: String(localized: "Setting up a new server.")
        case .nodeAgentReady: String(localized: "Waiting for server to start.")
        case .workspaceCreation: String(localized: "Creating workspace.")
        case .workspaceDispatch: String(localized: "Starting workspace on server.")
        case .workspaceReady: String(localized: "Setting up development environment.")
        case .attachmentTransfer: String(localized: "Uploading attachments to workspace.")
        case .agentSession: String(localized: "Starting AI agent.")
        }
    }
}
