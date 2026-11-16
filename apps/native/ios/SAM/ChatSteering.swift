import SwiftUI

/// Occupies the starter composer's profile-menu position.
struct ChatSteeringSelector: View {
    let intent: DeliveryIntent
    let hasFiles: Bool
    let steeringSupported: Bool?
    let select: (DeliveryIntent) -> Void

    private var locked: Bool { hasFiles || steeringSupported == false }
    private var queued: Bool { locked || intent == .queue }
    private var detail: LocalizedStringKey {
        hasFiles ? "Messages with files are sent when this turn ends."
            : steeringSupported == false ? "This agent takes messages when this turn ends."
            : queued ? "Sent when this turn ends."
            : "Joins this turn if the agent can take it; otherwise sent next."
    }

    var body: some View {
        Menu {
            Button { select(.steer) } label: {
                Label("Steer", systemImage: queued ? "arrow.turn.down.right" : "checkmark")
            }
            Button { select(.queue) } label: {
                Label("Queue", systemImage: queued ? "checkmark" : "text.line.last.and.arrowtriangle.forward")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: queued ? "text.line.last.and.arrowtriangle.forward" : "arrow.turn.down.right")
                Text(queued ? "Queue" : "Steer")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .glassButton()
        .buttonBorderShape(.capsule)
        .tint(.primary)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(locked)
        .accessibilityLabel("Message delivery")
        .accessibilityValue(Text(queued ? "Queue" : "Steer"))
        .accessibilityHint(Text(detail))
        .help(Text(detail))
    }
}

struct MessageDeliveryLabel: View {
    let status: String
    var body: some View {
        Group {
            switch status {
            case "steered": Label("Steered", systemImage: "checkmark")
            case "queued_instead": Label("Queued instead · sent next", systemImage: "text.line.last.and.arrowtriangle.forward")
            case "unconfirmed": Label("Delivery unconfirmed", systemImage: "questionmark.circle")
            case "not_delivered": Label("Not delivered", systemImage: "exclamationmark.circle")
            default: Label("Steering…", systemImage: "arrow.turn.down.right")
            }
        }.font(.caption).foregroundStyle(status == "not_delivered" ? .red : .secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
