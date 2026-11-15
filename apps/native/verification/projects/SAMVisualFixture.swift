import SwiftUI
final class VisualFixtureStore: CredentialStore, @unchecked Sendable {
    let credentials: Credentials
    init() {
        let base = CommandLine.arguments.first(where: { $0.hasPrefix("--base=") })!.dropFirst(7)
        credentials = Credentials(serverUrl: String(base), sessionCookie: "fixture=local-only")
    }
    func load() -> Credentials? { credentials }
    func save(credentials: Credentials) {}
    func clear() {}
}
@main struct SAMVisualFixture: SwiftUI.App {
    private let app = App(store: VisualFixtureStore(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            Group {
                if CommandLine.arguments.contains("--chat") {
                    NavigationStack { ChatView(app: app, ref: SessionRef(projectId: "p1", sessionId: "s1")) }
                } else if CommandLine.arguments.contains("--project") {
                    NavigationStack {
                        ProjectView(app: app, project: Project(id: "p1", name: "Project One", repository: "example/project-one", activeSessionCount: 1), changed: { _ in }, open: { _ in })
                    }
                } else {
                    ProjectsView(app: app)
                }
            }
            .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : .dark)
        }
    }
}
