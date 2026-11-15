import SwiftUI

@main
struct SAMApp: SwiftUI.App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.state.status == .signedIn {
                TabView {
                    ProjectsView(app: app.core).tabItem { Label("Projects", systemImage: "folder") }
                    NotificationsView(app: app.core).tabItem { Label("Notifications", systemImage: "bell") }
                }
            } else {
                SignInView()
            }
        }
        .task {
            if app.state.status == .signedIn { await app.core.refreshViewer() }
        }
    }
}

/// SAM's device flow: show a code, open the approval page in the browser
/// (where the user is signed in to SAM), and wait for the approval.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var server = ""
    /// Self-hosters type their own deployment; everyone else just taps Sign in.
    @State private var otherServer = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(verbatim: Brand.name).font(.largeTitle.bold())
            Text("Your coding agents, at hand.").foregroundStyle(.secondary)
            Spacer()
            if let pending = app.state.signIn {
                VStack(spacing: 8) {
                    Text("Approve this code in the browser").foregroundStyle(.secondary)
                    Text(pending.userCode)
                        .font(.system(.title, design: .monospaced).bold())
                        .textSelection(.enabled)
                    ProgressView()
                    GlassGroup {
                        HStack {
                            Button("Open again") {
                                if let url = URL(string: pending.verificationUrl) { openURL(url) }
                            }
                            .glassButton()
                            Button("Cancel", role: .cancel) { app.core.cancelSignIn() }
                                .glassButton()
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                if otherServer {
                    TextField("Server", text: $server, prompt: Text(verbatim: "example.com"))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glass(in: Capsule(), interactive: true)
                        .autocorrectionDisabled()
                        .urlKeyboard()
                        .onSubmit { signIn() }
                }
                if let error = app.state.error {
                    Text(error.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button(action: signIn) {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(app.state.status == .signingIn || (otherServer && server.trimmingCharacters(in: .whitespaces).isEmpty))
                if otherServer {
                    Button("Use \(deploymentName(serverUrl: app.state.serverUrl))") { otherServer = false }
                        .font(.footnote)
                } else {
                    VStack(spacing: 4) {
                        Text("Signs in to \(deploymentName(serverUrl: app.state.serverUrl))")
                            .foregroundStyle(.secondary)
                        Button("Use another server") { otherServer = true }
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
    }

    private func signIn() {
        let server = otherServer ? server : app.state.serverUrl
        Task {
            guard let link = await app.core.beginSignIn(serverUrl: server), let url = URL(string: link) else { return }
            openURL(url)
            await app.core.finishSignIn()
        }
    }
}
