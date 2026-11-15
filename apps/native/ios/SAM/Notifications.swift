import SwiftUI

@MainActor @Observable final class NotificationsModel {
    let core: NotificationsViewModel
    var state: NotificationsState
    init(app: App) {
        core = NotificationsViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}
extension Relay: NotificationsObserver where State == NotificationsState {
    func onStateChanged(state: NotificationsState) { send(state) }
}
@MainActor @Observable final class RequestModel {
    let core: RequestViewModel
    var state: RequestState
    init(app: App) {
        core = RequestViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}
extension Relay: RequestObserver where State == RequestState {
    func onStateChanged(state: RequestState) { send(state) }
}

struct NotificationsView: View {
    let app: App
    @Environment(\.openURL) private var openURL
    @State private var model: NotificationsModel
    init(app: App) { self.app = app; _model = State(initialValue: NotificationsModel(app: app)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error = model.state.error { Text(error.message).foregroundStyle(.red) }
                    if model.state.loading && model.state.items.isEmpty { ProgressView() }
                    if !model.state.loading && model.state.items.isEmpty && model.state.error == nil {
                        ContentUnavailableView("No notifications", systemImage: "bell")
                    }
                    ForEach(model.state.items, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.title).font(.headline)
                            if let id = item.requestId, let project = item.projectId {
                                RequestCard(app: app, project: project, session: item.sessionId ?? "", id: id, secret: item.kind == "secret_request", approval: item.kind == "operations_approval")
                            } else if let body = item.body { Text(body) }
                            VStack(alignment: .leading, spacing: 8) {
                                if let project = item.projectId, let session = item.sessionId {
                                    NavigationLink("Open conversation") { ChatView(app: app, ref: SessionRef(projectId: project, sessionId: session)) }
                                }
                                if let action = item.actionUrl, let url = notificationUrl(serverUrl: app.state().serverUrl, actionUrl: action).flatMap(URL.init(string:)) {
                                    Button("Open on web") { openURL(url) }
                                }
                                Button("Dismiss") { Task { await model.core.dismiss(id: item.id) } }
                            }.font(.callout)
                        }
                        .padding().glass(in: RoundedRectangle(cornerRadius: 20))
                    }
                }.padding()
            }
            .navigationTitle("Notifications")
            .refreshable { await model.core.load(projectId: "", sessionId: "") }
            .task {
                while !Task.isCancelled {
                    await model.core.load(projectId: "", sessionId: "")
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}

struct RequestCard: View {
    let project: String
    let session: String
    let id: String
    let secret: Bool
    let approval: Bool
    @State private var model: RequestModel
    @State private var value = ""
    @State private var confirmedVersion: String?
    init(app: App, project: String, session: String, id: String, secret: Bool, approval: Bool = false) {
        self.project = project; self.session = session; self.id = id; self.secret = secret; self.approval = approval
        _model = State(initialValue: RequestModel(app: app))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.state.title.isEmpty { Text(approval ? approvalTitle(model.state.title) : model.state.title).font(.headline) }
            Text(model.state.reason).textSelection(.enabled)
            if model.state.irreversible && model.state.canRespond { Text("Approving permanently deletes this resource. This cannot be undone.").foregroundStyle(.red) }
            if let error = model.state.error { Text(error.message).foregroundStyle(.red) }
            if model.state.busy { ProgressView() }
            if model.state.canRespond {
                if secret {
                    SecureField("Secret value", text: $value).autocorrectionDisabled()
                    if let version = model.state.existingVersion {
                        Text("This replaces the existing project value for all agents.").font(.caption)
                        Toggle("Replace the existing value", isOn: Binding(get: { confirmedVersion == version }, set: { confirmedVersion = $0 ? version : nil }))
                    }
                    HStack {
                        Button("Save secret") { respond(value) }
                            .disabled(value.isEmpty || (model.state.existingVersion != nil && confirmedVersion != model.state.existingVersion))
                        Button("Decline", role: .destructive) { respond("", decline: true) }
                    }
                } else if model.state.options.isEmpty {
                    TextField("Your answer", text: $value, axis: .vertical)
                    Button("Send answer") { respond(value) }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    ForEach(model.state.options, id: \.self) { option in
                        Button { respond(option) } label: {
                            if approval { Text(option == "approve" ? String(localized: "Approve") : String(localized: "Deny")) }
                            else { Text(option).multilineTextAlignment(.leading) }
                        }
                    }
                }
            } else if !model.state.status.isEmpty { Text(requestStatus(model.state.status)).font(.caption).foregroundStyle(.secondary) }
            if model.state.deliveryUnconfirmed { Text("Saved, but the agent could not be notified. Tell it in the conversation.").foregroundStyle(.orange) }
            if let answer = model.state.answer { Text(answer) }
            Button("Refresh") { Task { await load() } }.font(.caption)
        }
        .disabled(model.state.busy)
        .task {
            while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(15)) }
        }
        .onDisappear { value = ""; confirmedVersion = nil }
    }
    private func load() async {
        await model.core.load(projectId: project, sessionId: session, requestId: id, secret: secret, approval: approval)
    }
    private func respond(_ answer: String, decline: Bool = false) {
        Task {
            if await model.core.respond(projectId: project, sessionId: session, requestId: id, secret: secret, approval: approval, value: answer, decline: decline, expectedVersion: confirmedVersion) {
                value = ""; confirmedVersion = nil
            }
        }
    }
}
private func requestStatus(_ status: String) -> String {
    switch status {
    case "pending": String(localized: "Pending")
    case "answered": String(localized: "Answered")
    case "delivering": String(localized: "Answer is being delivered")
    case "fulfilled": String(localized: "Secret saved")
    case "declined": String(localized: "Declined")
    case "expired": String(localized: "Expired")
    case "approved": String(localized: "Approved")
    case "denied": String(localized: "Denied")
    case "executed": String(localized: "Executed")
    default: status
    }
}

private func approvalTitle(_ title: String) -> String {
    let parts = title.components(separatedBy: " · ")
    let action: String
    switch parts[0] {
    case "retry_snapshot": action = String(localized: "Retry snapshot")
    case "rerun_node_cleanup": action = String(localized: "Re-run node cleanup")
    case "sleep_session": action = String(localized: "Sleep session")
    case "delete_workspace": action = String(localized: "Delete workspace")
    case "delete_node": action = String(localized: "Delete node")
    case "restart_vm_agent": action = String(localized: "Restart VM agent")
    case "cancel_stuck_task": action = String(localized: "Cancel stuck task")
    default: action = parts[0]
    }
    return ([action] + parts.dropFirst()).joined(separator: " · ")
}
