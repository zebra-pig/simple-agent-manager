import SwiftUI
import AppKit

// Run on a macOS host with ChatDraft.swift. Independent UserDefaults suites
// exercise actual durable storage; no live account or workspace is accessed.
@main struct ChatDraftTests {
    @MainActor static func main() {
        let suite = "sam-chat-draft-tests-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        func draft(server: String = "https://sam.example", user: String = "alice",
                   project: String = "project", session: String = "chat") -> ChatDraft {
            ChatDraft(server: server, user: user, project: project, session: session, store: store)
        }
        let original = draft()
        let text = "Unsent **text**\n日本語 👋\n  keep whitespace  "
        original.wrappedValue = text
        precondition(draft().wrappedValue == text, "Reopening a chat must restore the draft")
        let recreatedStore = UserDefaults(suiteName: suite)!
        let recreated = ChatDraft(server: "https://sam.example", user: "alice", project: "project", session: "chat", store: recreatedStore)
        precondition(recreated.wrappedValue == text, "Storage must survive model/store recreation")
        precondition(draft(session: "other-chat").wrappedValue.isEmpty)
        precondition(draft(project: "other-project").wrappedValue.isEmpty)
        precondition(draft(user: "bob").wrappedValue.isEmpty)
        precondition(draft(server: "https://other.example").wrappedValue.isEmpty)
        // A delayed successful send may complete after navigating away and
        // editing the same conversation through a newly created composer.
        let reopened = draft()
        reopened.wrappedValue = "Newer edit"
        original.clear(ifUnchanged: text)
        precondition(draft().wrappedValue == "Newer edit", "Old completion must preserve newer edits")
        original.clear(ifUnchanged: "Newer edit")
        precondition(draft().wrappedValue.isEmpty, "Accepted unchanged text must clear durably")
        original.wrappedValue = "Not sent"
        // A failed send never calls clear. Reopening must retain the text.
        precondition(draft().wrappedValue == "Not sent")
        original.projectedValue.wrappedValue = "Edited through composer binding"
        precondition(draft().wrappedValue == "Edited through composer binding")
        original.wrappedValue = ""
        precondition(draft().wrappedValue.isEmpty, "Explicit deletion must remain deleted")
        let a = ChatDraft(server: "a/b", user: "c", project: "p", session: "s", store: store)
        let b = ChatDraft(server: "a", user: "b/c", project: "p", session: "s", store: store)
        a.wrappedValue = "Separated scope"
        precondition(b.wrappedValue.isEmpty, "Scope component boundaries must not collide")
        // Exercise the production property wrapper in real SwiftUI navigation,
        // including destroying and reopening the composer view.
        _ = NSApplication.shared
        var path: Binding<[String]>?
        var editor: Binding<String>?
        let fixture = DraftNavigationFixture(store: store, pathReady: { path = $0 }, editorReady: { editor = $0 })
        let host = NSHostingView(rootView: fixture)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        settle()
        precondition(path != nil)
        path!.wrappedValue = ["chat"]
        settle()
        precondition(editor != nil)
        editor!.wrappedValue = text
        settle()
        path!.wrappedValue = []
        settle()
        editor = nil
        path!.wrappedValue = ["chat"]
        settle()
        precondition(editor?.wrappedValue == text, "Navigating back into a chat must restore its input")
        let pending = ChatDraft(server: "fixture", user: "alice", project: "project", session: "chat", store: store)
        editor!.wrappedValue = "Edited after reopening"
        pending.clear(ifUnchanged: text)
        settle()
        precondition(editor?.wrappedValue == "Edited after reopening")
        pending.clear(ifUnchanged: "Edited after reopening")
        settle()
        precondition(editor?.wrappedValue == "", "Successful send must clear the mounted editor too")
        window.orderOut(nil)
        print("CHAT_DRAFT_TESTS_PASS")
    }
}

private struct DraftNavigationFixture: View {
    let store: UserDefaults
    let pathReady: (Binding<[String]>) -> Void
    let editorReady: (Binding<String>) -> Void
    @State private var path: [String] = []
    var body: some View {
        NavigationStack(path: $path) {
            Text("Chats")
                .navigationDestination(for: String.self) { _ in
                    DraftEditorFixture(store: store, ready: editorReady)
                }
        }.onAppear { pathReady($path) }
    }
}
private struct DraftEditorFixture: View {
    @ChatDraft private var text: String
    let ready: (Binding<String>) -> Void
    init(store: UserDefaults, ready: @escaping (Binding<String>) -> Void) {
        _text = ChatDraft(server: "fixture", user: "alice", project: "project", session: "chat", store: store)
        self.ready = ready
    }
    var body: some View {
        TextField("Reply…", text: $text).onAppear { ready($text) }
    }
}
