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
                ProjectsView(app: app.core)
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

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("SAM").font(.largeTitle.bold())
            Text("Your coding agents, at hand.").foregroundStyle(.secondary)
            Spacer()
            if let pending = app.state.signIn {
                VStack(spacing: 8) {
                    Text("Approve this code in the browser").foregroundStyle(.secondary)
                    Text(pending.userCode)
                        .font(.system(.title, design: .monospaced).bold())
                        .textSelection(.enabled)
                    ProgressView()
                    HStack {
                        Button("Open again") {
                            if let url = URL(string: pending.verificationUrl) { openURL(url) }
                        }
                        Button("Cancel", role: .cancel) { app.core.cancelSignIn() }
                    }
                }
            } else {
                TextField("Server", text: $server, prompt: Text("api.simple-agent-manager.org"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .urlKeyboard()
                    .onSubmit { signIn() }
                if let error = app.state.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button(action: signIn) {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.state.status == .signingIn || server.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .onAppear { if server.isEmpty { server = app.state.serverUrl } }
    }

    private func signIn() {
        let server = server
        Task {
            guard let link = await app.core.beginSignIn(serverUrl: server), let url = URL(string: link) else { return }
            openURL(url)
            await app.core.finishSignIn()
        }
    }
}
