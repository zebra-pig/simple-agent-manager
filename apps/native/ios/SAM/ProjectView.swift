import SwiftUI

/// A project's chat sessions, plus the composer that hands a new task (and any
/// attached files) to an agent, with the agent profile picked in it.
struct ProjectView: View {
    let app: App
    let changed: (Project?) -> Void
    let project: Project
    /// The conversation shown beside this list, highlighted in it.
    let selectedSessionId: String?
    let open: (SessionRef) -> Void
    @State private var model: ProjectModel
    @State private var search = ""
    @State private var draft = ""
    @State private var commands: CommandsModel
    @State private var submitting = false
    @State private var settings = false
    @State private var editing: ProfileEditing?

    init(app: App, project: Project, selectedSessionId: String? = nil,
         changed: @escaping (Project?) -> Void, open: @escaping (SessionRef) -> Void) {
        self.app = app
        self.changed = changed
        self.project = project
        self.selectedSessionId = selectedSessionId
        self.open = open
        _model = State(initialValue: ProjectModel(app: app))
        _commands = State(initialValue: CommandsModel(app: app))
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.state.matchingSessions, id: \.id) { session in
                Button {
                    open(SessionRef(projectId: project.id, sessionId: session.id))
                } label: {
                    SessionRow(session: session)
                }
                .buttonStyle(.plain)
                .tag(session.id)
                .accessibilityIdentifier("session-\(session.id)")
            }
        }
        .overlay {
            if !model.state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.state.matchingSessions.isEmpty, model.state.error == nil, !model.state.loading {
                ContentUnavailableView.search
            } else if model.state.sessions.isEmpty && model.state.error == nil {
                ContentUnavailableView("No sessions yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Describe a task below and an agent picks it up."))
            }
        }
        .initialLoading(model.state.loading)
        .searchable(text: $search, prompt: "Search chat titles or IDs")
        .onChange(of: search) { _, query in model.core.searchSessions(query: query) }
        .navigationTitle(project.name)
        .inlineTitle()
        .hidesTabBarWhenPushed()
        .refreshable { await model.core.load(projectId: project.id) }
        .interactiveKeyboardDismiss()
        .task { await model.core.load(projectId: project.id) }
        .task { await commands.core.load(projectId: project.id) }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Describe a task…", text: $draft, busy: submitting || model.state.submitting, files: model.files, commands: commands.state.commands, dismissFocusOnSend: true) {
                guard !submitting && !model.state.submitting else { return }
                submitting = true
                let message = draft
                Task {
                    defer { submitting = false }
                    if let task = await model.core.submitTask(message: message) {
                        draft = ""
                        open(SessionRef(projectId: project.id, sessionId: task.sessionId))
                        model.core.finishSubmission(sessionId: task.sessionId)
                    }
                }
            } accessory: {
                ProfileMenu(model: model) { editing = ProfileEditing(profile: $0) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Project settings", systemImage: "gearshape") { settings = true }
            }
        }
        .sheet(isPresented: $settings) { ProjectSettings(app: app, projectId: project.id, saved: changed) }
        .sheet(item: $editing) { ProfileEditor(model: model, profile: $0.profile) }
        .floatingErrors([model.state.error?.message])
    }

    /// Highlights the open conversation; keyboard selection opens one too.
    /// A collapsed split view clears selection when popping back; that keeps the chat.
    private var selection: Binding<String?> {
        Binding(get: { selectedSessionId }) { id in
            if let id, id != selectedSessionId { open(SessionRef(projectId: project.id, sessionId: id)) }
        }
    }
}

struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(session: session).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.topic ?? "Untitled session")
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(statusLabel(session))
                    Text(verbatim: "·")
                    Text(Date(millis: session.lastMessageAt ?? session.startedAt), style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The floating input island: a Liquid Glass container with the attach
/// button, the text field and a round send button, over the content (which
/// scrolls beneath it). Attached files show above the text field; files
/// dropped on the island are attached too. The project profile selector stays
/// beside the attachment button, below the input, regardless of keyboard focus.
struct Composer<Accessory: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let busy: Bool
    let files: ComposerFiles?
    var commands: [SlashCommand] = []
    var inputEnabled = true
    var sendEnabled = true
    var allowsEmpty = false
    var sendLabel: LocalizedStringKey = "Send"
    var sendIcon = "arrow.up"
    let dismissFocusOnSend: Bool
    let send: () -> Void
    let accessory: Accessory
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22
    @State private var dropTargeted = false
    @State private var dismissedCommandDraft: String?
    @State private var selectedCommand: String?
    #if os(iOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif

    init(placeholder: LocalizedStringKey, text: Binding<String>, busy: Bool, files: ComposerFiles?, commands: [SlashCommand] = [],
         dismissFocusOnSend: Bool = false, send: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        self.placeholder = placeholder
        _text = text
        self.busy = busy
        self.files = files
        self.commands = commands
        self.dismissFocusOnSend = dismissFocusOnSend
        self.send = send
        self.accessory = accessory()
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Text or files to send, and every file uploaded.
    private var canSend: Bool { sendEnabled && (allowsEmpty || !empty || !(files?.items.isEmpty ?? true)) && (files?.ready ?? true) }

    var body: some View {
        GlassGroup {
            VStack(spacing: 8) {
                if showsCommands {
                    SlashCommandPicker(commands: matchingCommands, selected: selectedCommand,
                                       select: insertCommand, dismiss: dismissCommands)
                }
                composerIsland
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: text) { _, _ in
            dismissedCommandDraft = nil
            selectedCommand = matchingCommands.first?.name
        }
        .onChange(of: commands) { _, _ in selectedCommand = matchingCommands.first?.name }
        .onKeyPress(.escape) {
            guard showsCommands else { return .ignored }
            dismissCommands()
            return .handled
        }
        .onKeyPress(.downArrow) { moveCommand(1) }
        .onKeyPress(.upArrow) { moveCommand(-1) }
        .onKeyPress(.tab) {
            guard showsCommands, let command = activeCommand else { return .ignored }
            insertCommand(command)
            return .handled
        }
        .onKeyPress(.return) {
            guard showsCommands, let command = activeCommand else { return .ignored }
            insertCommand(command)
            return .handled
        }
    }

    private var composerIsland: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let files, !files.items.isEmpty {
                AttachmentStrip(files: files)
            }
            if Accessory.self == EmptyView.self {
                ComposerInputLayout(lineHeight: lineHeight) {
                    composerInput
                    attachmentControl.frame(width: 44, height: 44)
                    sendControl.frame(width: 44, height: 44)
                }
            } else {
                composerInput
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                HStack(alignment: .bottom, spacing: 8) {
                    attachmentControl.frame(width: 44, height: 44)
                    accessory.padding(.vertical, 4)
                    Spacer(minLength: 0)
                    sendControl.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: true)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.item], delegate: AttachmentDrop(files: files, targeted: $dropTargeted))
    }

    private var matchingCommands: [SlashCommand] {
        guard let query = SlashCommandQuery(draft: text) else { return [] }
        return query.matches(commands)
    }

    private var showsCommands: Bool {
        focused && inputEnabled && !busy && dismissedCommandDraft != text && !matchingCommands.isEmpty
    }

    private var activeCommand: SlashCommand? {
        matchingCommands.first { $0.name == selectedCommand } ?? matchingCommands.first
    }

    private func commandKey(_ action: String) -> Bool {
        guard showsCommands else { return false }
        switch action {
        case "next": _ = moveCommand(1)
        case "previous": _ = moveCommand(-1)
        case "dismiss": dismissCommands()
        default: if let command = activeCommand { insertCommand(command) }
        }
        return true
    }

    private func insertCommand(_ command: SlashCommand) {
        text = "/" + command.name + " "
        focused = true
    }

    private func dismissCommands() { dismissedCommandDraft = text }

    private func moveCommand(_ offset: Int) -> KeyPress.Result {
        guard showsCommands else { return .ignored }
        let items = matchingCommands
        let current = items.firstIndex { $0.name == selectedCommand } ?? 0
        selectedCommand = items[(current + offset + items.count) % items.count].name
        return .handled
    }

    @ViewBuilder
    private var sendControl: some View {
        if busy {
            ProgressView().frame(width: 36, height: 36)
        } else {
            Button {
                if dismissFocusOnSend { focused = false }
                send()
            } label: {
                Image(systemName: sendIcon).font(.body.weight(.semibold)).frame(width: 22, height: 22)
            }
            .glassButton()
            .tint(.primary)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text(sendLabel))
        }
    }

    private var attachmentControl: some View {
        // Layout requires a stable control slot even when SAM has no attachments.
        // A conditional EmptyView is omitted from Layout.Subviews entirely.
        ZStack {
            Color.clear
            if let files { AttachButton(files: files) }
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        #if os(iOS)
        ComposerTextInput(text: $text, focused: Binding(get: { focused }, set: { focused = $0 }),
                          files: files, commandKey: showsCommands ? commandKey : nil)
            .disabled(!inputEnabled || (dismissFocusOnSend && busy))
            .accessibilityLabel(Text(placeholder))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
        #else
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .disabled(!inputEnabled || (dismissFocusOnSend && busy))
            .textFieldStyle(.plain)
            .submitLabel(.send)
            .focused($focused)
            .onPasteCommand(of: [.fileURL, .image, .pdf, .archive, .audiovisualContent]) { providers in
                if let files { AttachmentIntake.add(providers: providers, to: files) }
            }
        #endif
    }

}

extension Composer where Accessory == EmptyView {
    init(placeholder: LocalizedStringKey, text: Binding<String>, busy: Bool, files: ComposerFiles?, commands: [SlashCommand] = [],
         send: @escaping () -> Void) {
        self.init(placeholder: placeholder, text: text, busy: busy, files: files, commands: commands, send: send) { EmptyView() }
    }
}

extension ProjectModel {
    var files: ComposerFiles {
        ComposerFiles(
            items: state.attachments,
            add: { [core] name, type, size, source in
                Task { await core.addAttachment(filename: name, contentType: type, size: size, source: source) }
            },
            remove: { [core] id in core.removeAttachment(id: id) }
        )
    }
}

extension ChatModel {
    var files: ComposerFiles {
        ComposerFiles(
            items: state.attachments,
            add: { [core] name, type, size, source in
                Task { await core.addAttachment(filename: name, contentType: type, size: size, source: source) }
            },
            remove: { [core] id in core.removeAttachment(id: id) }
        )
    }
}
