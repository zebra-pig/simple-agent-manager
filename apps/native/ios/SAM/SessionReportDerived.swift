import SwiftUI

/// Retry or Fork: a new task in the same project with this chat's task as its
/// parent. Like web, the composer is prefilled (the original prompt, or the
/// fork briefing) and nothing is sent until the user presses Send.
struct DerivedTaskView: View {
    let kind: DerivedKind
    let ref: SessionRef
    let session: ChatSession
    let open: (SessionRef) -> Void
    @State private var model: ProjectModel
    @State private var commands: CommandsModel
    @State private var draft = ""
    @State private var submitting = false
    @State private var editing: ProfileEditing?
    @Environment(\.dismiss) private var dismiss

    init(app: App, kind: DerivedKind, ref: SessionRef, session: ChatSession, open: @escaping (SessionRef) -> Void) {
        self.kind = kind
        self.ref = ref
        self.session = session
        self.open = open
        _model = State(initialValue: ProjectModel(app: app))
        _commands = State(initialValue: CommandsModel(app: app))
    }

    private var derived: DerivedTask? { model.state.derived }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(verbatim: kind == .retry
                             ? String(localized: "Retrying: \(derived?.parentLabel ?? "")")
                             : String(localized: "Forking from: \(derived?.parentLabel ?? "")"))
                            .font(.headline)
                    } icon: {
                        Image(systemName: kind == .retry ? "arrow.clockwise" : "arrow.triangle.branch")
                            .foregroundStyle(kind == .retry ? Color.orange : Color.secondary)
                    }
                    if let branch = derived?.parentBranch {
                        Text("Branch: \(branch)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let error = derived?.errorMessage {
                        Text("Error: \(error)").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    if derived?.promptLoading == true {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading original prompt…") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(kind == .retry
                         ? "Starts a new chat that re-runs this task. Edit the prompt below if needed, then send."
                         : "Starts a new chat that continues from this one. The agent reads this chat for context.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: RoundedRectangle(cornerRadius: 20))
                .padding()
            }
            .navigationTitle(kind == .retry ? "Retry" : "Fork")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.core.cancelDerived(); dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(placeholder: kind == .retry ? "Describe the task to retry…" : "Describe what to do next…",
                         text: $draft, busy: submitting || model.state.submitting || derived?.promptLoading == true,
                         files: model.files, commands: commands.state.commands, dismissFocusOnSend: true) {
                    guard !submitting && !model.state.submitting else { return }
                    submitting = true
                    let message = draft
                    Task {
                        defer { submitting = false }
                        if let task = await model.core.submitTask(message: message) {
                            draft = ""
                            dismiss()
                            open(SessionRef(projectId: ref.projectId, sessionId: task.sessionId))
                            model.core.finishSubmission(sessionId: task.sessionId)
                        }
                    }
                } accessory: {
                    ProfileMenu(model: model) { editing = ProfileEditing(profile: $0) }
                }
            }
            .sheet(item: $editing) { ProfileEditor(model: model, profile: $0.profile) }
            .task {
                await model.core.load(projectId: ref.projectId)
                await commands.core.load(projectId: ref.projectId)
                let prefill = await model.core.derive(kind: kind, session: session)
                if draft.isEmpty { draft = prefill }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .floatingErrors([model.state.error?.message,
                         model.state.derived?.promptError.map { _ in String(localized: "Could not load the original prompt. Type it below to retry.") }])
    }
}

/// "Report an issue" for this chat, reviewed by the platform team.
struct ReportIssueView: View {
    let refs: ReportRefs
    @State private var model: ReportModel
    @State private var title = ""
    @State private var details = ""
    @State private var attachRefs = false
    @Environment(\.dismiss) private var dismiss

    init(app: App, refs: ReportRefs) {
        self.refs = refs
        _model = State(initialValue: ReportModel(app: app))
    }

    private var present: [String] { reportRefsPresent(refs: refs) }
    private var valid: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !d.isEmpty && t.count <= 200 && d.count <= 5000
    }

    var body: some View {
        NavigationStack {
            Form {
                if let done = model.state.submitted {
                    Section {
                        Label("Report submitted", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                        if !done.message.isEmpty { Text(verbatim: done.message) }
                        LabeledContent("Report ID", value: done.id).textSelection(.enabled)
                        LabeledContent("Status", value: humanized(done.status))
                        if !done.attached.isEmpty {
                            LabeledContent("Refs attached", value: done.attached.map(refLabel).joined(separator: ", "))
                        }
                    }
                } else {
                    Section {
                        TextField("Brief summary of the issue", text: $title)
                        TextField("What happened? What did you expect?", text: $details, axis: .vertical).lineLimit(4...12)
                    } footer: { Text("Describe what went wrong. Your report will be reviewed by the platform team.") }
                    if !present.isEmpty {
                        Section {
                            Toggle("Attach technical references to help diagnose this issue", isOn: $attachRefs)
                            if attachRefs {
                                ForEach(present, id: \.self) { key in
                                    LabeledContent(refLabel(key)) { Text(verbatim: refValue(key)).font(.caption.monospaced()).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Report an issue")
            .inlineTitle()
            .toolbar {
                if model.state.submitted != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { _ = await model.core.submit(title: title, description: details, attachRefs: attachRefs, refs: refs) } } label: {
                            LoadingLabel(title: "Submit", loading: model.state.submitting)
                        }.disabled(!valid || model.state.submitting)
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .floatingErrors([model.state.error?.message])
    }

    private func refLabel(_ key: String) -> String {
        switch key {
        case "sessionId": String(localized: "Chat session")
        case "taskId": String(localized: "Task")
        case "nodeId": String(localized: "Node")
        case "errorId": String(localized: "Error")
        case "diagnosisId": String(localized: "Diagnosis")
        default: key
        }
    }
    private func refValue(_ key: String) -> String {
        switch key {
        case "sessionId": refs.sessionId ?? ""
        case "taskId": refs.taskId ?? ""
        case "nodeId": refs.nodeId ?? ""
        default: ""
        }
    }
}
