import SwiftUI

private final class SessionToolsCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? { Credentials(serverUrl: "http://127.0.0.1:SAM_TEST_PORT", sessionCookie: "fixture=session-tools") }
    func save(credentials: Credentials) {}
    func clear() {}
}

// Only the app entry point is replaced. The tests drive the production ChatView,
// its Session tools menu, the Rust view models and real loopback HTTP.
@main struct SessionToolsFixture: SwiftUI.App {
    private let app = App(store: SessionToolsCredentials(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack { ChatView(app: app, ref: SessionRef(projectId: "p", sessionId: "s")) }
                .task { await app.refreshViewer() }
        }
    }
}
