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
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Section {
                    LabeledContent("Server", value: app.state.serverUrl)
                }
                if let error = app.state.error {
                    Section { Text(error.message).foregroundStyle(.red) }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await app.core.signOut() }
                    }
                }
            }
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
    }
}
