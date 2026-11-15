// The Rust core's view models (Generated/SamCore.swift), wrapped so SwiftUI
// observes their state, plus the Keychain the core keeps the session in.

import Foundation
import Observation
import Security

@MainActor @Observable final class AppModel {
    let core: App
    private(set) var state: AppState

    init() {
        core = App(store: KeychainCredentialStore(), baseDomain: Brand.baseDomain)
        state = core.state()
        Push.core = core
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}

@MainActor @Observable final class ProjectListModel {
    let core: ProjectListViewModel
    private(set) var state: ProjectListState

    init(app: App) {
        core = ProjectListViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}

@MainActor @Observable final class ProjectModel {
    let core: ProjectViewModel
    private(set) var state: ProjectState

    init(app: App) {
        core = ProjectViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}

@MainActor @Observable final class ChatModel {
    let core: ChatViewModel
    let tools: ChatToolsModel
    private(set) var state: ChatState

    init(app: App) {
        core = ChatViewModel(app: app)
        tools = ChatToolsModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}

/// Core observers fire on whatever thread the core is on; this hands each
/// state to the main actor, in order (main queue is FIFO).
final class Relay<State>: @unchecked Sendable {
    private let apply: @MainActor (State) -> Void
    init(_ apply: @escaping @MainActor (State) -> Void) { self.apply = apply }
    func send(_ state: State) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(state) } }
    }
}

extension Relay: AppObserver where State == AppState {
    func onStateChanged(state: AppState) { send(state) }
}
extension Relay: ProjectListObserver where State == ProjectListState {
    func onStateChanged(state: ProjectListState) { send(state) }
}
extension Relay: ProjectObserver where State == ProjectState {
    func onStateChanged(state: ProjectState) { send(state) }
}
extension Relay: ChatObserver where State == ChatState {
    func onStateChanged(state: ChatState) { send(state) }
}

/// One generic-password item holding the server and session cookie as JSON.
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.simpleagentmanager.app",
        kSecAttrAccount as String: "session",
        // On the Mac: not the legacy file keychain, which prompts for the login
        // password whenever the app's signature changes. iOS has only this one.
        kSecUseDataProtectionKeychain as String: true,
    ]

    func load() -> Credentials? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = json["serverUrl"] as? String,
              let cookie = json["sessionCookie"] as? String
        else { return nil }
        return Credentials(serverUrl: server, sessionCookie: cookie)
    }

    func save(credentials: Credentials) {
        let json: [String: Any] = ["serverUrl": credentials.serverUrl, "sessionCookie": credentials.sessionCookie]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(item as CFDictionary)
    }
}

/// Build-time identity from Config/Brand.xcconfig (via Info.plist), so
/// white-label builds need no Swift changes.
enum Brand {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SAM"
    /// The platform's `BASE_DOMAIN` this build suggests; the API is `api.<domain>`.
    static let baseDomain = Bundle.main.object(forInfoDictionaryKey: "SAMBaseDomain") as? String
}

@MainActor @Observable final class ChatToolsModel {
    private let app: App
    let core: ChatToolsViewModel
    private(set) var state: ChatToolsState
    init(app: App) {
        self.app = app
        core = ChatToolsViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
    /// Each navigation destination owns its requests and retains its parent’s results.
    func navigationModel() -> ChatToolsModel {
        let model = ChatToolsModel(app: app)
        let session = core.state()
        model.core.load(projectId: session.projectId, sessionId: session.sessionId)
        return model
    }
}
extension Relay: ChatToolsObserver where State == ChatToolsState {
    func onStateChanged(state: ChatToolsState) { send(state) }
}

@MainActor @Observable final class ProjectManagementModel {
    let core: ProjectManagementViewModel
    private(set) var state: ProjectManagementState
    init(app: App) {
        core = ProjectManagementViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}
extension Relay: ProjectManagementObserver where State == ProjectManagementState {
    func onStateChanged(state: ProjectManagementState) { send(state) }
}
