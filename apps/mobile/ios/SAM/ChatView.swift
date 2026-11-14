import SwiftUI

/// One chat session: the conversation, the task it runs, and follow-ups.
/// Polls while on screen; there is no push channel yet.
struct ChatView: View {
    let ref: SessionRef
    @State private var chat: ChatModel
    @State private var draft = ""
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef) {
        self.ref = ref
        _chat = State(initialValue: ChatModel(app: app))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let task = chat.state.session?.task {
                        TaskCard(task: task) { openURL($0) }
                    }
                    ForEach(chat.state.messages, id: \.id) { message in
                        MessageView(message: message).id(message.id)
                    }
                    if let error = chat.state.error {
                        Text(error.message).foregroundStyle(.red).font(.callout)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.state.messages.last?.id) {
                if let last = chat.state.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
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
                Composer(placeholder: "Reply to the agent…", text: $draft, busy: chat.state.sending) {
                    let content = draft
                    Task { if await chat.core.send(content: content) { draft = "" } }
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
