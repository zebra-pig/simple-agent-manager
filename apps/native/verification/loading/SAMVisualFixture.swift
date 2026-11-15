import SwiftUI

final class LoadingFixtureStore: CredentialStore, @unchecked Sendable {
    let credentials: Credentials
    init() {
        let base = CommandLine.arguments.first { $0.hasPrefix("--base=") }!.dropFirst(7)
        credentials = Credentials(serverUrl: String(base), sessionCookie: "fixture=local-only")
    }
    func load() -> Credentials? { credentials }
    func save(credentials: Credentials) {}
    func clear() {}
}

struct LoadingFixture: View {
    let app: App
    @State private var chat: ChatModel
    init(app: App) {
        self.app = app
        let chat = ChatModel(app: app)
        chat.tools.core.load(projectId: "fixture", sessionId: "fixture")
        _chat = State(initialValue: chat)
    }
    var body: some View {
        Group {
            if CommandLine.arguments.contains("--settings") {
                ProjectSettings(app: app) { _ in }
            } else {
                ChatToolView(tool: .resources, chat: chat, serverUrl: app.state().serverUrl)
                    .task {
                        // The production view performs its first load. Start a second
                        // request after the loaded screen has been captured.
                        try? await Task.sleep(for: .seconds(7))
                        await chat.tools.core.resources()
                    }
            }
        }.preferredColorScheme(.dark)
    }
}

@main struct SAMLoadingFixture: SwiftUI.App {
    private let app = App(store: LoadingFixtureStore(), baseDomain: nil)
    var body: some Scene { WindowGroup { LoadingFixture(app: app) } }
}
