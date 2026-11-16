import SwiftUI

@main struct ErrorTestApp: SwiftUI.App {
    var body: some Scene { WindowGroup { ErrorTestScreen() } }
}

private struct ErrorTestScreen: View {
    @State private var sheet = false
    var body: some View {
        NavigationStack {
            ErrorTestForm().navigationTitle("Nested error")
                .toolbar { Button("Open settings") { sheet = true } }
                .floatingErrors()
        }
        .sheet(isPresented: $sheet) {
            NavigationStack {
                ErrorTestForm().navigationTitle("Settings")
                    .toolbar { Button("Done") { sheet = false } }
                    .floatingErrors()
            }
        }
    }
}

private struct ErrorTestForm: View {
    @State private var failed = false
    var body: some View {
        Form {
            Section("Request") {
                VStack {
                    Text("Request details stay visible.")
                    if failed {
                        ErrorNotice(message: "Couldn't save your changes. Try again.")
                        ErrorNotice(message: "Couldn't save your changes. Try again.")
                    }
                }
                Button("Fail request") { failed = true }
                Button("Resolve request") { failed = false }
            }
        }
    }
}
