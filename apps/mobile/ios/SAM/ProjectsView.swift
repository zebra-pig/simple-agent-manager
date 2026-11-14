import SwiftUI

/// A chat session to open: the stack's second level.
struct SessionRef: Hashable {
    let projectId: String
    let sessionId: String
}

struct ProjectsView: View {
    let app: App
    @State private var list: ProjectListModel
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showingAccount = false

    init(app: App) {
        self.app = app
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
                    Text(error).foregroundStyle(.red)
                }
                ForEach(projects, id: \.id) { project in
                    NavigationLink(value: project) { ProjectRow(project: project) }
                }
            }
            .overlay {
                if list.state.projects.isEmpty && list.state.loading {
                    ProgressView()
                } else if list.state.projects.isEmpty && list.state.error == nil {
                    ContentUnavailableView("No projects", systemImage: "folder",
                                           description: Text("Create a project in SAM on the web to get started."))
                }
            }
            .navigationTitle("Projects")
            .searchable(text: $query)
            .refreshable { await list.core.load() }
            .task { await list.core.load() }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
                }
            }
            .navigationDestination(for: Project.self) { project in
                ProjectView(app: app, project: project) { path.append($0) }
            }
            .navigationDestination(for: SessionRef.self) { ref in
                ChatView(app: app, ref: ref)
            }
            .sheet(isPresented: $showingAccount) { AccountView().macSheet() }
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
                    Label("\(project.activeSessionCount)", systemImage: "bolt.fill")
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
