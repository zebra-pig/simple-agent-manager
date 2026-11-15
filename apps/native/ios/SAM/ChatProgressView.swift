import SwiftUI

/// Informational status is available on demand, outside the conversation.
struct ChatProgressView: View {
    let state: ChatState
    let serverUrl: String
    @Environment(\.openURL) private var openURL

    private var notifications: [Notification] { state.notifications.filter { $0.requestId == nil } }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let provisioning = state.provisioning {
                ProvisioningView(state: provisioning)
            }
            if let task = state.session?.task {
                TaskCard(task: task) { openURL($0) }
            }
            if state.working { Text("Working").font(.callout).foregroundStyle(.secondary) }
            ForEach(notifications, id: \.id) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline)
                    if let body = item.body { Text(body) }
                    if let action = item.actionUrl, let url = notificationUrl(serverUrl: serverUrl, actionUrl: action).flatMap(URL.init(string:)) {
                        Button("Open on web") { openURL(url) }.glassButton()
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: RoundedRectangle(cornerRadius: 20))
            }
            if let error = state.notificationsError { Text(error.message).foregroundStyle(.red) }
            if state.provisioning == nil && state.session?.task == nil && notifications.isEmpty && !state.working && state.notificationsError == nil {
                Text("No progress updates yet.").foregroundStyle(.secondary)
            }
        }
    }
}
