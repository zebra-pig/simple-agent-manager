import SwiftUI

enum ChatTool: String, Identifiable {
    case files, git, timeline, resources, details, progress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .git: String(localized: "Git")
        case .timeline: String(localized: "Timeline")
        case .resources: String(localized: "Resources")
        case .details: String(localized: "Details")
        case .progress: String(localized: "Progress")
        }
    }
}

struct ChatToolView: View {
    let tool: ChatTool
    let chat: ChatModel
    let serverUrl: String
    @Environment(\.dismiss) private var dismiss
    private var model: ChatToolsModel { chat.tools }
    private var state: ChatToolsState { model.state }

    var body: some View {
        NavigationStack {
            Group {
                switch tool {
                case .files: FileBrowserView(source: model)
                case .git: GitChangesView(source: model)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if tool != .progress, let error = state.error {
                                Text(error.message).foregroundStyle(.red)
                                Button("Retry") { Task { await refresh() } }.glassButton()
                            }
                            switch tool {
                            case .resources: resources
                            case .details: details
                            case .timeline: timeline
                            case .progress: ChatProgressView(state: chat.state, serverUrl: serverUrl)
                            case .files, .git: EmptyView()
                            }
                        }.padding()
                    }
                    .initialLoading(tool != .progress && state.loading)
                }
            }
            .navigationTitle(tool.title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if tool != .files && tool != .git {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await refresh() } } label: {
                            LoadingLabel(title: "Refresh", systemImage: "arrow.clockwise", loading: tool == .progress ? chat.state.loading : state.loading)
                        }.disabled(tool == .progress ? chat.state.loading : state.loading)
                    }
                }
            }
            .task { if tool != .files && tool != .git { await refresh() } }
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private func refresh() async {
        switch tool {
        case .files, .git: break
        case .resources: await model.core.resources()
        case .details:
            let session = chat.state.session
            let owner = session?.viewerAccess == "owner" || (session?.viewerAccess == nil && session?.isMine == true)
            await model.core.details(workspaceId: owner ? session?.workspaceId : nil, agentSessionId: session?.agentSessionId)
        case .progress: await chat.core.refresh()
        case .timeline: break
        }
    }

    private var resources: some View {
        ResourceHistoryView(points: state.points, collection: state.collection,
                            omittedChunks: state.omittedChunks, loading: state.loading)
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
            ForEach(chat.state.items, id: \.id) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(timeIntervalSince1970: Double(message.createdAt) / 1000), style: .time).font(.caption).foregroundStyle(.secondary)
                    if case let .document(document) = message.content {
                        DocumentCard(document: document, documents: chat.state.items.compactMap { if case let .document(d) = $0.content { return d }; return nil }, core: chat.core)
                    } else { TimelineItemView(item: message) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
