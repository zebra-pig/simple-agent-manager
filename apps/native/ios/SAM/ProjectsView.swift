import SwiftUI

/// A chat session to open: the stack's second level.
struct SessionRef: Hashable {
    let projectId: String
    let sessionId: String
}

struct ProjectsView: View {
    let app: App
    let onPush: () -> Void
    @State private var list: ProjectListModel
    @State private var path = NavigationPath()
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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = list.state.error {
                    Text(error.message).foregroundStyle(.red)
                }
                ForEach(projects, id: \.id) { project in
                    NavigationLink(value: project) {
                        ProjectRow(project: project).padding(12).glass(in: RoundedRectangle(cornerRadius: 20))
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .overlay {
                if list.state.projects.isEmpty && list.state.loading {
                    ProgressView()
                } else if list.state.projects.isEmpty && list.state.error == nil {
                    ContentUnavailableView("No projects", systemImage: "folder",
                                           description: Text("Tap + to create your first project."))
                }
            }
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
            .navigationDestination(for: Project.self) { project in
                ProjectView(app: app, project: project, changed: { updated in
                    path = NavigationPath()
                    Task { await list.core.load() }
                    if let updated { path.append(updated) }
                }) { path.append($0) }
            }
            .navigationDestination(for: SessionRef.self) { ref in
                ChatView(app: app, ref: ref)
            }
            .sheet(isPresented: $creating) {
                ProjectSettings(app: app) { project in
                    Task { await list.core.load() }
                    if let project { path.append(project) }
                }
            }
            .sheet(isPresented: $showingAccount) { AccountView().macSheet() }
            // A tapped notification opens its session on top of the stack.
            .onChange(of: push.pending, initial: true) { _, ref in
                guard let ref else { return }
                onPush()
                push.pending = nil
                path.append(ref)
            }
        }
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
