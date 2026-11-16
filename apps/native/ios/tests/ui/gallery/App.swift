import SwiftUI

private final class GalleryFixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? { Credentials(serverUrl: "http://127.0.0.1:SAM_TEST_PORT", sessionCookie: "fixture=offline") }
    func save(credentials: Credentials) {}
    func clear() {}
}

@main struct GalleryFixtureApp: SwiftUI.App {
    private let app = App(store: GalleryFixtureCredentials(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack { ChatView(app: app, ref: SessionRef(projectId: "p", sessionId: "s")) }
        }
    }
}
