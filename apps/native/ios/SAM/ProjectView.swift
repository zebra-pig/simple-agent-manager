import SwiftUI

/// A project's chat sessions, plus the composer that hands a new task (and any
/// attached files) to an agent, with the agent profile picked in it.
struct ProjectView: View {
    let project: Project
    let open: (SessionRef) -> Void
    @State private var model: ProjectModel
    @State private var draft = ""
    @State private var editing: ProfileEditing?

    init(app: App, project: Project, open: @escaping (SessionRef) -> Void) {
        self.project = project
        self.open = open
        _model = State(initialValue: ProjectModel(app: app))
    }

    var body: some View {
        List {
            if let error = model.state.error {
                Text(error.message).foregroundStyle(.red)
            }
            ForEach(model.state.sessions, id: \.id) { session in
                Button {
                    open(SessionRef(projectId: project.id, sessionId: session.id))
                } label: {
                    SessionRow(session: session)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if model.state.sessions.isEmpty && model.state.loading {
                ProgressView()
            } else if model.state.sessions.isEmpty && model.state.error == nil {
                ContentUnavailableView("No sessions yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Describe a task below and an agent picks it up."))
            }
        }
        .navigationTitle(project.name)
        .inlineTitle()
        .refreshable { await model.core.load(projectId: project.id) }
        .interactiveKeyboardDismiss()
        .task { await model.core.load(projectId: project.id) }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Describe a task…", text: $draft, busy: model.state.submitting, files: model.files) {
                let message = draft
                Task {
                    if let task = await model.core.submitTask(message: message) {
                        draft = ""
                        open(SessionRef(projectId: project.id, sessionId: task.sessionId))
                    }
                }
            } accessory: {
                ProfileMenu(model: model) { editing = ProfileEditing(profile: $0) }
            }
        }
        .sheet(item: $editing) { ProfileEditor(model: model, profile: $0.profile) }
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
/// dropped on the island are attached too. `accessory` (the project screen's
/// profile selector) sits at the top of the same container, only while the
/// text field has focus (keyboard open).
struct Composer<Accessory: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let busy: Bool
    let files: ComposerFiles
    let send: () -> Void
    let accessory: Accessory
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    /// Follows `focused`, but hides a moment later, so tapping the accessory
    /// (which may briefly take focus) doesn't make it vanish under the finger.
    @State private var showsAccessory = false

    init(placeholder: LocalizedStringKey, text: Binding<String>, busy: Bool, files: ComposerFiles,
         send: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        self.placeholder = placeholder
        _text = text
        self.busy = busy
        self.files = files
        self.send = send
        self.accessory = accessory()
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Text or files to send, and every file uploaded.
    private var canSend: Bool { (!empty || !files.items.isEmpty) && files.ready }

    var body: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 0) {
                if showsAccessory && Accessory.self != EmptyView.self {
                    accessory
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !files.items.isEmpty {
                    AttachmentStrip(files: files)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    AttachButton(files: files)
                        .padding([.leading, .vertical], 4)
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 10)
                        .submitLabel(.send)
                        .focused($focused)
                    Group {
                        if busy {
                            ProgressView().frame(width: 36, height: 36)
                        } else {
                            Button(action: send) {
                                Image(systemName: "arrow.up")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 22, height: 22)
                            }
                            .glassButton()
                            .tint(.primary)
                            .buttonBorderShape(.circle)
                            .disabled(!canSend)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel(Text("Send"))
                        }
                    }
                    .padding(4)
                }
            }
            .animation(.snappy(duration: 0.25), value: showsAccessory)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    showsAccessory = true
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if !focused { showsAccessory = false }
                    }
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.item], delegate: AttachmentDrop(files: files, targeted: $dropTargeted))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

extension Composer where Accessory == EmptyView {
    init(placeholder: LocalizedStringKey, text: Binding<String>, busy: Bool, files: ComposerFiles,
         send: @escaping () -> Void) {
        self.init(placeholder: placeholder, text: text, busy: busy, files: files, send: send) { EmptyView() }
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
