import SwiftUI

/// One chat session: the conversation, the task it runs, and follow-ups.
/// Polls while on screen; there is no push channel yet.
struct ChatView: View {
    let ref: SessionRef
    @State private var chat: ChatModel
    @State private var draft = ""
    @State private var tool: ChatTool?
    @State private var confirmEnd = false
    @State private var ending = false
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef) {
        self.ref = ref
        _chat = State(initialValue: ChatModel(app: app))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.state.provisioning == nil, let task = chat.state.session?.task {
                        TaskCard(task: task) { openURL($0) }
                    }
                    ForEach(chat.state.messages, id: \.id) { message in
                        MessageView(message: message).id(message.id)
                    }
                    if let provisioning = chat.state.provisioning {
                        ProvisioningView(state: provisioning).id("provisioning")
                    }
                    if let error = chat.state.error {
                        Text(error.message).foregroundStyle(.red).font(.callout)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .interactiveKeyboardDismiss()
            .onChange(of: chat.state.messages.last?.id) {
                if let last = chat.state.messages.last?.id {
                    withAnimation { proxy.scrollTo(chat.state.provisioning == nil ? last : "provisioning", anchor: .bottom) }
                }
            }
            .onChange(of: chat.state.provisioning != nil) {
                if chat.state.provisioning != nil {
                    withAnimation { proxy.scrollTo("provisioning", anchor: .bottom) }
                }
            }
        }
        .overlay {
            if chat.state.messages.isEmpty && chat.state.loading { ProgressView() }
        }
        .navigationTitle(chat.state.session?.topic ?? String(localized: "Session"))
        .inlineTitle()
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
                    Task { if await chat.core.send(content: content) { draft = "" } }
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

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .accentColor.opacity(0.35))
            }
        case .assistant:
            Text(markdown(message.content)).textSelection(.enabled)
        case .thinking:
            Text(message.content)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(4)
        case .tool:
            Text(message.content)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .system, .plan, .unknown:
            Text(markdown(message.content))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
