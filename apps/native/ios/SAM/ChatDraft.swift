import SwiftUI

/// Unsent text belongs to a conversation, rather than the lifetime of its view.
/// AppStorage writes on each edit and notifies other windows of the same draft.
@propertyWrapper
struct ChatDraft: DynamicProperty {
    @AppStorage private var saved: String
    private let store: UserDefaults
    private let key: String

    init(server: String, user: String, project: String, session: String, store: UserDefaults = .standard) {
        // Encode components together so separators in IDs/URLs cannot collide.
        let scope = [server, user, project, session]
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

    /// A response for an older send must never discard a newly edited draft.
    func clear(ifUnchanged sent: String) {
        if store.string(forKey: key) == sent {
            store.set("", forKey: key)
        }
    }
}
