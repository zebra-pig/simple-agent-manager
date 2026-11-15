import SwiftUI
import Charts

enum ChatTool: String, Identifiable {
    case files, git, timeline, resources, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .git: String(localized: "Git")
        case .timeline: String(localized: "Timeline")
        case .resources: String(localized: "Resources")
        case .details: String(localized: "Details")
        }
    }
}

struct ChatToolView: View {
    let tool: ChatTool
    let chat: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var file: String?
    @State private var staged = false
    @State private var diff = false
    @State private var search = ""
    private var model: ChatToolsModel { chat.tools }
    private var state: ChatToolsState { model.state }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = state.error {
                        Text(error.message).foregroundStyle(.red)
                        Button("Retry") { Task { await refresh() } }.glassButton()
                    }
                    if state.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let file {
                        HStack {
                            Button("Back", systemImage: "chevron.left") { self.file = nil; Task { await refresh() } }
                            if diff {
                                Button("View file", systemImage: "doc.text") {
                                    diff = false
                                    Task { await model.core.openFile(path: file, diff: false, staged: false) }
                                }
                            }
                        }.glassButton()
                        Text(verbatim: file).font(.caption.monospaced()).textSelection(.enabled)
                        code
                    } else {
                        switch tool {
                        case .files: files
                        case .git: changes
                        case .resources: resources
                        case .details: details
                        case .timeline: timeline
                        }
                    }
                }.padding()
            }
            .navigationTitle(tool.title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(state.loading)
                }
            }
            .modifier(ChatFileSearch(enabled: file == nil && (tool == .files || tool == .git), text: $search))
            .task { await refresh() }
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private func refresh() async {
        if let file { await model.core.openFile(path: file, diff: diff, staged: staged); return }
        switch tool {
        case .files: await model.core.browse(path: state.path.isEmpty ? "." : state.path)
        case .git: await model.core.gitStatus()
        case .resources: await model.core.resources()
        case .details:
            let session = chat.state.session
            let owner = session?.viewerAccess == "owner" || (session?.viewerAccess == nil && session?.isMine == true)
            await model.core.details(workspaceId: owner ? session?.workspaceId : nil, agentSessionId: session?.agentSessionId)
        case .timeline: break
        }
    }

    private func open(_ path: String, diff: Bool = false, staged: Bool = false) {
        file = path; self.diff = diff; self.staged = staged
        Task { await model.core.openFile(path: path, diff: diff, staged: staged) }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: state.path).font(.caption.monospaced()).textSelection(.enabled)
            if state.path != "." && !state.path.isEmpty {
                Button("Parent folder", systemImage: "arrow.up") {
                    let parent = (state.path as NSString).deletingLastPathComponent
                    Task { await model.core.browse(path: parent.isEmpty ? "." : parent) }
                }.glassButton()
            }
            if state.entries.isEmpty && !state.loading { Text("This folder is empty.").foregroundStyle(.secondary) }
            ForEach(state.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.name) { entry in
                Button {
                    let path = state.path == "." ? entry.name : "\(state.path)/\(entry.name)"
                    if entry.kind == "dir" { Task { await model.core.browse(path: path) } }
                    else { open(path) }
                } label: {
                    HStack {
                        Image(systemName: entry.kind == "dir" ? "folder" : "doc.text")
                        Text(verbatim: entry.name).lineLimit(1)
                        Spacer()
                        if entry.kind != "dir" { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).glass(in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.changes.isEmpty && !state.loading { Text("No uncommitted changes.").foregroundStyle(.secondary) }
            ForEach(0..<3) { group in
                let entries = state.changes.filter { group == 0 ? $0.staged : group == 1 ? (!$0.staged && !$0.untracked) : $0.untracked }
                if !entries.isEmpty {
                    Text(group == 0 ? String(localized: "Staged") : group == 1 ? String(localized: "Changes") : String(localized: "Untracked")).font(.headline)
                    ForEach(entries.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }, id: \.path) { entry in
                        Button { open(entry.path, diff: !entry.untracked, staged: entry.staged) } label: {
                            HStack {
                                Text(verbatim: entry.status).font(.caption.monospaced())
                                VStack(alignment: .leading) {
                                    Text(verbatim: entry.path)
                                    if let old = entry.oldPath { Text(verbatim: old).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).glass(in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private var code: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if state.lines.isEmpty && !state.loading { Text("No content to display.").padding() }
                ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 12) {
                        if diff { Text(line.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary) }
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
        }.glass(in: RoundedRectangle(cornerRadius: 16))
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session resource history").font(.headline)
            Text("Minute averages for CPU and memory; I/O totals per minute.").font(.caption).foregroundStyle(.secondary)
            if state.points.isEmpty && !state.loading {
                Text(state.collection == "pending" ? String(localized: "Resource history is still being collected.") : String(localized: "Resource history is unavailable for this session."))
            }
            if state.omittedChunks > 0 { Text("Some older resource history was omitted.").font(.caption) }
            resourceChart("CPU · cores", unit: 1, value: { $0.cpuCores })
            resourceChart("Memory · MiB", unit: 1_048_576, value: { $0.memoryBytes })
            resourceChart("Read · MiB/min", unit: 1_048_576, value: { $0.readBytes })
            resourceChart("Write · MiB/min", unit: 1_048_576, value: { $0.writeBytes })
        }
    }
    private func resourceChart(_ title: LocalizedStringKey, unit: Double, value: @escaping (ResourcePoint) -> Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline)
            Chart(chartSamples(value: value)) { sample in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: Double(sample.time) / 1000)), y: .value("Value", sample.value / unit), series: .value("Run", sample.segment))
                    .foregroundStyle(Color.secondary)
                PointMark(x: .value("Time", Date(timeIntervalSince1970: Double(sample.time) / 1000)), y: .value("Value", sample.value / unit))
                    .foregroundStyle(Color.secondary)
            }.frame(height: 150).chartYScale(domain: .automatic(includesZero: true))
        }.padding(14).glass(in: RoundedRectangle(cornerRadius: 20))
    }

    private struct ChartSample: Identifiable {
        let id: Int
        let time: Int64
        let value: Double
        let segment: Int
    }
    private func chartSamples(value: (ResourcePoint) -> Double?) -> [ChartSample] {
        var result: [ChartSample] = []
        var segment = 0
        var previous: ResourcePoint?
        for (index, point) in state.points.enumerated() {
            guard let y = value(point) else { segment += 1; previous = nil; continue }
            if let last = previous, last.runId != point.runId || point.time - last.time > 60_000 { segment += 1 }
            result.append(ChartSample(id: index, time: point.time, value: y, segment: segment))
            previous = point
        }
        return result
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = chat.state.session {
                detailCard {
                    Label(statusLabel(session), systemImage: "circle.fill").font(.headline)
                    LabeledContent("Session", value: session.id)
                    if let task = session.task {
                        LabeledContent("Task", value: taskStatusLabel(task.status))
                        if let step = task.executionStep { LabeledContent("Step", value: humanized(step)) }
                        if let branch = task.outputBranch { LabeledContent("Branch", value: branch) }
                    }
                }
            }
            if let w = state.workspace {
                detailCard {
                    Text("Infrastructure").font(.headline)
                    LabeledContent("Workspace", value: w.name)
                    LabeledContent("Status", value: humanized(w.status))
                    LabeledContent("Branch", value: w.branch)
                    if let location = w.vmLocation { LabeledContent("Location", value: location) }
                    if let node = state.node {
                        LabeledContent("VM", value: node.name)
                        LabeledContent("VM status", value: humanized(node.status))
                        if let health = node.healthStatus { LabeledContent("Health", value: humanized(health)) }
                        if let provider = node.cloudProvider { LabeledContent("Provider", value: provider) }
                        if let cpu = node.providerInstanceVcpuCount { LabeledContent("vCPUs", value: String(cpu)) }
                        if let memory = node.providerInstanceMemoryMb { LabeledContent("Memory · MiB", value: String(memory)) }
                    }
                }
            }
            detailCard {
                Text("Provider usage").font(.headline)
                if state.limits.isEmpty { Text("No provider balance or usage limits reported.").foregroundStyle(.secondary) }
                ForEach(Array(state.limits.enumerated()), id: \.offset) { _, limit in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "\(limit.provider) · \(limit.windowType)").font(.subheadline)
                        if limit.resetElapsed {
                            Text("Awaiting a new provider sample.")
                        } else {
                            if let remaining = limit.remainingAmount { LabeledContent("Remaining", value: remaining.formatted()) }
                            if let total = limit.limitAmount { LabeledContent("Limit", value: total.formatted()) }
                            if let used = limit.utilizationPercent {
                                ProgressView(value: min(max(used, 0), 100), total: 100).tint(.secondary)
                                Text("\(used.formatted())% used").font(.caption)
                            }
                        }
                        Text("Observed \(Date(timeIntervalSince1970: Double(limit.observedAt) / 1000).formatted())").font(.caption).foregroundStyle(.secondary)
                        if let reset = limit.resetsAt { LabeledContent("Resets", value: Date(timeIntervalSince1970: Double(reset) / 1000).formatted()) }
                    }
                }
            }
        }.textSelection(.enabled)
    }
    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content).padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(in: RoundedRectangle(cornerRadius: 20))
    }
    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(chat.state.messages, id: \.id) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(timeIntervalSince1970: Double(message.createdAt) / 1000), style: .time).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: message.content).lineLimit(5).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct ChatFileSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, prompt: "Filter files") }
        else { content }
    }
}
