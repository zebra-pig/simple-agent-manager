import SwiftUI

/// A project's chat sessions, plus the composer that hands a new task to an agent.
struct ProjectView: View {
    let project: Project
    let open: (SessionRef) -> Void
    @State private var model: ProjectModel
    @State private var draft = ""

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
        .task { await model.core.load(projectId: project.id) }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Describe a task…", text: $draft, busy: model.state.submitting) {
                let message = draft
                Task {
                    if let task = await model.core.submitTask(message: message) {
                        draft = ""
                        open(SessionRef(projectId: project.id, sessionId: task.sessionId))
                    }
                }
            }
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

/// The floating input island: a Liquid Glass capsule with the text field and a
/// round send button, over the content (which scrolls beneath it).
struct Composer: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let busy: Bool
    let send: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .padding(.leading, 16)
                    .submitLabel(.send)
                Group {
                    if busy {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(width: 22, height: 22)
                        }
                        .glassProminentButton()
                        .buttonBorderShape(.circle)
                        .disabled(empty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel(Text("Send"))
                    }
                }
                .padding(4)
            }
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
