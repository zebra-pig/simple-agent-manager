import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let viewer = app.state.viewer {
                    Section {
                        LabeledContent("Name", value: viewer.name)
                        LabeledContent("Email", value: viewer.email)
                    }
                }
                Section {
                    LabeledContent("Server", value: app.state.serverUrl)
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await app.core.signOut() }
                    }
                }
            }
            .initialLoading(app.state.viewer == nil && app.state.error == nil)
            .formStyle(.grouped)
            .navigationTitle("Account")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { if app.state.viewer == nil { await app.core.refreshViewer() } }
        }
        .floatingErrors([app.state.error?.message])
    }
}
