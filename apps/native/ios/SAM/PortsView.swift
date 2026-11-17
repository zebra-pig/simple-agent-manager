import SwiftUI

struct PortsView: View {
    @Bindable var model: PortsModel
    let workspaceId: String
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var browserError = false
    private var state: PortsState { model.state }
    private var busy: Bool { state.loading || state.saving || state.opening != nil }

    var body: some View {
        List {
            if let error = state.error {
                Section {
                    Text(error.message).foregroundStyle(.red)
                    Button("Retry") { Task { await model.core.refresh() } }.disabled(busy)
                }
            }
            Section {
                LabeledContent {
                    Text(!state.loaded ? "Checking…" : state.publicEnabled ? "Public" : "Private")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Site access", systemImage: state.publicEnabled ? "globe" : "lock.shield")
                }
                Toggle("Expose to public", isOn: $model.publicAccess)
                .disabled(!state.loaded || busy)
                .confirmationDialog("Expose all workspace ports?", isPresented: $model.confirmPublic, titleVisibility: .visible) {
                    Button("Expose to public", role: .destructive) {
                        Task { await model.core.setPublic(enabled: true) }
                    }
                } message: {
                    Text("Anyone with a port URL can access its site without signing in to SAM. This applies to every port in this workspace, including ports started later.")
                }
            } footer: {
                Text(state.publicEnabled
                     ? "All workspace ports are accessible without SAM sign-in. Your site's own authentication still applies."
                     : "Open sites securely using your SAM sign-in. They remain private to your workspace.")
            }
            Section("Server ports") {
                if state.ports.isEmpty {
                    if state.loading { ProgressView("Finding ports…") }
                    else if state.loaded {
                        ContentUnavailableView(state.readiness == "ready" ? "No servers running" : "Ports unavailable",
                                               systemImage: "network",
                                               description: Text(readinessDescription))
                    }
                }
                ForEach(state.ports, id: \.port) { port in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Port \(Int(port.port).formatted(.number.grouping(.never)))").font(.headline)
                            if !port.label.isEmpty { Text(port.label).foregroundStyle(.secondary) }
                        }
                        if let url = URL(string: port.url) {
                            Text(url.host() ?? port.url).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2)
                        }
                        let actionsLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 24))
                        actionsLayout {
                            Button {
                                Task {
                                    if let grant = await model.core.openPort(port: port.port), let url = URL(string: grant) {
                                        openURL(url) { accepted in browserError = !accepted }
                                    }
                                }
                            } label: {
                                Label(state.opening == port.port ? "Opening…" : "Open site", systemImage: "safari")
                                    .frame(minHeight: 44)
                            }.disabled(busy)
                            if state.publicEnabled, let url = URL(string: port.url) {
                                ShareLink(item: url) {
                                    Label("Share link", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                                }
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .refreshable { await model.core.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.core.refresh() } }
                    .disabled(busy)
            }
        }
        .alert("Couldn't open browser", isPresented: $browserError) {
            Button("OK", role: .cancel) { }
        } message: { Text("Try opening the site again.") }
        .task(id: workspaceId) {
            model.core.load(workspaceId: workspaceId)
            await model.core.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await model.core.refresh()
            }
        }
    }

    private var readinessDescription: String {
        switch state.readiness {
        case "ready": String(localized: "Start a development server in this workspace, then refresh.")
        case "sleeping", "stopped", "evicted": String(localized: "Resume the workspace to access its sites.")
        case "gone", "deleted": String(localized: "This workspace is no longer available.")
        default: String(localized: "Waiting for the workspace. Ports refresh automatically.")
        }
    }
}
