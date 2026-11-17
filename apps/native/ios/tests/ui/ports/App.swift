import SwiftUI

// Only the app entry point is replaced: production PortsView, PortsModel, the Rust
// ports view model and real loopback HTTP run unchanged.
@main struct PortsFixture: SwiftUI.App {
    @State private var model = PortsModel(app: App(store: FixtureCredentials(), baseDomain: nil))
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PortsView(model: model, workspaceId: "demo")
                    .navigationTitle("Ports")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") {} } }
            }
        }
    }
}

private final class FixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? {
        // The runner substitutes the fixture port. Port URLs must sit under the API host
        // (ws-demo--3000.localhost), so keep the host name rather than the IP literal.
        let port = "127.0.0.1:SAM_TEST_PORT".split(separator: ":").last ?? ""
        return Credentials(serverUrl: "http://localhost:\(port)", sessionCookie: "fixture=ports")
    }
    func save(credentials: Credentials) {}
    func clear() {}
}
