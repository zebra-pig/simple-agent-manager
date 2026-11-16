import SwiftUI
import UIKit

// Real ChatView and core HTTP transport against the accompanying offline server.
private final class ChatFixtureStore: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? {
        Credentials(serverUrl: ProcessInfo.processInfo.environment["SAM_FIXTURE_SERVER"]!, sessionCookie: "fixture=local-only")
    }
    func save(credentials: Credentials) {}
    func clear() {}
}

@main struct SlashCommandsChatFixture: SwiftUI.App {
    private let app = App(store: ChatFixtureStore(), baseDomain: nil)
    var body: some Scene { WindowGroup { ChatCapture(app: app) } }
}

private struct ChatCapture: View {
    let app: App
    @State private var dark = false
    var body: some View {
        NavigationStack {
            ChatView(app: app, ref: SessionRef(projectId: "p1", sessionId: "s1"))
        }
        .preferredColorScheme(dark ? .dark : .light)
        .task { await verify() }
    }

    @MainActor private func verify() async {
        func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
        func findEditor(_ view: UIView) -> UITextView? {
            if let input = view as? UITextView { return input }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)!
        var found: UITextView?
        for _ in 0..<60 {
            found = findEditor(window)
            if found != nil { break }
            await settle()
        }
        guard let input = found else { fatalError("Real chat reply editor did not load") }
        input.becomeFirstResponder()
        await settle()
        input.insertText("/re")
        await settle()
        await capture(window, "chat-light")
        guard let next = input.keyCommands?.first(where: { $0.input == UIKeyCommand.inputDownArrow }),
              let select = input.keyCommands?.first(where: { $0.input == "\r" }) else {
            fatalError("Cached commands did not reach the real ChatView composer")
        }
        _ = input.perform(next.action, with: next)
        await settle()
        _ = input.perform(select.action, with: select)
        await settle()
        precondition(input.text == "/review ", "Chat selection did not update its durable draft")
        precondition(input.isFirstResponder)
        input.insertText("the settings update")
        await settle()
        await capture(window, "chat-inserted")
        input.selectAll(nil)
        input.insertText("/re")
        input.resignFirstResponder()
        dark = true
        await settle()
        input.becomeFirstResponder()
        await settle()
        await capture(window, "chat-dark")
        try! "PASS: real ChatView loaded transcript and cached commands through Rust HTTP/UniFFI; reply autocomplete filtered, inserted a command and arguments, and retained focus without sending".write(
            to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    @MainActor private func capture(_ window: UIWindow, _ phase: String) async {
        try! Data().write(to: directory.appendingPathComponent(phase + ".ready"))
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(phase + ".done").path) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        preconditionFailure("Screenshot timed out: \(phase)")
    }
}
