import SwiftUI

/// Offline simulator fixture: the production ChatView with its real Rust model.
final class FixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? { Credentials(serverUrl: "http://127.0.0.1:18973", sessionCookie: "fixture=offline") }
    func save(credentials: Credentials) {}
    func clear() {}
}

@main struct SteeringFixture: SwiftUI.App {
    private let app: App
    @State private var model: ChatModel
    init() {
        let core = App(store: FixtureCredentials(), baseDomain: nil)
        app = core
        _model = State(initialValue: ChatModel(app: core))
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(app: app, ref: SessionRef(projectId: "fixture", sessionId: "chat"), model: model)
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                let mode = ProcessInfo.processInfo.arguments.last ?? "steer"
                if mode == "queue" { model.core.setDeliveryIntent(intent: .queue) }
                if mode == "interrupting" || mode == "error" { await model.core.interrupt() }
            }
        }
    }
}
