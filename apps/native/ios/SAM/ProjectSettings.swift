import SwiftUI

/// Repository onboarding and general project settings share a glass sheet.
struct ProjectSettings: View {
    let projectId: String?
    let saved: (Project?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectManagementModel
    @State private var name = ""
    @State private var description = ""
    @State private var provider = "github"
    @State private var installation = ""
    @State private var repositoryId: UInt64?
    @State private var repository = ""
    @State private var branch = "main"
    @State private var search = ""
    @State private var loadedFor = ""
    @State private var deleting = false
    @State private var confirmation = ""

    init(app: App, projectId: String? = nil, saved: @escaping (Project?) -> Void) {
        self.projectId = projectId
        self.saved = saved
        _model = State(initialValue: ProjectManagementModel(app: app))
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (projectId != nil || provider == "artifacts" || repositoryId != nil)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.state.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.state.error {
                        Text(error.message).foregroundStyle(.red)
                        if !model.state.initialized {
                            Button("Retry") { Task { await load() } }.glassButton()
                        }
                    }
                    if projectId == nil || model.state.project != nil {
                        card {
                            Label(projectId == nil ? "New project" : "General", systemImage: "folder").font(.headline)
                            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                            TextField("Description (optional)", text: $description, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(3...6)
                        }
                        card {
                            Label("Repository", systemImage: "chevron.left.forwardslash.chevron.right").font(.headline)
                            if let project = model.state.project {
                                Text(project.repository).textSelection(.enabled)
                                Text("The repository provider is fixed after creation.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker("Provider", selection: $provider) {
                                    Text("GitHub").tag("github")
                                    Text("GitLab").tag("gitlab")
                                    if model.state.artifactsEnabled { Text("SAM-hosted").tag("artifacts") }
                                }.onChange(of: provider) { _, _ in resetRepository() }
                                if provider == "github" {
                                    Picker("GitHub account", selection: $installation) {
                                        Text("Select account").tag("")
                                        ForEach(model.state.installations, id: \.id) { Text($0.accountName).tag($0.id) }
                                    }.onChange(of: installation) { _, _ in resetRepository() }
                                    if model.state.installations.isEmpty {
                                        Text("Connect a GitHub account in SAM on the web, then retry.").font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                if provider != "artifacts" {
                                    TextField("Search repositories", text: $search).textFieldStyle(.roundedBorder)
                                    Button("Load repositories") {
                                        repositoryId = nil
                                        loadedFor = "\(provider):\(installation)"
                                        Task { await model.core.loadRepositories(provider: provider, installationId: installation, search: search) }
                                    }.glassButton().disabled(provider == "github" && installation.isEmpty)
                                    ForEach(model.state.repositories.filter {
                                        loadedFor == "\(provider):\(installation)" &&
                                        (provider == "gitlab" || search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search))
                                    }, id: \.id) { repo in
                                        Button {
                                            repositoryId = repo.id; repository = repo.fullName; branch = repo.defaultBranch
                                            if name.isEmpty { name = repo.fullName.components(separatedBy: "/").last ?? "" }
                                        } label: {
                                            HStack {
                                                Text(repo.fullName); Spacer()
                                                if repositoryId == repo.id { Image(systemName: "checkmark") }
                                            }.frame(minHeight: 44).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }
                                    if !repository.isEmpty { Text(repository).font(.caption).foregroundStyle(.secondary) }
                                    if loadedFor == "\(provider):\(installation)" && !model.state.loading && model.state.repositories.isEmpty && model.state.error == nil {
                                        Text("No repositories found.").foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("SAM creates a private Git repository for this project.").foregroundStyle(.secondary)
                                }
                            }
                            if provider != "artifacts" {
                                TextField("Default branch", text: $branch).textFieldStyle(.roundedBorder)
                            }
                        }
                        if let project = model.state.project {
                            card {
                                Label("Delete project", systemImage: "trash").font(.headline).foregroundStyle(.red)
                                Text("Permanently deletes this project and all associated data. This cannot be undone.").font(.callout)
                                if deleting {
                                    Text("Type \(project.name) to confirm.").font(.callout)
                                    TextField("Confirm project name", text: $confirmation).textFieldStyle(.roundedBorder)
                                    Button("Permanently delete", role: .destructive) {
                                        Task { if await model.core.delete(confirmation: confirmation) { saved(nil); dismiss() } }
                                    }.glassButton().disabled(confirmation != project.name)
                                } else {
                                    Button("Delete project", role: .destructive) { deleting = true }.glassButton()
                                }
                            }
                        }
                    }
                }.padding(20).disabled(model.state.saving || model.state.loading)
            }
            .navigationTitle(projectId == nil ? "New project" : "Project settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.state.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(projectId == nil ? "Create" : "Save") {
                        Task {
                            let draft = ProjectDraft(name: name, description: description, provider: provider,
                                installationId: installation, repositoryId: repositoryId, repository: repository, defaultBranch: branch)
                            if let project = await model.core.save(draft: draft) { saved(project); dismiss() }
                        }
                    }.disabled(!valid || model.state.loading || model.state.saving || (projectId != nil && model.state.project == nil))
                }
            }
            .interactiveDismissDisabled(model.state.saving)
            .task { await load() }
        }.macSheet()
    }
    private func load() async {
        await model.core.load(projectId: projectId)
        if let project = model.core.state().project {
            name = project.name; description = project.description ?? ""; branch = project.defaultBranch
            provider = project.repoProvider; repository = project.repository
        }
    }
    private func resetRepository() { repositoryId = nil; repository = ""; branch = "main"; loadedFor = "" }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .glass(in: RoundedRectangle(cornerRadius: 24))
    }
}
