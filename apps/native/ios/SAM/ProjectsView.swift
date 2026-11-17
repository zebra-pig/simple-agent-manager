import SwiftUI

struct ProjectsView: View {
    let app: App
    let onPush: () -> Void
    @State private var list: ProjectListModel
    @State private var selectedProjectId: String?
    @State private var path: [SessionRef] = []
    @State private var pendingSession: SessionRef?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var query = ""
    @State private var showingAccount = false
    @State private var creating = false
    @State private var push = PushRouter.shared

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

    /// Keep the detail root's identity stable while a notification's project is loading.
    private var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return list.state.projects.first(where: { $0.id == id })
            ?? Project(id: id, name: String(localized: "Project"), repository: nil, activeSessionCount: 0)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
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
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if let project = selectedProject {
                        ProjectView(app: app, project: project, changed: projectChanged, open: openSession)
                            .id(project.id)
                            .task { openPendingSession(for: project.id) }
                    } else {
                        ContentUnavailableView("Select a project", systemImage: "folder",
                                               description: Text("Choose a project to see its sessions and start a task."))
                    }
                }
                .navigationDestination(for: SessionRef.self) { ref in
                    ChatView(app: app, ref: ref)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedProjectId) { _, id in
            // A push selects its project and session together; keep that route.
            if path.last?.projectId != id { path.removeAll() }
            preferredCompactColumn = id == nil ? .sidebar : .detail
        }
        .onChange(of: push.pending, initial: true) { _, ref in
            guard let ref else { return }
            onPush()
            push.pending = nil
            openSession(ref)
        }
    }

    private func selectProject(_ id: String) {
        pendingSession = nil
        selectedProjectId = id
        path.removeAll()
        preferredCompactColumn = .detail
    }

    private func openSession(_ ref: SessionRef) {
        if selectedProjectId == ref.projectId && pendingSession == nil {
            path = [ref]
        } else {
            // Let the selected project's detail root mount before pushing its chat.
            pendingSession = ref
            selectedProjectId = ref.projectId
        }
        preferredCompactColumn = .detail
    }

    private func openPendingSession(for projectId: String) {
        guard let ref = pendingSession, ref.projectId == projectId else { return }
        pendingSession = nil
        path = [ref]
    }

    private func projectChanged(_ updated: Project?) {
        pendingSession = nil
        path.removeAll()
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
