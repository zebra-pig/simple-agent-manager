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
            ProjectSettings(app: app,
                projectId: CommandLine.arguments.contains("--create") ? nil : "p1",
                saved: { _ in })
            .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : .dark)
        }
    }
}
