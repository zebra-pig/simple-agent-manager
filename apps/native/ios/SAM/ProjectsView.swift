import SwiftUI

/// Projects, a project's agents and the selected conversation in Mail-style
/// columns. Regular width shows the columns side by side; compact width
/// collapses them into one stack (Projects → Agents → Conversation).
struct ProjectsView: View {
    let app: App
    let onPush: () -> Void
    @State private var list: ProjectListModel
    @State private var selectedProjectId: String?
    @State private var selectedSession: SessionRef?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var query = ""
    @State private var showingAccount = false
    @State private var creating = false
    @State private var push = PushRouter.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(app: App, onPush: @escaping () -> Void = {}) {
        self.app = app
        self.onPush = onPush
        _list = State(initialValue: ProjectListModel(app: app))
    }

    private var projects: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list.state.projects }
        return list.state.projects.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.repository ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Keep the agents column's identity stable while a notification's project is loading.
    private var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return list.state.projects.first(where: { $0.id == id })
            ?? Project(id: id, name: String(localized: "Project"), repository: nil, activeSessionCount: 0)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $preferredCompactColumn) {
            projectList
        } content: {
            Group {
                if let project = selectedProject {
                    ProjectView(app: app, project: project, selectedSessionId: selectedSession?.sessionId,
                                changed: projectChanged, open: openSession)
                        .id(project.id)
                } else {
                    ContentUnavailableView("Select a project", systemImage: "folder",
                                           description: Text("Choose a project to see its agents and start a task."))
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            if let ref = selectedSession {
                // A fresh conversation per session, like a pushed destination.
                ChatView(app: app, ref: ref).id(ref)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Choose an agent to see its conversation."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.hidesTabBar, collapsed)
        .onChange(of: selectedProjectId) { _, id in
            // A push selects its project and session together; keep that route.
            if selectedSession?.projectId != id { selectedSession = nil }
        }
        .onChange(of: push.pending, initial: true) { _, ref in
            guard let ref else { return }
            onPush()
            push.pending = nil
            openSession(ref)
        }
    }

    /// Compact width stacks the columns, so agents and chats are pushed screens.
    private var collapsed: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var projectList: some View {
        List(selection: $selectedProjectId) {
            ForEach(projects, id: \.id) { project in
                // Explicit selection keeps arriving rows from replacing a notification's chat route.
                Button { selectProject(project.id) } label: {
                    ProjectRow(project: project)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(project.id)
                .accessibilityIdentifier("project-\(project.id)")
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
        }
        .overlay {
            if list.state.projects.isEmpty && list.state.error == nil {
                ContentUnavailableView("No projects", systemImage: "folder",
                                       description: Text("Tap + to create your first project."))
            }
        }
        .initialLoading(list.state.loading)
        .floatingErrors([list.state.error?.message])
        .navigationTitle("Projects")
        .searchable(text: $query)
        .refreshable { await list.core.load() }
        .task { await list.core.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New project", systemImage: "plus") { creating = true }
            }
            ToolbarItem(placement: .navigation) {
                Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
            }
        }
        .sheet(isPresented: $creating) {
            ProjectSettings(app: app) { project in
                Task {
                    await list.core.load()
                    if let project { selectProject(project.id) }
                }
            }
        }
        .sheet(isPresented: $showingAccount) { AccountView().macSheet() }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    private func selectProject(_ id: String) {
        if selectedProjectId != id { selectedSession = nil }
        selectedProjectId = id
        preferredCompactColumn = .content
    }

    private func openSession(_ ref: SessionRef) {
        selectedSession = ref
        selectedProjectId = ref.projectId
        preferredCompactColumn = .detail
    }

    private func projectChanged(_ updated: Project?) {
        selectedSession = nil
        if let updated {
            selectedProjectId = updated.id
        } else {
            selectedProjectId = nil
            preferredCompactColumn = .sidebar
        }
        Task { await list.core.load() }
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                if project.activeSessionCount > 0 {
                    Label { Text(project.activeSessionCount, format: .number) } icon: { Image(systemName: "bolt.fill") }
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if let repo = project.repository {
                Text(repo).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
