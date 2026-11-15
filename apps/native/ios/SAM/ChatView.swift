import SwiftUI

/// One chat session: the conversation, the task it runs, and follow-ups.
/// Polls while on screen; there is no push channel yet.
struct ChatView: View {
    let ref: SessionRef
    @State private var chat: ChatModel
    @State private var draft = ""
    @State private var followsLatest = true
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef) {
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
                        TimelineItemView(item: message).id(message.id)
                    }
                    ForEach(chat.state.outbox, id: \.id) { message in
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(verbatim: message.text).padding(12).glass(in: RoundedRectangle(cornerRadius: 18))
                            Text(message.accepted ? "Queued" : "Sending…").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let session = chat.state.session {
                    HStack(spacing: 6) {
                        StatusDot(session: session)
                        Text(statusLabel(session)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
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
            await chat.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(finished ? 20 : 4))
                if Task.isCancelled { break }
                await chat.core.refresh()
            }
        }
    }

    private var finished: Bool {
        guard let status = chat.state.session?.status else { return false }
        return status == .stopped || status == .failed
    }

    private var canReply: Bool {
        guard let session = chat.state.session else { return false }
        return session.status == .active || session.status == .sleeping
    }
}

struct TimelineItemView: View {
    let item: ChatItem
    var body: some View {
        switch item.content {
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
