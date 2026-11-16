import SwiftUI

private final class ScrollFixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? {
        Credentials(serverUrl: "http://127.0.0.1:18874", sessionCookie: "fixture=scroll-only")
    }
    func save(credentials: Credentials) {}
    func clear() {}
}

// Only the app entry point is replaced in an isolated build copy. The UI tests
// navigate the production ChatView, Rust model, HTTP transport, pager and button.
@main struct SAMScrollFixture: SwiftUI.App {
    private let app = App(store: ScrollFixtureCredentials(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(app: app, ref: SessionRef(projectId: "fixture", sessionId: "fixture"))
            }
        }
    }
}
