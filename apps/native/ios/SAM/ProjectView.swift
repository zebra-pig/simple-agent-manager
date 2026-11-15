import SwiftUI

/// A project's chat sessions, plus the composer that hands a new task (and any
/// attached files) to an agent, with the agent profile picked in it.
struct ProjectView: View {
    let app: App
    let changed: (Project?) -> Void
    let project: Project
    let open: (SessionRef) -> Void
    @State private var model: ProjectModel
    @State private var draft = ""
    @State private var settings = false
    @State private var editing: ProfileEditing?

    init(app: App, project: Project, changed: @escaping (Project?) -> Void, open: @escaping (SessionRef) -> Void) {
        self.app = app
        self.changed = changed
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
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Project settings", systemImage: "gearshape") { settings = true }
            }
        }
        .sheet(isPresented: $settings) { ProjectSettings(app: app, projectId: project.id, saved: changed) }
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
/// dropped on the island are attached too. The project profile selector stays
/// beside the attachment button, below the input, regardless of keyboard focus.
struct Composer<Accessory: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let busy: Bool
    let files: ComposerFiles
    let send: () -> Void
    let accessory: Accessory
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

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
                if !files.items.isEmpty {
                    AttachmentStrip(files: files)
                }
                if Accessory.self == EmptyView.self {
                    ComposerInputLayout(lineHeight: lineHeight) {
                        composerInput
                        AttachButton(files: files).frame(width: 44, height: 44)
                        sendControl.frame(width: 44, height: 44)
                    }
                } else {
                    composerInput
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    HStack(alignment: .bottom, spacing: 8) {
                        AttachButton(files: files).frame(width: 44, height: 44)
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
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sendControl: some View {
        if busy {
            ProgressView().frame(width: 36, height: 36)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 22, height: 22)
            }
            .glassButton()
            .tint(.primary)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text("Send"))
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        #if os(iOS)
        ComposerTextInput(text: $text, focused: Binding(get: { focused }, set: { focused = $0 }),
                          files: files)
            .accessibilityLabel(Text(placeholder))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
        #else
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .submitLabel(.send)
            .focused($focused)
            .onPasteCommand(of: [.fileURL, .image, .pdf, .archive, .audiovisualContent]) { providers in
                AttachmentIntake.add(providers: providers, to: files)
            }
        #endif
    }

}

/// Keeps the editor's identity and keyboard focus while its controls move below a wrapped draft.
private struct ComposerInputLayout: Layout {
    var lineHeight: CGFloat

    private func metrics(width: CGFloat, subviews: Subviews) -> (expanded: Bool, field: CGSize, height: CGFloat) {
        let collapsed = subviews[0].sizeThatFits(ProposedViewSize(width: max(1, width - 112), height: nil))
        let expanded = collapsed.height > lineHeight * 1.5
        let field = expanded ? subviews[0].sizeThatFits(ProposedViewSize(width: max(1, width - 32), height: nil)) : collapsed
        return (expanded, field, expanded ? 16 + field.height + 8 + 44 + 8 : max(56, field.height + 16))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX + (m.expanded ? 16 : 56), y: bounds.minY + (m.expanded ? 16 : (bounds.height - m.field.height) / 2)), proposal: ProposedViewSize(width: max(1, bounds.width - (m.expanded ? 32 : 112)), height: m.field.height))
        let y = bounds.minY + (m.expanded ? bounds.height - 52 : (bounds.height - 44) / 2)
        subviews[1].place(at: CGPoint(x: bounds.minX + 8, y: y), proposal: ProposedViewSize(width: 44, height: 44))
        subviews[2].place(at: CGPoint(x: bounds.maxX - 52, y: y), proposal: ProposedViewSize(width: 44, height: 44))
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
