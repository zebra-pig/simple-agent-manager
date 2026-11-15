import SwiftUI

struct FileBrowserView: View {
    let path: String
    @State private var loaded = false
    @State private var model: ChatToolsModel
    @State private var search = ""

    init(source: ChatToolsModel, path: String = ".") {
        self.path = path
        _model = State(initialValue: source.navigationModel())
    }

    private var entries: [FileEntry] {
        model.state.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ToolLoadStatus(state: model.state, retry: refresh)
            if !model.state.loading && model.state.error == nil && entries.isEmpty {
                Text(search.isEmpty ? "This folder is empty." : "No matching files.").foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.name) { entry in
                let child = path == "." ? entry.name : "\(path)/\(entry.name)"
                NavigationLink {
                    if entry.kind == "dir" {
                        FileBrowserView(source: model, path: child)
                    } else {
                        SourceFileView(source: model, path: child)
                    }
                } label: {
                    HStack {
                        Label { Text(verbatim: entry.name).lineLimit(1) }
                            icon: { Image(systemName: entry.kind == "dir" ? "folder" : "doc.text") }
                        Spacer()
                        if entry.kind != "dir" {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .initialLoading(model.state.loading)
        .listStyle(.plain)
        .navigationTitle(path == "." ? String(localized: "Files") : (path as NSString).lastPathComponent)
        .inlineTitle()
        .searchable(text: $search, prompt: "Filter files")
        .toolbar { ToolRefreshButton(loading: model.state.loading, refresh: refresh) }
        .task {
            guard !loaded else { return }
            loaded = true
            await refresh()
        }
    }

    private func refresh() async { await model.core.browse(path: path) }
}

struct GitChangesView: View {
    @State private var loaded = false
    @State private var model: ChatToolsModel
    @State private var search = ""

    init(source: ChatToolsModel) { _model = State(initialValue: source.navigationModel()) }

    var body: some View {
        List {
            ToolLoadStatus(state: model.state, retry: refresh)
            if !model.state.loading && model.state.error == nil && model.state.changes.isEmpty {
                Text("No uncommitted changes.").foregroundStyle(.secondary)
            } else if !search.isEmpty && !model.state.changes.contains(where: matches) {
                Text("No matching files.").foregroundStyle(.secondary)
            }
            ForEach(0..<3) { group in
                let entries = model.state.changes.filter {
                    (group == 0 ? $0.staged : group == 1 ? (!$0.staged && !$0.untracked) : $0.untracked) && matches($0)
                }
                if !entries.isEmpty {
                    Section(group == 0 ? String(localized: "Staged") : group == 1 ? String(localized: "Changes") : String(localized: "Untracked")) {
                        ForEach(entries, id: \.path) { entry in
                            NavigationLink {
                                SourceFileView(source: model, path: entry.path, diff: !entry.untracked, staged: entry.staged)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(verbatim: entry.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .frame(minWidth: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: entry.path).lineLimit(2).truncationMode(.middle)
                                        if let old = entry.oldPath {
                                            Text(verbatim: old).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .initialLoading(model.state.loading)
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Filter files")
        .toolbar { ToolRefreshButton(loading: model.state.loading, refresh: refresh) }
        .task {
            guard !loaded else { return }
            loaded = true
            await refresh()
        }
    }

    private func matches(_ change: GitChange) -> Bool {
        search.isEmpty || change.path.localizedCaseInsensitiveContains(search)
            || change.oldPath?.localizedCaseInsensitiveContains(search) == true
    }
    private func refresh() async { await model.core.gitStatus() }
}

struct SourceFileView: View {
    let path: String
    let diff: Bool
    let staged: Bool
    @State private var loaded = false
    @State private var model: ChatToolsModel

    init(source: ChatToolsModel, path: String, diff: Bool = false, staged: Bool = false) {
        self.path = path
        self.diff = diff
        self.staged = staged
        _model = State(initialValue: source.navigationModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).padding()
            Divider()
            ToolLoadStatus(state: model.state, retry: refresh).padding(.horizontal)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.state.lines.isEmpty && !model.state.loading && model.state.error == nil {
                        Text("No content to display.").foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(model.state.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 12) {
                            if diff {
                                Text(line.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                            }
                            Text(line.newNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                            Text(verbatim: line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(line.kind == .added ? Color.green.opacity(0.14) : line.kind == .removed ? Color.red.opacity(0.14) : line.kind == .header ? Color.secondary.opacity(0.1) : .clear)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .initialLoading(model.state.loading)
        .navigationTitle((path as NSString).lastPathComponent)
        .inlineTitle()
        .toolbar {
            ToolRefreshButton(loading: model.state.loading, refresh: refresh)
            if diff {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SourceFileView(source: model, path: path)
                    } label: { Label("View file", systemImage: "doc.text") }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await refresh()
        }
    }

    private func refresh() async { await model.core.openFile(path: path, diff: diff, staged: staged) }
}

private struct ToolLoadStatus: View {
    let state: ChatToolsState
    let retry: () async -> Void

    var body: some View {
        if let error = state.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message).foregroundStyle(.red)
                Button("Retry") { Task { await retry() } }.disabled(state.loading)
            }.padding(.vertical, 8)
        }
    }
}

private struct ToolRefreshButton: ToolbarContent {
    let loading: Bool
    let refresh: () async -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await refresh() } } label: {
                LoadingLabel(title: "Refresh", systemImage: "arrow.clockwise", loading: loading)
            }.disabled(loading)
        }
    }
}
