import SwiftUI

/// Unsent text belongs to a project composer or conversation, rather than its view.
/// AppStorage writes on each edit and notifies other windows of the same draft.
@propertyWrapper
struct ChatDraft: DynamicProperty {
    @AppStorage private var saved: String
    private let store: UserDefaults
    private let key: String

    init(server: String, user: String, project: String, session: String? = nil, store: UserDefaults = .standard) {
        // Encode components together so separators in IDs/URLs cannot collide.
        // Three components identify a new-task draft; four identify a chat.
        // Even an empty session ID cannot collide with the project composer.
        let scope = [server, user, project] + (session.map { [$0] } ?? [])
        let key = "chat-draft.v1." + scope.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        self.store = store
        self.key = key
        _saved = AppStorage(wrappedValue: "", key, store: store)
    }

    var wrappedValue: String {
        get { saved }
        nonmutating set { saved = newValue }
    }
    var projectedValue: Binding<String> { $saved }

    /// Read durable storage directly: another window may have edited the draft
    /// before this property wrapper receives its AppStorage notification.
    func restore(ifEmpty content: String) {
        if (store.string(forKey: key) ?? "").isEmpty {
            store.set(content, forKey: key)
        }
    }
}

/// Owns the synchronous composer handoff, before the core observer can publish.
@MainActor @Observable final class ChatSubmission {
    private(set) var sending = false

    func send(draft: ChatDraft, operation: @escaping (String) async -> Bool) {
        guard !sending else { return }
        sending = true
        let content = draft.wrappedValue
        draft.wrappedValue = ""
        Task {
            let accepted = await operation(content)
            // A failed request must not overwrite text entered in another window
            // or after navigating back into this conversation.
            if !accepted { draft.restore(ifEmpty: content) }
            sending = false
        }
    }
}
