import SwiftUI

/// Most cases script each prompt's result (SAM_LOCK_RESULTS, e.g. "success,failed")
/// to cover cancel and failure paths. SAM_LOCK_DEVICE=1 uses the production
/// DeviceAuthenticator against the simulator's enrolled Face ID instead.
/// Everything else is the production lock: windows, lifecycle, screen, settings.
private final class FixtureAuthenticator: AppAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String]

    init(script: String) { results = script.split(separator: ",").map(String.init) }

    func method() -> AppLockMethod { .faceID }

    func authenticate(reason: String) async -> AppAuthenticationResult {
        // Like the system sheet: the prompt takes a moment.
        try? await Task.sleep(for: .milliseconds(400))
        let next: String? = lock.withLock { results.isEmpty ? nil : results.removeFirst() }
        await MainActor.run { FixtureState.shared.prompts += 1 }
        return next == "success" ? .success : .failed
    }
}

@MainActor @Observable final class FixtureState {
    static let shared = FixtureState()
    var prompts = 0
}

@main struct AppLockFixture: SwiftUI.App {
    @State private var lock: AppLock

    init() {
        let env = ProcessInfo.processInfo.environment
        let store = UserDefaults(suiteName: "app-lock-fixture")!
        store.removePersistentDomain(forName: "app-lock-fixture")
        if env["SAM_LOCK_ENABLED"] == "1" { store.set(true, forKey: "appLock.enabled") }
        let authenticator: any AppAuthenticator = env["SAM_LOCK_DEVICE"] == "1"
            ? DeviceAuthenticator() : FixtureAuthenticator(script: env["SAM_LOCK_RESULTS"] ?? "")
        _lock = State(initialValue: AppLock(authenticator: authenticator, store: store))
    }

    var body: some Scene {
        WindowGroup { FixtureRoot().appLock(lock) }
    }
}

/// Typical state worth keeping: a tab, a pushed screen, a scroll position,
/// a presented sheet, a focused field and its unsent text.
private struct FixtureRoot: View {
    @State private var tab = 1
    var body: some View {
        TabView(selection: $tab) {
            Text("First tab").tabItem { Label("First", systemImage: "1.circle") }.tag(0)
            FixtureProjects().tabItem { Label("Projects", systemImage: "folder") }.tag(1)
        }
    }
}

private struct FixtureProjects: View {
    var body: some View {
        NavigationStack {
            List(1...50, id: \.self) { n in
                NavigationLink("Project \(n)", value: n)
            }
            .navigationTitle("Projects")
            .navigationDestination(for: Int.self) { FixtureDetail(number: $0) }
        }
    }
}

private struct FixtureDetail: View {
    let number: Int
    @State private var settings = false
    private var state = FixtureState.shared

    init(number: Int) { self.number = number }

    var body: some View {
        List {
            Text("Prompts: \(state.prompts)").accessibilityIdentifier("prompts")
            ForEach(1...200, id: \.self) { row in
                Text("Message \(row)").accessibilityIdentifier("message-\(row)")
            }
        }
        .navigationTitle("Chat \(number)")
        .toolbar { Button("Settings") { settings = true } }
        .sheet(isPresented: $settings) { FixtureSettings() }
    }
}

private struct FixtureSettings: View {
    @State private var note = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                AppLockSettings()
                Section { TextField("Note", text: $note).focused($focused).accessibilityIdentifier("note") }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
