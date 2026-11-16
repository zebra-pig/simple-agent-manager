import SwiftUI

/// Exercises the production preference path used by attachments and request forms.
@main struct ErrorBadgeFixture: App {
    @State private var failed = false
    @State private var sheet = false
    private var sheetMode: Bool { ProcessInfo.processInfo.arguments.contains("sheet") }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Request") {
                        Text("The error must appear above this form.")
                        if failed && !sheetMode {
                            ErrorNotice(message: "Can't reach the server. Check your connection and try again.")
                        }
                        Button("Retry") { failed = false }
                    }
                }
                .navigationTitle("Nested error")
                .floatingErrors()
            }
            .sheet(isPresented: $sheet) {
                NavigationStack {
                    Form {
                        Text("The error belongs above this sheet.")
                        if failed { ErrorNotice(message: "Couldn't save your changes. Try again.") }
                        Button("Retry") { failed = false }
                    }
                    .navigationTitle("Settings")
                }
                .floatingErrors()
            }
            .task {
                sheet = sheetMode
                try? await Task.sleep(for: .seconds(1))
                failed = true
            }
        }
    }
}
