import SwiftUI

/// Shared by the live chat and simulator review fixture.
struct ChatSteeringControls: View {
    let intent: DeliveryIntent
    let hasFiles: Bool
    let steeringSupported: Bool?
    let interrupting: Bool
    let error: String?
    let select: (DeliveryIntent) -> Void
    let interrupt: () -> Void

    private var locked: Bool { hasFiles || steeringSupported == false }
    private var queued: Bool { locked || intent == .queue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("Agent working", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(WorkingLabelStyle())
                Spacer(minLength: 0)
                Button(action: interrupt) {
                    HStack(spacing: 6) {
                        if interrupting { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "stop.fill").font(.caption) }
                        Text(interrupting ? "Interrupting…" : "Interrupt")
                    }.font(.subheadline.weight(.medium)).padding(.vertical, 10)
                }
                .tint(.red).disabled(interrupting)
                .accessibilityHint("Stops this turn so the agent can read queued messages.")
            }
            Picker("Message delivery", selection: Binding(get: { queued ? DeliveryIntent.queue : .steer }, set: select)) {
                Label("Steer now", systemImage: "arrow.turn.down.right").tag(DeliveryIntent.steer)
                Label("Queue next", systemImage: "text.line.last.and.arrowtriangle.forward").tag(DeliveryIntent.queue)
            }
            .pickerStyle(.segmented).disabled(locked)
            Text(hasFiles ? "Messages with files are sent when this turn ends." : steeringSupported == false ? "This agent takes messages when this turn ends." : queued ? "Sent when this turn ends." : "Joins this turn if the agent can take it; otherwise sent next.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 4)
    }
}

private struct WorkingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(.green)
            configuration.title
        }
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
