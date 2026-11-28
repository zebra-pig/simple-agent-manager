import SwiftUI

/// One chat session: the conversation, the task it runs, and follow-ups.
/// Polls while on screen; there is no push channel yet.
struct ChatView: View {
    let app: App
    let ref: SessionRef
    @State private var chat: ChatModel
    @State private var commands: CommandsModel
    @State private var requests = ChatRequests()
    @ChatDraft private var draft: String
    @State private var submission = ChatSubmission()
    @State private var historyCancellation = 0
    @State private var followsLatest = true
    #if os(iOS)
    @State private var transcriptControl = ChatTranscriptControl()
    #else
    @State private var historyInteraction = 0
    @State private var historyGestureActive = false
    @GestureState private var historyDragging = false
    @State private var visibleMessage: String?
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollControl = ChatScrollControl()
    @State private var scrollProxy: ScrollViewProxy?
    #endif
    @State private var tool: ChatTool?
    @State private var sessionSheet: SessionSheet?
    @State private var comments: CommentsModel
    @State private var confirmEnd = false
    @State private var ending = false
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef, model: ChatModel? = nil) {
        self.app = app
        self.ref = ref
        let account = app.state()
        _draft = ChatDraft(server: account.serverUrl, user: account.viewer?.id ?? "",
                           project: ref.projectId, session: ref.sessionId)
        _chat = State(initialValue: model ?? ChatModel(app: app))
        _commands = State(initialValue: CommandsModel(app: app))
        _comments = State(initialValue: CommentsModel(app: app))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            conversation
            if !followsLatest {
                ChatJumpButton {
                    historyCancellation += 1
                    chat.showLatest()
                    jumpToLatest(animated: true)
                }
            }
        }
        .onChange(of: chat.state.outbox) {
            historyCancellation += 1
            chat.showLatest()
            jumpToLatest(animated: false)
        }
        .overlay {
            if chat.state.items.isEmpty && chat.state.loading { ProgressView() }
        }
        .navigationTitle(chat.state.session?.topic ?? String(localized: "Session"))
        .inlineTitle()
        .hidesTabBarWhenPushed()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Workspace and history") {
                        if let session = chat.state.session, canBrowse(session) {
                            Button("Files", systemImage: "folder") { tool = .files }
                            Button("Git", systemImage: "arrow.triangle.branch") { tool = .git }
                        }
                        if let session = chat.state.session, session.workspaceId != nil,
                           session.viewerAccess == "owner" || (session.viewerAccess == nil && session.isMine) {
                            Button("Ports", systemImage: "network") { tool = .ports }
                        }
                        Button("Timeline", systemImage: "clock") { tool = .timeline }
                        Button("Related", systemImage: "link") { sessionSheet = .related }
                        Button("Resources", systemImage: "chart.xyaxis.line") { tool = .resources }
                        Button("Automation", systemImage: "arrow.trianglehead.2.clockwise") { sessionSheet = .automation }
                        Button("Comments", systemImage: "text.bubble") { sessionSheet = .comments }
                    }
                    Section("Session") {
                        Button("Progress", systemImage: "list.bullet.clipboard") { tool = .progress }
                        if let session = chat.state.session {
                            if session.viewerAccess != nil { Button("Share", systemImage: "person.2") { sessionSheet = .share } }
                            if session.task != nil {
                                if !(session.task?.status == "cancelled" && session.task?.terminalReason == "snapshot_expired") {
                                    Button("Retry", systemImage: "arrow.clockwise") { sessionSheet = .retry }
                                }
                                Button("Fork", systemImage: "arrow.triangle.branch") { sessionSheet = .fork }
                            }
                        }
                    }
                    Section {
                        if chat.state.reportEnabled { Button("Report", systemImage: "flag") { sessionSheet = .report } }
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
            ChatToolView(tool: selected, chat: chat, serverUrl: app.state().serverUrl)
                .modifier(ChatGalleryPresentation(chat: chat, app: app))
        }
        .modifier(ChatGalleryPresentation(chat: chat, app: app))
        .sheet(item: $sessionSheet) { sheet in sessionSheetView(sheet) }
        .confirmationDialog(endLabel ?? String(localized: "Complete"), isPresented: $confirmEnd) {
            Button(endLabel ?? String(localized: "Complete"), role: .destructive) { ending = true; Task { await chat.core.endTask(); ending = false } }
        } message: { Text("This ends the task and stops its agent.") }
        .safeAreaInset(edge: .bottom) {
            if canReply {
                VStack(spacing: 0) {
                    replyComposer
                }
            }
        }
        .task(id: ref) { await commands.core.load(projectId: ref.projectId) }
        .task(id: requestKeys) { await requests.poll(app: app, project: ref.projectId, keys: requestKeys) }
        .task(id: ref) {
            chat.tools.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
            await chat.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(finished ? 20 : 4))
                if Task.isCancelled { break }
                await chat.core.refresh()
            }
        }
        .floatingErrors([chat.state.error?.message, chat.state.interruptError?.message, chat.state.historyError?.message])
    }

    /// Everything below the messages, oldest first: what was sent but not yet
    /// in the transcript, open requests, and provisioning progress.
    private var rows: [ChatRow] {
        let transcript = chat.transcript
        var rows = transcript.items.map(ChatRow.message)
        rows += transcript.outbox.map(ChatRow.outbox)
        rows += requestKeys.reversed().filter { requests.visible($0) != nil }.map(ChatRow.request)
        if let provisioning = transcript.provisioning { rows.append(.provisioning(provisioning)) }
        return rows
    }

    @ViewBuilder private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case let .message(message):
            messageRow(message)
                .environment(\.selectionComment, commentable(message) ? { sessionSheet = .newComment(message.id) } : nil)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-message-\(message.id)")
        case let .outbox(message):
            VStack(alignment: .trailing, spacing: 4) {
                UserMessageView(text: message.text, attachments: message.attachments, core: chat.core)
                if message.deliveryIntent == .steer { MessageDeliveryLabel(status: "steering") }
                else { Text(message.accepted ? "Queued" : "Sending…").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        case let .request(key):
            if let model = requests.visible(key) {
                RequestCard(chat: key, project: ref.projectId, model: model)
            }
        case let .provisioning(state):
            ProvisioningView(state: state)
        }
    }

    private var earlier: ChatTranscriptEarlier? {
        guard chat.state.hasMore || chat.state.loadingHistory else { return nil }
        return ChatTranscriptEarlier(loading: chat.state.loadingHistory, failed: chat.state.historyError != nil)
    }

    private func follow(_ latest: Bool) {
        if latest { chat.showLatest() } else { chat.browseHistory() }
    }

    #if os(iOS)
    /// A plain, upright collection view that runs on behind the navigation bar
    /// and the composer, with the system's scroll edge effect under the bar.
    private var conversation: some View {
        GeometryReader { geometry in
            ChatTranscript(rows: rows, earlier: earlier, control: transcriptControl,
                           insets: geometry.safeAreaInsets,
                           followsLatest: Binding(get: { followsLatest }, set: { latest in
                               followsLatest = latest
                               follow(latest)
                           }),
                           browse: { chat.browseHistory() },
                           loadEarlier: { Task { await chat.core.loadOlder() } },
                           comment: { row in
                               guard case let .message(message) = row, commentable(message) else { return nil }
                               return { sessionSheet = .newComment(message.id) }
                           }) { row in
                ChatRowHost { rowView(row) }
            }
            // Insets above already include the keyboard. Keep the transcript
            // full height so SwiftUI does not also subtract the keyboard from
            // its viewport, lifting the messages a second time.
            .ignoresSafeArea(.all)
        }
    }

    private func jumpToLatest(animated: Bool) {
        transcriptControl.jumpToLatest(animated: animated)
    }
    #else
    /// macOS keeps a SwiftUI scroll view, upright, where `textSelection`
    /// already selects ranges.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let earlier {
                        ChatHistoryPager(loading: earlier.loading, error: chat.state.historyError?.message,
                                         viewportHeight: viewportHeight, cancellation: historyCancellation,
                                         interaction: historyInteraction) {
                            Task { await chat.core.loadOlder() }
                        }
                    }
                    ForEach(rows) { row in
                        rowView(row)
                            .contextMenu {
                                if case let .message(message) = row, commentable(message) {
                                    Button("Comment", systemImage: "text.bubble") { sessionSheet = .newComment(message.id) }
                                }
                            }
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatMessageFrames.self,
                                    value: [row.id: geometry.frame(in: .named("chatViewport"))])
                            })
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .modifier(ChatBottomTracking(followsLatest: $followsLatest))
                }
                .scrollTargetLayout()
                .padding()
            }
            .coordinateSpace(name: "chatViewport")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ChatViewportHeight.self, value: geometry.size.height)
            })
            .onPreferenceChange(ChatMessageFrames.self) { scrollControl.messageFrames = $0 }
            .onPreferenceChange(ChatViewportHeight.self) {
                viewportHeight = $0
                scrollControl.viewportHeight = $0
            }
            .onAppear {
                scrollProxy = proxy
                chat.willUpdateItems = {
                    if !followsLatest { scrollControl.preserveReadingPosition(using: proxy) }
                }
            }
            .onDisappear { chat.willUpdateItems = nil }
            .modifier(ChatScrollTracking(control: scrollControl, followsLatest: followsLatest, visibleMessage: $visibleMessage))
            .simultaneousGesture(DragGesture()
                .updating($historyDragging) { _, dragging, _ in dragging = true }
                .onChanged { gesture in
                    scrollControl.readManually()
                    if !historyGestureActive, abs(gesture.translation.height) > abs(gesture.translation.width) {
                        historyGestureActive = true
                        chat.browseHistory()
                        historyInteraction += 1
                    }
                })
            .onChange(of: historyDragging) { _, dragging in
                if !dragging { historyGestureActive = false }
            }
            .onChange(of: chat.transcript.items) {
                if followsLatest && !chat.state.loadingHistory { scrollControl.jump(using: proxy, to: "latest", animated: false) }
            }
            .onChange(of: followsLatest) { _, latest in follow(latest) }
        }
    }

    private func jumpToLatest(animated: Bool) {
        guard let scrollProxy else { return }
        scrollControl.jump(using: scrollProxy, to: "latest", animated: animated)
    }
    #endif

    /// Requests from notifications and from the conversation, newest first.
    private var requestKeys: [ChatRequestKey] {
        let transcript = chat.transcript
        let notified = transcript.notifications.compactMap { item -> ChatRequestKey? in
            guard let id = item.requestId, !transcript.requests.contains(where: { $0.id == id }) else { return nil }
            return ChatRequestKey(id: id, session: item.sessionId ?? ref.sessionId,
                                  secret: item.kind == "secret_request", approval: item.kind == "operations_approval")
        }
        let referenced = transcript.requests.map {
            ChatRequestKey(id: $0.id, session: $0.sessionId ?? ref.sessionId, secret: $0.secret, approval: $0.approval)
        }
        // One card per request: two notifications for a request can differ in kind.
        var seen = Set<[String]>()
        return (notified.reversed() + referenced.reversed()).filter { seen.insert([$0.session, $0.id]).inserted }
    }

    private var replyComposer: some View {
        let stopping = chat.state.working
            && draft.isEmpty
            && chat.state.attachments.isEmpty
        var composer = Composer(placeholder: composerPlaceholder, text: $draft,
            busy: submission.sending || chat.state.sending || chat.state.interrupting,
            files: chat.files, commands: commands.state.commands) {
                if stopping { Task { await chat.core.interrupt() } }
                else { sendReply() }
            } accessory: {
                if chat.state.working {
                    ChatSteeringSelector(intent: chat.state.deliveryIntent,
                        hasFiles: !chat.state.attachments.isEmpty,
                        steeringSupported: chat.state.steeringSupported,
                        select: { chat.core.setDeliveryIntent(intent: $0) })
                }
            }
        composer.allowsEmpty = stopping
        composer.sendLabel = stopping ? "Stop agent" : "Send"
        composer.sendIcon = stopping ? "stop.fill" : "arrow.up"
        return composer
    }

    private func sendReply() {
        guard !chat.state.sending else { return }
        submission.send(draft: _draft) { content in
            await chat.core.send(content: content)
        }
    }

    private var composerPlaceholder: LocalizedStringKey {
        guard chat.state.working else { return "Reply to the agent…" }
        return chat.state.deliveryIntent == .steer && chat.state.attachments.isEmpty && chat.state.steeringSupported != false
            ? "Steer the agent…" : "Queue next…"
    }

    @ViewBuilder private func sessionSheetView(_ sheet: SessionSheet) -> some View {
        switch sheet {
        case .related: RelatedWorkView(app: app, ref: ref, chat: chat.core)
        case .automation: AutomationView(app: app, ref: ref)
        case .comments: CommentsView(ref: ref, chat: chat, model: comments)
        case let .newComment(messageId): NewCommentView(messageId: messageId, chat: chat, model: comments, ref: ref)
        case .share:
            ShareView(app: app, ref: ref, shareable: chat.state.session.map { $0.status == .active || $0.status == .sleeping } ?? false,
                      topic: chat.state.session?.topic)
        case .report:
            ReportIssueView(app: app, refs: ReportRefs(sessionId: ref.sessionId, taskId: chat.state.session?.taskId ?? chat.state.session?.task?.id,
                                                       nodeId: chat.tools.state.workspace?.nodeId))
        case .retry, .fork:
            if let session = chat.state.session {
                // The Projects stack opens the new chat, wherever this one was opened from.
                DerivedTaskView(app: app, kind: sheet == .retry ? .retry : .fork, ref: ref, session: session) { PushRouter.shared.pending = $0 }
            }
        }
    }

    @ViewBuilder private func messageRow(_ message: ChatItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if case let .document(document) = message.content {
                DocumentCard(document: document, documents: chat.transcript.items.compactMap { if case let .document(d) = $0.content { return d }; return nil }, core: chat.core)
            } else if case let .user(text, attachments) = message.content {
                VStack(alignment: .trailing, spacing: 4) {
                    UserMessageView(text: text, attachments: attachments, core: chat.core)
                    if let delivery = chat.transcript.deliveries.first(where: { $0.messageId == message.id }) {
                        MessageDeliveryLabel(status: delivery.status)
                    }
                }
            } else { TimelineItemView(item: message) }
        }
    }

    /// Web takes new comments on user and agent messages, not on notices or tool activity.
    private func commentable(_ message: ChatItem) -> Bool {
        switch message.content {
        case .user, .agent: true
        default: false
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
        case let .user(text, _):
            HStack {
                Spacer(minLength: 40)
                SelectableText(verbatim: text).padding(12)
                    .glass(in: RoundedRectangle(cornerRadius: 18))
            }
        case let .agent(_, blocks):
            MarkdownView(blocks: blocks)
        case let .thinking(text):
            ThinkingView(text: text)
        case let .activity(steps, summary):
            RowDisclosureGroup(key: "activity") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    switch step {
                    case let .thought(text):
                        ThinkingView(text: text, key: "step-\(index)")
                    case let .tool(call):
                        VStack(alignment: .leading, spacing: 6) {
                            Label { Text(verbatim: toolLabel(call.kind)) }
                                icon: { Image(systemName: call.status == .failed ? "exclamationmark.circle" : "terminal") }
                                .font(.callout).foregroundStyle(call.status == .failed ? Color.red : Color.secondary)
                            if let title = call.title {
                                if call.kind == .execute {
                                    CodeView(code: title, language: nil)
                                } else {
                                    SelectableText(verbatim: title, style: .callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            ForEach(call.locations, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()) }
                            if let output = call.output {
                                RowDisclosureGroup("Output", key: "output-\(index)") { CodeView(code: output, language: nil) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if summary.toolCount == 1 {
                        Text("Activity · 1 tool").font(.callout)
                    } else {
                        Text("Activity · \(summary.toolCount) tools").font(.callout)
                    }
                    if summary.failedCount > 0 { Text("\(summary.failedCount) failed").font(.caption).foregroundStyle(.red) }
                    if summary.live, let title = summary.liveTitle {
                        Text(verbatim: title)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(.primary)
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
                if let detail = notice.detail { RowDisclosureGroup("Details", key: "details") { SelectableText(verbatim: detail, style: .callout).frame(maxWidth: .infinity, alignment: .leading) } }
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

struct UserMessageView: View {
    let text: String
    let attachments: [ChatDocument]
    let core: ChatViewModel
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 10) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(attachments, id: \.fileId) { document in
                                DocumentCard(document: document, documents: attachments, core: core, compactImage: true)
                            }
                        }
                    }
                }
                if !text.isEmpty { SelectableText(verbatim: text) }
            }
            .padding(12)
            .glass(in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

/// One row of the agent conversation.
enum ChatRow: Identifiable, Equatable {
    case message(ChatItem)
    case outbox(OutgoingMessage)
    case request(ChatRequestKey)
    case provisioning(ProvisioningState)

    /// Message ids are the server's; the other rows can't collide with them.
    var id: String {
        switch self {
        case let .message(message): message.id
        case let .outbox(message): "#outbox-\(message.id)"
        case let .request(key): "#request-\(key.session)-\(key.id)"
        case .provisioning: "#provisioning"
        }
    }
}

/// Evaluates a row inside its own body, so a hosted row observes the models
/// it reads (deliveries, request status) and updates itself.
struct ChatRowHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
