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
        original.projectedValue.wrappedValue = "Edited through composer binding"
        precondition(draft().wrappedValue == "Edited through composer binding")
        original.wrappedValue = ""
        precondition(draft().wrappedValue.isEmpty, "Explicit deletion must remain deleted")
        let a = ChatDraft(server: "a/b", user: "c", project: "p", session: "s", store: store)
        let b = ChatDraft(server: "a", user: "b/c", project: "p", session: "s", store: store)
        a.wrappedValue = "Separated scope"
        precondition(b.wrappedValue.isEmpty, "Scope component boundaries must not collide")
        // A suspended request models a slow server/history refresh. The handoff
        // must finish synchronously, and duplicate taps must never start work.
        let submission = ChatSubmission()
        var complete: CheckedContinuation<Bool, Never>?
        var requests = 0
        original.wrappedValue = text
        submission.send(draft: original) { sent in
            requests += 1
            precondition(sent == text)
            return await withCheckedContinuation { complete = $0 }
        }
        precondition(original.wrappedValue.isEmpty, "Tap must clear before async work starts")
        precondition(submission.sending, "Tap must lock before observer delivery")
        submission.send(draft: original) { _ in fatalError("Duplicate send") }
        func waitForRequest() {
            while complete == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func finish(_ accepted: Bool) {
            complete!.resume(returning: accepted)
            complete = nil
            while submission.sending { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        waitForRequest()
        precondition(requests == 1)
        finish(false)
        precondition(draft().wrappedValue == text, "Failure must restore durable draft")
        submission.send(draft: original) { _ in
            await withCheckedContinuation { complete = $0 }
        }
        waitForRequest()
        draft().wrappedValue = "New draft during request"
        finish(false)
        precondition(draft().wrappedValue == "New draft during request", "Failure must preserve newer input")
        submission.send(draft: original) { _ in
            await withCheckedContinuation { complete = $0 }
        }
        waitForRequest()
        draft().wrappedValue = "Next message"
        finish(true)
        precondition(draft().wrappedValue == "Next message", "Success must preserve next message")
        original.wrappedValue = ""
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
        editor!.wrappedValue = text
        settle()
        let mountedSubmission = ChatSubmission()
        mountedSubmission.send(draft: pending) { _ in
            await withCheckedContinuation { complete = $0 }
        }
        settle()
        precondition(editor?.wrappedValue == "", "Sending must clear the mounted editor while request is pending")
        precondition(mountedSubmission.sending)
        precondition(complete != nil)
        complete!.resume(returning: false)
        complete = nil
        settle()
        precondition(editor?.wrappedValue == text, "Failed send must restore mounted editor")
        precondition(!mountedSubmission.sending)
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
