import SwiftUI

/// Done and Refresh around a session tool's list, like the other chat tools.
struct SessionToolSheet<Content: View>: View {
    let title: LocalizedStringKey
    let loading: Bool
    let errors: [String?]
    let refresh: () async -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await refresh() } } label: {
                            LoadingLabel(title: "Refresh", systemImage: "arrow.clockwise", loading: loading)
                        }.disabled(loading)
                    }
                }
                .task { await refresh() }
        }
        .frame(minWidth: 320, minHeight: 440)
        .floatingErrors(errors)
    }
}

/// A rounded count or state label next to a title.
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(verbatim: text).font(.caption.weight(.medium)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

func relativeTime(_ millis: Int64) -> String {
    Date(millis: millis).formatted(.relative(presentation: .named))
}

/// The web app's address for project pages ("https://app…/projects/…").
func webProjectUrl(_ chat: ChatViewModel, _ path: String) -> URL? {
    let chatUrl = chat.webUrl()
    guard let range = chatUrl.range(of: "/chat/") else { return nil }
    return URL(string: String(chatUrl[..<range.lowerBound]) + path)
}

// MARK: - Related

struct RelatedWorkView: View {
    let ref: SessionRef
    let chat: ChatViewModel
    @State private var model: LinkedWorkModel
    @Environment(\.openURL) private var openURL

    init(app: App, ref: SessionRef, chat: ChatViewModel) {
        self.ref = ref
        self.chat = chat
        _model = State(initialValue: LinkedWorkModel(app: app))
    }

    var body: some View {
        SessionToolSheet(title: "Related", loading: model.state.loading, errors: [model.state.error?.message]) {
            await model.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
        } content: {
            List {
                if let work = model.state.work {
                    if !work.ideas.isEmpty {
                        Section { ForEach(work.ideas, id: \.id) { idea in
                            Button {
                                if let url = webProjectUrl(chat, "/ideas/\(idea.id)") { openURL(url) }
                            } label: {
                                RelatedRow(icon: "lightbulb", title: idea.title, detail: relationText(idea.relations))
                            }.buttonStyle(.plain)
                        } } header: { SectionCount(title: "Ideas", total: work.ideasTotal) }
                    }
                    if !work.files.isEmpty {
                        Section { ForEach(work.files, id: \.id) { file in
                            LibraryFileRow(file: file, chat: chat)
                        } } header: { SectionCount(title: "Files", total: work.filesTotal) }
                    }
                    if !work.pullRequests.isEmpty {
                        Section { ForEach(work.pullRequests, id: \.url) { pr in
                            Button { if let url = URL(string: pr.url) { openURL(url) } } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    RelatedRow(icon: "arrow.triangle.pull", title: pr.title ?? String(localized: "Pull request #\(pr.number)"),
                                               detail: "#\(pr.number)" + (pr.checks.map { " · " + checksLabel($0) } ?? ""))
                                    if let status = pr.status { Pill(text: pullRequestLabel(status), tint: pullRequestTint(status)) }
                                }
                            }.buttonStyle(.plain)
                            .accessibilityHint(pr.stale ? Text("May be out of date") : Text(""))
                        } } header: { SectionCount(title: "Pull requests", total: work.pullRequestsTotal) }
                    }
                }
            }
            .overlay {
                if let work = model.state.work, work.ideas.isEmpty, work.files.isEmpty, work.pullRequests.isEmpty {
                    ContentUnavailableView("Nothing related yet", systemImage: "link",
                        description: Text("SAM keeps track of the ideas this chat works on, the library files it adds or reads, and the pull requests it opens."))
                } else if model.state.work == nil, model.state.error != nil {
                    ContentUnavailableView("Couldn't load related work", systemImage: "exclamationmark.triangle",
                        description: Text("The rest of the chat is unaffected. Try again in a moment."))
                }
            }
            .initialLoading(model.state.loading && model.state.work == nil)
        }
    }
}

private struct SectionCount: View {
    let title: LocalizedStringKey
    let total: LinkedTotal
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(verbatim: "\(total.count)\(total.lowerBound ? "+" : "")").foregroundStyle(.secondary)
        }
        .accessibilityHint(total.truncated ? Text("Showing the most recent only") : Text(""))
    }
}

private struct RelatedRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).lineLimit(2)
                if !detail.isEmpty { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }
}

/// Opens a library file in Quick Look, like a file shared in the chat.
private struct LibraryFileRow: View {
    let file: LinkedFile
    let chat: ChatViewModel
    @State private var preview: URL?
    @State private var folder: URL?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button { Task { await open() } } label: {
            HStack {
                RelatedRow(icon: "doc.text", title: file.filename,
                           detail: [relationText(file.relations), file.directory].filter { !$0.isEmpty }.joined(separator: " · "))
                if loading { ProgressView().controlSize(.small) }
                else if failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("File unavailable") }
            }
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .quickLookPreview($preview)
        .onChange(of: preview) { if preview == nil { cleanUp() } }
        .onDisappear { cleanUp() }
    }

    private func cleanUp() { if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil }
    @MainActor private func open() async {
        loading = true; failed = false
        defer { loading = false }
        guard let bytes = await chat.documentBytes(fileId: file.id) else { failed = true; return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = (file.filename as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name == "." || name == ".." || name.isEmpty ? "File" : name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: url)
            cleanUp(); folder = dir; preview = url
        } catch { try? FileManager.default.removeItem(at: dir); failed = true }
    }
}

func relationText(_ relations: [LinkRelation]) -> String {
    relations.map { relation in
        switch relation {
        case .worksOn: String(localized: "Working on")
        case .created: String(localized: "Created")
        case .edited: String(localized: "Edited")
        case .opened: String(localized: "Opened")
        case .uploaded: String(localized: "Uploaded")
        case .replaced: String(localized: "Replaced")
        case .linked: String(localized: "Linked")
        case .related: String(localized: "Related")
        case .discusses: String(localized: "Discussed")
        case .read: String(localized: "Read")
        case .viewed: String(localized: "Viewed")
        }
    }.joined(separator: " · ")
}

func pullRequestLabel(_ status: PullRequestStatus) -> String {
    switch status {
    case .open: String(localized: "Open")
    case .draft: String(localized: "Draft")
    case .merged: String(localized: "Merged")
    case .closed: String(localized: "Closed")
    }
}
private func pullRequestTint(_ status: PullRequestStatus) -> Color {
    switch status {
    case .open: .green
    case .draft, .closed: .secondary
    case .merged: .purple
    }
}
private func checksLabel(_ checks: ChecksStatus) -> String {
    switch checks {
    case .pending: String(localized: "Checks running")
    case .passed: String(localized: "Checks passed")
    case .failing: String(localized: "Checks failing")
    }
}

// MARK: - Automation

struct AutomationView: View {
    let ref: SessionRef
    @State private var model: AutomationModel
    @State private var showRelays = false
    @State private var stopping: ChatWait?
    @State private var stopReason = ""
    @State private var reminding = false

    init(app: App, ref: SessionRef) {
        self.ref = ref
        _model = State(initialValue: AutomationModel(app: app))
    }

    private var state: AutomationState { model.state }

    var body: some View {
        SessionToolSheet(title: "Automation", loading: state.loading,
                         errors: [state.error?.message, state.waitsError?.message, state.upcomingError?.message]) {
            await model.core.load(projectId: ref.projectId, sessionId: ref.sessionId)
        } content: {
            List {
                if state.canWrite {
                    Section {
                        Button { reminding = true } label: { Label("Remind this chat later", systemImage: "alarm") }.tint(.primary)
                    }
                }
                Section {
                    let waits = state.waits + (showRelays ? state.relays : [])
                    if state.loaded && waits.isEmpty && state.waitsError == nil {
                        Text("This chat is not waiting for anything.").foregroundStyle(.secondary)
                    }
                    ForEach(waits, id: \.id) { wait in
                        WaitRow(wait: wait, sessionId: ref.sessionId)
                            .swipeActions {
                                if wait.canStop {
                                    Button("Stop waiting", role: .destructive) { stopReason = ""; stopping = wait }
                                }
                            }
                            .contextMenu {
                                if wait.canStop {
                                    Button("Stop waiting", systemImage: "stop.circle", role: .destructive) { stopReason = ""; stopping = wait }
                                }
                            }
                    }
                    if !state.relays.isEmpty {
                        Toggle("Show SAM's own message relays (\(state.relays.count))", isOn: $showRelays)
                    }
                } header: {
                    Text("Waiting for")
                } footer: {
                    Text("Things an agent here asked to hear about.")
                }
                Section {
                    if state.loaded && state.upcoming.isEmpty && state.upcomingError == nil {
                        Text("Nothing is set to message this chat.").foregroundStyle(.secondary)
                    }
                    ForEach(state.upcoming, id: \.id) { UpcomingRow(row: $0) }
                } header: {
                    Text("Coming up for this chat")
                } footer: {
                    if state.upcomingTruncated { Text("Only the first automations are shown.") }
                }
            }
            .initialLoading(state.loading && !state.loaded)
            .alert("Stop waiting?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
                TextField("Why (optional)", text: $stopReason)
                Button("Keep waiting", role: .cancel) { stopping = nil }
                Button("Stop waiting", role: .destructive) {
                    guard let wait = stopping else { return }
                    let reason = stopReason
                    stopping = nil
                    Task { _ = await model.core.stopWaiting(subscriptionId: wait.id, reason: reason) }
                }
            } message: {
                if let wait = stopping { Text(verbatim: waitTitle(wait, sessionId: ref.sessionId)) }
            }
            .sheet(isPresented: $reminding) { ReminderForm(model: model) }
        }
    }
}

private struct WaitRow: View {
    let wait: ChatWait
    let sessionId: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: waitTitle(wait, sessionId: sessionId))
            Text(verbatim: waitSubtitle(wait)).font(.caption).foregroundStyle(.secondary)
            if wait.owner == .managed {
                Text("Managed by SAM, so it cannot be stopped here.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }
}

private func waitTitle(_ wait: ChatWait, sessionId: String) -> String {
    let what = eventNoun(wait.event, subject: wait.subject)
    if wait.targetSessionId == nil || wait.targetSessionId == sessionId {
        return String(localized: "This chat is waiting for \(what)")
    }
    let who = wait.ownerName ?? (wait.owner == .agent ? String(localized: "An agent") : String(localized: "Someone"))
    return String(localized: "\(who) is waiting for \(what)")
}

private func waitSubtitle(_ wait: ChatWait) -> String {
    var parts = [String(localized: "Since \(relativeTime(wait.createdAt))")]
    if let expires = wait.expiresAt {
        parts.append(expires > Int64(Date().timeIntervalSince1970 * 1000)
            ? String(localized: "gives up \(relativeTime(expires))") : String(localized: "past its end time"))
    }
    if let matched = wait.lastMatchedAt { parts.append(String(localized: "last matched \(relativeTime(matched))")) }
    return parts.joined(separator: " · ")
}

private struct UpcomingRow: View {
    let row: UpcomingAutomation
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: row.kind == .schedule ? "alarm" : "eye").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: upcomingTitle(row)).lineLimit(2)
                if let due = row.dueAt {
                    Text(Date(millis: due), format: .dateTime.weekday().day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                } else if let max = row.maxExecutions {
                    Text("\(row.executions) of \(max) runs used").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let pill = upcomingPill(row) { Pill(text: pill.0, tint: pill.1) }
        }
        .opacity(row.status == .cancelled || row.status == .ended ? 0.6 : 1)
    }
}

private func upcomingTitle(_ row: UpcomingAutomation) -> String {
    if let title = row.title { return title }
    if row.kind == .watch, let event = row.event { return String(localized: "When \(eventClause(event, subject: row.subject))") }
    return row.messagesThisChat ? String(localized: "Message a chat") : String(localized: "Start a chat")
}

private func upcomingPill(_ row: UpcomingAutomation) -> (String, Color)? {
    switch row.status {
    case .scheduled, .on, .done, .ended: return row.needsAttention ? (String(localized: "Check"), .orange) : nil
    case .late: return (String(localized: "Waiting to start"), .orange)
    case .starting: return (String(localized: "Starting"), .blue)
    case .cancelled: return (String(localized: "Cancelled"), .secondary)
    case .paused: return row.needsAttention ? (String(localized: "Check"), .orange) : (String(localized: "Paused"), .secondary)
    }
}

/// "Remind this chat later": one message to this chat at a chosen time.
private struct ReminderForm: View {
    let model: AutomationModel
    @State private var prompt = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var key = UUID().uuidString
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                } footer: { Text("Sent to this chat as a message at the chosen time.") }
                Section {
                    DatePicker("When", selection: $due, in: Date().addingTimeInterval(60)...)
                }
            }
            .navigationTitle("Remind this chat")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task {
                        if await model.core.remindLater(prompt: prompt, dueAt: Int64(due.timeIntervalSince1970 * 1000),
                                                        timezone: TimeZone.current.identifier, idempotencyKey: key) { dismiss() }
                    } } label: { LoadingLabel(title: "Save", loading: model.state.busy) }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.state.busy)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 320)
        .floatingErrors([model.state.error?.message])
    }
}

// MARK: - Event words (web's describeEventFilter)

private let eventPhrases: [String: (noun: String.LocalizationValue, clause: String.LocalizationValue)] = [
    "issues.opened": ("a new issue", "an issue is opened"),
    "issues.labeled": ("an issue label", "an issue is labeled"),
    "issues.closed": ("an issue closing", "an issue is closed"),
    "issue_comment.created": ("a new comment", "someone comments on an issue or PR"),
    "pull_request.opened": ("a new pull request", "a pull request is opened"),
    "pull_request.closed": ("a pull request closing", "a pull request is closed"),
    "pull_request.synchronize": ("new commits on a PR", "a PR gets new commits"),
    "pull_request.review_requested": ("a review request", "someone requests a PR review"),
    "pull_request_review.submitted": ("a PR review", "a PR review is submitted"),
    "pull_request_review_comment.created": ("a review comment", "someone leaves a review comment"),
    "push": ("a push", "code is pushed"),
    "check_run.completed": ("CI to finish", "CI finishes"),
    "check_suite.completed": ("CI to finish", "CI finishes"),
    "workflow_run.completed": ("a workflow run to finish", "a workflow run finishes"),
    "task.started": ("a task to start", "a task starts"),
    "task.completed": ("a task to finish", "a task finishes"),
    "task.failed": ("a failed task", "a task fails"),
    "task.cancelled": ("a cancelled task", "a task is cancelled"),
    "session.failed": ("a failed chat", "a chat fails"),
    "session.archived": ("a chat to be archived", "a chat is archived"),
    "deployment.release.applied": ("a release going live", "a release goes live"),
    "deployment.release.failed": ("a failed release", "a release fails"),
    "webhook.accepted": ("a webhook call", "a webhook call is accepted"),
    "webhook.filtered": ("an ignored webhook call", "a webhook call is ignored by its filters"),
]

private func shortId(_ id: String, _ length: Int = 7) -> String { String(id.prefix(length)) }

private func subjectSuffix(_ subject: WaitSubject?) -> String {
    guard let subject else { return "" }
    switch subject.kind {
    case "commit": return String(localized: " on commit \(shortId(subject.id))")
    case "pull_request": return String(localized: " on PR #\(subject.id)")
    case "issue": return String(localized: " on issue #\(subject.id)")
    case "task": return String(localized: " for task \(shortId(subject.id, 8))")
    case "session": return String(localized: " for chat \(shortId(subject.id, 8))")
    default: return " " + subject.kind.replacingOccurrences(of: "_", with: " ") + " " + shortId(subject.id, 12)
    }
}

private func orList(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.first ?? "" }
    return String(localized: "\(items.dropLast().joined(separator: ", ")) or \(last)")
}

private func eventWords(_ event: WaitEvent, subject: WaitSubject?) -> (noun: String, clause: String) {
    let suffix = subjectSuffix(subject)
    switch event {
    case let .channel(names):
        let where_ = names.isEmpty ? String(localized: "any channel") : orList(names.map { "#\($0)" })
        return (String(localized: "a post on \(where_)"), String(localized: "someone posts on \(where_)"))
    case .ci:
        return (String(localized: "CI to finish") + suffix, String(localized: "CI finishes") + suffix)
    case let .known(type):
        guard let phrase = eventPhrases[type] else { return eventWords(.named(source: nil, eventType: type), subject: subject) }
        return (String(localized: phrase.noun) + suffix, String(localized: phrase.clause) + suffix)
    case let .named(source, type):
        let words = type.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let family = source == "github" ? "GitHub " : source == "sam.lifecycle" ? "SAM " : source.map { "\($0) " } ?? ""
        let noun = String(localized: "a \(family)“\(words)” event")
        return (noun + suffix, String(localized: "\(noun) arrives") + suffix)
    case let .family(source):
        let family = source == "github" ? String(localized: "GitHub activity") : source == "sam.lifecycle" ? String(localized: "SAM activity") : nil
        if !suffix.isEmpty { let f = family ?? String(localized: "an event"); return (f + suffix, String(localized: "there is \(f)") + suffix) }
        return (family.map { String(localized: "matching \($0)") } ?? String(localized: "matching events"), String(localized: "a matching event arrives"))
    }
}

func eventNoun(_ event: WaitEvent, subject: WaitSubject?) -> String { eventWords(event, subject: subject).noun }
func eventClause(_ event: WaitEvent, subject: WaitSubject?) -> String { eventWords(event, subject: subject).clause }
