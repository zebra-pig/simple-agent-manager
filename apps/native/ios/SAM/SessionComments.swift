import SwiftUI

/// The chat's comment inbox: web's buckets as filters, threads newest first.
struct CommentsView: View {
    let ref: SessionRef
    let chat: ChatModel
    let model: CommentsModel
    @State private var filter: CommentBucket?
    @State private var choseFilter = false

    private var state: CommentsState { model.state }
    private var shown: [CommentThread] { state.threads.filter { filter == nil || $0.bucket == filter } }

    var body: some View {
        SessionToolSheet(title: "Comments", loading: state.loading, errors: [state.error?.message]) {
            if let session = chat.state.session { await model.core.load(projectId: ref.projectId, session: session) }
            // Opens on "Needs you" when something is waiting for the viewer.
            if !choseFilter { filter = model.state.counts.needsYou > 0 ? .needsYou : nil }
        } content: {
            List {
                if state.counts.all > 0 {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip(nil, "All", state.counts.all)
                                chip(.needsYou, "Needs you", state.counts.needsYou)
                                chip(.withAgent, "With agent", state.counts.withAgent)
                                chip(.open, "Open", state.counts.open)
                                chip(.resolved, "Resolved", state.counts.resolved)
                            }.padding(.horizontal, 16)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(shown, id: \.id) { thread in
                        NavigationLink {
                            CommentThreadView(threadId: thread.id, chat: chat, model: model)
                        } label: { CommentInboxRow(thread: thread, chat: chat.state) }
                    }
                } footer: {
                    if state.hasMore { Text("Only the most recent comments are shown.") }
                }
            }
            .overlay {
                if state.loaded && state.threads.isEmpty {
                    ContentUnavailableView("No comments in this session", systemImage: "text.bubble",
                                           description: Text("Touch and hold a message to comment on it."))
                } else if state.loaded && shown.isEmpty {
                    ContentUnavailableView(filter == .needsYou ? "You're all caught up" : "Nothing here", systemImage: "checkmark.bubble",
                                           description: Text("\(state.counts.all) comments in this session — switch filters to see them."))
                }
            }
            .initialLoading(state.loading && !state.loaded)
        }
    }

    private func chip(_ bucket: CommentBucket?, _ title: LocalizedStringKey, _ count: UInt32) -> some View {
        Button {
            choseFilter = true
            filter = bucket
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(filter == bucket ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(filter == bucket ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .opacity(count == 0 && filter != bucket ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == bucket ? .isSelected : [])
    }
}

private struct CommentInboxRow: View {
    let thread: CommentThread
    let chat: ChatState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: thread.quote.map { "“\($0)”" } ?? anchorLabel(thread.messageId, chat))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(verbatim: relativeTime(thread.lastActivityAt)).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: thread.body).lineLimit(3)
            HStack(spacing: 6) {
                Text(verbatim: lastActorLine(thread)).font(.caption).foregroundStyle(.secondary)
                if !thread.replies.isEmpty {
                    Label("\(thread.replies.count)", systemImage: "arrowshape.turn.up.left").labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Pill(text: bucketLabel(thread.bucket), tint: bucketTint(thread.bucket))
            }
        }.padding(.vertical, 2)
    }
}

/// One thread: what it is on, the conversation, and its actions.
struct CommentThreadView: View {
    let threadId: String
    let chat: ChatModel
    let model: CommentsModel
    @State private var reply = ""
    @State private var sendReply = false
    @State private var clientId = UUID().uuidString
    @FocusState private var focused: Bool

    private var thread: CommentThread? { model.state.threads.first { $0.id == threadId } }

    var body: some View {
        List {
            if let thread {
                Section {
                    if let quote = thread.quote {
                        Text(verbatim: quote).font(.callout).foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.4)).frame(width: 3) }
                    }
                    Text(verbatim: messageExcerpt(thread.messageId, chat.state)).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                } header: { Text(verbatim: anchorLabel(thread.messageId, chat.state)) }
                Section {
                    CommentBubble(author: thread.author, text: thread.body, time: thread.createdAt, sentToAgent: false)
                    ForEach(thread.replies, id: \.id) { CommentBubble(author: $0.author, text: $0.body, time: $0.createdAt, sentToAgent: $0.sentToAgent) }
                } header: {
                    HStack { Text("Thread"); Spacer(); Pill(text: statusLabel(thread.status), tint: bucketTint(thread.bucket)) }
                }
                if model.state.canComment {
                    Section {
                        if thread.status == .open && model.state.canSendToAgent {
                            Button("Send to agent", systemImage: "paperplane") {
                                Task { _ = await model.core.sendToAgent(threadId: thread.id, clientId: UUID().uuidString) }
                            }
                        }
                        if thread.status == .resolved {
                            Button("Reopen", systemImage: "arrow.uturn.backward") { Task { _ = await model.core.reopen(threadId: thread.id) } }
                        } else {
                            Button("Resolve", systemImage: "checkmark.circle") { Task { _ = await model.core.resolve(threadId: thread.id) } }
                        }
                    }.disabled(model.state.saving).tint(.primary)
                }
            } else {
                ContentUnavailableView("Comment unavailable", systemImage: "text.bubble")
            }
        }
        .navigationTitle("Comment")
        .inlineTitle()
        .safeAreaInset(edge: .bottom) {
            if model.state.canComment, thread != nil {
                CommentComposer(text: $reply, sendToAgent: $sendReply, placeholder: "Reply…",
                                canSendToAgent: model.state.canSendToAgent, saving: model.state.saving,
                                submitTitle: sendReply ? "Reply & send" : "Reply") {
                    let body = reply
                    Task {
                        if await model.core.reply(threadId: threadId, body: body, sendToAgent: sendReply, clientId: clientId) {
                            reply = ""; sendReply = false; clientId = UUID().uuidString
                        }
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
        }
    }
}

private struct CommentBubble: View {
    let author: CommentAuthor
    let text: String
    let time: Int64
    let sentToAgent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: author.isAgent ? "sparkles" : "person.crop.circle.fill").foregroundStyle(.secondary)
                Text(verbatim: authorName(author)).font(.subheadline.weight(.semibold))
                Text(verbatim: relativeTime(time)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if sentToAgent { Pill(text: String(localized: "Sent to agent"), tint: .blue) }
            }
            Text(verbatim: text).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}

/// The composer shared by new comments and replies.
struct CommentComposer: View {
    @Binding var text: String
    @Binding var sendToAgent: Bool
    let placeholder: LocalizedStringKey
    let canSendToAgent: Bool
    let saving: Bool
    let submitTitle: LocalizedStringKey
    let submit: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical).lineLimit(2...8)
            HStack {
                if canSendToAgent {
                    Picker("Action", selection: $sendToAgent) {
                        Text("Add note").tag(false)
                        Text("Send to agent").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                } else {
                    Text("Visible to everyone in this project. Doesn't message the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: submit) { LoadingLabel(title: submitTitle, loading: saving).fontWeight(.semibold).lineLimit(1).fixedSize() }
                    .glassButton()
                    .disabled(empty || saving)
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Comment on one message, started from the message's menu.
struct NewCommentView: View {
    let messageId: String
    let chat: ChatModel
    let model: CommentsModel
    let ref: SessionRef
    @State private var text = ""
    @State private var sendToAgent = false
    @State private var clientId = UUID().uuidString
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: messageExcerpt(messageId, chat.state)).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                } header: { Text(verbatim: anchorLabel(messageId, chat.state)) } footer: {
                    if model.state.canSendToAgent && sendToAgent {
                        Text("Send to agent creates a follow-up instruction with the quoted message context.")
                    }
                }
            }
            .navigationTitle("New comment")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if model.state.loaded && !model.state.canComment {
                    Text("You can view this chat, but not comment on it.").font(.callout).foregroundStyle(.secondary).padding()
                } else {
                    CommentComposer(text: $text, sendToAgent: $sendToAgent, placeholder: "Add a comment…",
                                    canSendToAgent: model.state.canSendToAgent, saving: model.state.saving,
                                    submitTitle: sendToAgent ? "Comment & send" : "Comment") {
                        let body = text
                        Task {
                            if await model.core.create(messageId: messageId, quote: nil, body: body, sendToAgent: sendToAgent, clientId: clientId) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.state.loaded)
                    .padding(.horizontal).padding(.bottom, 8)
                }
            }
            .task {
                if !model.state.loaded, let session = chat.state.session {
                    await model.core.load(projectId: ref.projectId, session: session)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .floatingErrors([model.state.error?.message])
    }
}

// MARK: - Words

private func anchorLabel(_ messageId: String, _ chat: ChatState) -> String {
    switch chat.items.first(where: { $0.id == messageId })?.content {
    case .user: String(localized: "On a message")
    case .agent, .thinking, .activity: String(localized: "On the agent's reply")
    default: String(localized: "On a message")
    }
}

private func messageExcerpt(_ messageId: String, _ chat: ChatState) -> String {
    guard let item = chat.items.first(where: { $0.id == messageId }) else {
        return String(localized: "This message is earlier in the conversation.")
    }
    switch item.content {
    case let .user(text, _): return text
    case let .agent(text, _): return text
    case let .thinking(text): return text
    default: return String(localized: "Agent activity")
    }
}

private func authorName(_ author: CommentAuthor) -> String {
    if author.isViewer { return String(localized: "You") }
    return author.name ?? (author.isAgent ? String(localized: "Agent") : String(localized: "Someone"))
}

private func lastActorLine(_ thread: CommentThread) -> String {
    let actor = thread.replies.last?.author ?? thread.author
    if actor.isViewer { return thread.replies.isEmpty ? String(localized: "You commented") : String(localized: "You replied") }
    let name = authorName(actor)
    return thread.replies.isEmpty ? String(localized: "\(name) commented") : String(localized: "\(name) replied")
}

private func bucketLabel(_ bucket: CommentBucket) -> String {
    switch bucket {
    case .needsYou: String(localized: "Needs you")
    case .withAgent: String(localized: "With agent")
    case .open: String(localized: "Open")
    case .resolved: String(localized: "Resolved")
    }
}
private func bucketTint(_ bucket: CommentBucket) -> Color {
    switch bucket {
    case .needsYou: .orange
    case .withAgent: .blue
    case .open: .secondary
    case .resolved: .green
    }
}
private func statusLabel(_ status: CommentStatus) -> String {
    switch status {
    case .open: String(localized: "Open")
    case .sent: String(localized: "Sent to agent")
    case .resolved: String(localized: "Resolved")
    }
}
