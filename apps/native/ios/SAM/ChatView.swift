import SwiftUI

/// One chat session: the conversation, the task it runs, and follow-ups.
/// Polls while on screen; there is no push channel yet.
struct ChatView: View {
    let app: App
    let ref: SessionRef
    @State private var chat: ChatModel
    @State private var draft = ""
    @State private var followsLatest = true
    @State private var tool: ChatTool?
    @State private var confirmEnd = false
    @State private var ending = false
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef) {
        self.app = app
        self.ref = ref
        _chat = State(initialValue: ChatModel(app: app))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.state.hasMore { Text("Showing the latest messages").font(.caption).foregroundStyle(.secondary) }
                    if chat.state.provisioning == nil, let task = chat.state.session?.task {
                        TaskCard(task: task) { openURL($0) }
                    }
                    ForEach(chat.state.items, id: \.id) { message in
                        Group {
                            if case let .document(document) = message.content {
                                DocumentCard(document: document, documents: chat.state.items.compactMap { if case let .document(d) = $0.content { return d }; return nil }, core: chat.core)
                            } else { TimelineItemView(item: message) }
                        }.id(message.id)
                    }
                    ForEach(chat.state.outbox, id: \.id) { message in
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(verbatim: message.text).padding(12).glass(in: RoundedRectangle(cornerRadius: 18))
                            Text(message.accepted ? "Queued" : "Sending…").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    ForEach(chat.state.requests, id: \.id) { request in
                        RequestCard(app: app, project: ref.projectId, session: request.sessionId ?? ref.sessionId, id: request.id, secret: request.secret, approval: request.approval)
                            .padding().glass(in: RoundedRectangle(cornerRadius: 20))
                    }
                    ForEach(chat.state.notifications.filter { item in
                        guard let id = item.requestId else { return true }
                        return !chat.state.requests.contains { $0.id == id }
                    }, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            if let id = item.requestId {
                                RequestCard(app: app, project: ref.projectId, session: ref.sessionId, id: id, secret: item.kind == "secret_request", approval: item.kind == "operations_approval")
                            } else if let body = item.body { Text(body) }
                            if let action = item.actionUrl, let url = notificationUrl(serverUrl: app.state().serverUrl, actionUrl: action).flatMap(URL.init(string:)) {
                                Button("Open on web") { openURL(url) }
                            }
                        }.padding().glass(in: RoundedRectangle(cornerRadius: 20))
                    }
                    if let error = chat.state.notificationsError { Text(error.message).foregroundStyle(.red) }
                    if let provisioning = chat.state.provisioning {
                        ProvisioningView(state: provisioning).id("provisioning")
                    }
                    if chat.state.working && chat.state.provisioning == nil { Text("Working").font(.caption).foregroundStyle(Color.accentColor) }
                    if let error = chat.state.error {
                        Text(error.message).foregroundStyle(.red).font(.callout)
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followsLatest = true }
                        .onDisappear { followsLatest = false }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .interactiveKeyboardDismiss()
            .onChange(of: chat.state.items) {
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: chat.state.provisioning) {
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: chat.state.outbox) { proxy.scrollTo("latest", anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !followsLatest {
                    Button {
                        withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.body.weight(.medium))
                            .frame(width: 28, height: 28)
                    }
                    .glassButton()
                    .buttonBorderShape(.circle)
                    .tint(.primary)
                    .accessibilityLabel(Text("Jump to latest"))
                    .padding()
                }
            }
        }
        .overlay {
            if chat.state.items.isEmpty && chat.state.loading { ProgressView() }
        }
        .navigationTitle(chat.state.session?.topic ?? String(localized: "Session"))
        .inlineTitle()
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Workspace and history") {
                        if let session = chat.state.session, canBrowse(session) {
                            Button("Files", systemImage: "folder") { tool = .files }
                            Button("Git", systemImage: "arrow.triangle.branch") { tool = .git }
                        }
                        Button("Timeline", systemImage: "clock") { tool = .timeline }
                        webTool("Related", icon: "link", action: .related)
                        Button("Resources", systemImage: "chart.xyaxis.line") { tool = .resources }
                        webTool("Automation", icon: "arrow.trianglehead.2.clockwise", action: .automation)
                        webTool("Comments", icon: "text.bubble", action: .comments)
                    }
                    Section("Session") {
                        if let session = chat.state.session {
                            if session.viewerAccess != nil { webTool("Share", icon: "person.2", action: .share) }
                            if session.task != nil {
                                if !(session.task?.status == "cancelled" && session.task?.terminalReason == "snapshot_expired") { webTool("Retry", icon: "arrow.clockwise", action: .retry) }
                                webTool("Fork", icon: "arrow.triangle.branch", action: .fork)
                            }
                        }
                    }
                    Section {
                        if chat.state.reportEnabled { webTool("Report", icon: "flag", action: .report) }
                        if let end = endLabel {
                            Button(end, systemImage: "checkmark.circle") { confirmEnd = true }.disabled(ending)
                        }
                        Button("Details", systemImage: "info.circle") { tool = .details }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Session tools")
                .glassButton()
            }
        }
        .sheet(item: $tool) { selected in
            ChatToolView(tool: selected, chat: chat)
        }
        .confirmationDialog(endLabel ?? String(localized: "Complete"), isPresented: $confirmEnd) {
            Button(endLabel ?? String(localized: "Complete"), role: .destructive) { ending = true; Task { await chat.core.endTask(); ending = false } }
        } message: { Text("This ends the task and stops its agent.") }
        .safeAreaInset(edge: .bottom) {
            if canReply {
                Composer(placeholder: "Reply to the agent…", text: $draft, busy: chat.state.sending, files: chat.files) {
                    let content = draft
                    draft = ""
                    Task { if !(await chat.core.send(content: content)), draft.isEmpty { draft = content } }
                }
            }
        }
        .task(id: ref) {
            chat.tools.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
            await chat.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(finished ? 20 : 4))
                if Task.isCancelled { break }
                await chat.core.refresh()
            }
        }
    }

    private func webTool(_ title: LocalizedStringKey, icon: String, action: WebChatTool) -> some View {
        Button {
            if let url = URL(string: chat.core.webToolUrl(tool: action)) { openURL(url) }
        } label: {
            Label { Text(title) + Text(" (web)") } icon: { Image(systemName: icon) }
        }
    }

    private func canBrowse(_ session: ChatSession) -> Bool {
        session.status == .active && session.workspaceId != nil && canDrive(session)
    }
    private func canDrive(_ session: ChatSession) -> Bool {
        session.viewerAccess == "owner" || session.viewerAccess == "grantee" || (session.viewerAccess == nil && session.isMine)
    }
    private var endLabel: String? {
        guard let session = chat.state.session, canDrive(session), let task = session.task else { return nil }
        switch task.status {
        case "in_progress", "sleeping": return String(localized: "Complete")
        case "draft", "ready", "queued", "delegated": return String(localized: "Cancel task")
        default: return nil
        }
    }

    private var finished: Bool {
        guard let status = chat.state.session?.status else { return false }
        return status == .stopped || status == .failed
    }

    private var canReply: Bool {
        guard let session = chat.state.session else { return false }
        return canDrive(session) && (session.status == .active || session.status == .sleeping)
    }
}

struct TimelineItemView: View {
    let item: ChatItem
    var body: some View {
        switch item.content {
        case .document: EmptyView()
        case let .user(text):
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: text).textSelection(.enabled).padding(12)
                    .glass(in: RoundedRectangle(cornerRadius: 18))
            }
        case let .agent(_, blocks):
            MarkdownView(blocks: blocks)
        case let .thinking(text):
            DisclosureGroup("Thinking") { Text(verbatim: text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        case let .activity(steps, summary):
            DisclosureGroup {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    switch step {
                    case let .thought(text):
                        DisclosureGroup("Thinking") { Text(verbatim: text).font(.callout).foregroundStyle(.secondary) }
                    case let .tool(call):
                        VStack(alignment: .leading, spacing: 6) {
                            Label { Text(verbatim: call.title ?? toolLabel(call.kind)) }
                                icon: { Image(systemName: call.status == .failed ? "exclamationmark.circle" : "terminal") }
                                .font(.callout).foregroundStyle(call.status == .failed ? Color.red : Color.secondary)
                            ForEach(call.locations, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()) }
                            if let output = call.output {
                                DisclosureGroup("Output") { CodeView(code: output, language: nil) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity · \(summary.toolCount) tools").font(.callout)
                    if summary.failedCount > 0 { Text("\(summary.failedCount) failed").font(.caption).foregroundStyle(.red) }
                    if summary.live, let title = summary.liveTitle { Text(verbatim: title).font(.caption).foregroundStyle(Color.accentColor) }
                }
            }
        case let .plan(entries):
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan").font(.headline)
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Label(entry.content, systemImage: entry.status == .completed ? "checkmark.circle.fill" : entry.status == .inProgress ? "circle.inset.filled" : "circle")
                        .font(.callout).foregroundStyle(entry.status == .inProgress ? Color.accentColor : Color.secondary)
                }
            }
        case let .notice(notice):
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.headline ?? (notice.source == .workspace ? String(localized: "Report from the workspace") : String(localized: "Conversation context")))
                    .font(.callout.weight(.medium))
                if let detail = notice.detail { DisclosureGroup("Details") { Text(verbatim: detail).font(.callout).textSelection(.enabled) } }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: RoundedRectangle(cornerRadius: 16), tint: notice.severity == .error ? .red.opacity(0.1) : nil)
        }
    }
}

struct TaskCard: View {
    let task: TaskSummary
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(taskStatusLabel(task.status), systemImage: "checklist")
                    .font(.subheadline.bold())
                if let step = task.executionStep, task.status == "in_progress" || task.status == "queued" {
                    Text(verbatim: humanized(step)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error = task.errorMessage {
                Text(verbatim: error).font(.callout).foregroundStyle(.red)
            }
            if let summary = task.outputSummary {
                Text(summary).font(.callout)
            }
            if let pr = task.outputPrUrl, let url = URL(string: pr) {
                Button("Open pull request", systemImage: "arrow.triangle.pull") { open(url) }
                    .font(.callout)
                    .glassButton()
            } else if let branch = task.outputBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private func toolLabel(_ kind: ToolKind) -> String {
    switch kind {
    case .read: String(localized: "Read file")
    case .edit: String(localized: "Edit file")
    case .delete: String(localized: "Delete file")
    case .move: String(localized: "Move file")
    case .search: String(localized: "Search")
    case .execute: String(localized: "Run command")
    case .think: String(localized: "Thinking")
    case .fetch: String(localized: "Fetch resource")
    case .switchMode: String(localized: "Change mode")
    case .other: String(localized: "Tool call")
    }
}
