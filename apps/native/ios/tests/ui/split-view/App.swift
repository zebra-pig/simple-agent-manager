import SwiftUI

private final class SplitViewCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? { Credentials(serverUrl: "http://127.0.0.1:SAM_TEST_PORT", sessionCookie: "fixture=split-view") }
    func save(credentials: Credentials) {}
    func clear() {}
}

// Only the app entry point is replaced. The tests drive the production ProjectsView
// split navigation, ProjectView, ChatView, the Rust view models and real loopback HTTP.
// Run on an iPad (SAM_TEST_DEVICE_PREFIX=iPad) for the sidebar cases and on an iPhone
// for compact navigation; each case skips on the other idiom.
@main struct SplitViewFixture: SwiftUI.App {
    private let app = App(store: SplitViewCredentials(), baseDomain: nil)

    init() {
        if ProcessInfo.processInfo.arguments.contains("-fixture-push") {
            // A notification tapped before the project list has loaded.
            PushRouter.shared.pending = SessionRef(projectId: "orchard", sessionId: "orchard-session")
        }
    }

    var body: some Scene {
        WindowGroup {
            ProjectsView(app: app)
                .task { await app.refreshViewer() }
        }
    }
}
