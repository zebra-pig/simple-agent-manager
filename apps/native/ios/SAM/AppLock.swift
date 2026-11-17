// App lock: Face ID, Touch ID or the device passcode before the app shows again.
//
// Unlocking returns to exactly what was on screen. The lock therefore never
// replaces the root view, which would tear down navigation stacks, sheets,
// scroll positions, focus and in-flight work. The app's views stay mounted and
// a separate window above every app window (sheets, full-screen covers and
// alerts included) covers them, and takes keyboard focus, until the person
// authenticates. Hiding that window hands key status back to the app's window,
// which restores its own first responder.

import Foundation
import LocalAuthentication
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppLockMethod: Equatable, Sendable {
    case faceID, touchID, opticID, passcode
    /// The device has no passcode, so there is nothing to unlock with.
    case unavailable
}

enum AppAuthenticationResult: Sendable {
    case success
    case failed
    /// The device can no longer authenticate (its passcode was removed).
    case unavailable
}

protocol AppAuthenticator: Sendable {
    func method() -> AppLockMethod
    func authenticate(reason: String) async -> AppAuthenticationResult
}

/// Biometrics with the device passcode as fallback.
struct DeviceAuthenticator: AppAuthenticator {
    func method() -> AppLockMethod {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    func authenticate(reason: String) async -> AppAuthenticationResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .failed
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return (error as? LAError)?.code == .passcodeNotSet ? .unavailable : .failed
        }
    }
}

@MainActor @Observable final class AppLock {
    private(set) var policy: AppLockPolicy
    private(set) var authenticating = false
    private(set) var method: AppLockMethod
    @ObservationIgnored private let authenticator: any AppAuthenticator
    @ObservationIgnored private let store: UserDefaults
    #if os(iOS)
    @ObservationIgnored private var windows = AppLockWindows()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    #endif

    private static let enabledKey = "appLock.enabled"
    private static let delayKey = "appLock.delay"

    init(authenticator: any AppAuthenticator = DeviceAuthenticator(), store: UserDefaults = .standard) {
        self.authenticator = authenticator
        self.store = store
        method = authenticator.method()
        let delay = AppLockDelay(rawValue: store.integer(forKey: Self.delayKey)) ?? .immediately
        policy = AppLockPolicy(enabled: store.bool(forKey: Self.enabledKey), delay: delay)
        #if os(iOS)
        observeLifecycle()
        #endif
    }

    var enabled: Bool { policy.enabled }
    var status: AppLockPolicy.Status { policy.status }

    var delay: AppLockDelay {
        get { policy.delay }
        set {
            policy.delay = newValue
            store.set(newValue.rawValue, forKey: Self.delayKey)
        }
    }

    /// Turning the lock on first proves the person can unlock, so a failed
    /// enrolment can't lock them out. Returns whether the setting changed.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on != policy.enabled, !authenticating else { return false }
        if on {
            method = authenticator.method()
            guard method != .unavailable else { return false }
            authenticating = true
            let result = await authenticator.authenticate(reason: String(localized: "Turn on the lock for \(Brand.name)"))
            authenticating = false
            guard case .success = result else { return false }
        }
        policy.setEnabled(on)
        store.set(on, forKey: Self.enabledKey)
        refreshCover()
        return true
    }

    func unlock() async {
        guard policy.status == .locked, !authenticating else { return }
        authenticating = true
        let result = await authenticator.authenticate(reason: String(localized: "Unlock \(Brand.name)"))
        authenticating = false
        switch result {
        case .success:
            policy.authenticated()
        case .unavailable:
            // Without a device passcode there is nothing to unlock with;
            // keeping the lock would only shut the person out of their data.
            policy.setEnabled(false)
            store.set(false, forKey: Self.enabledKey)
        case .failed:
            break
        }
        refreshCover()
    }

    // MARK: Lifecycle

    func enteredBackground() {
        policy.enteredBackground(at: .now)
        refreshCover()
    }

    func enteringForeground() {
        method = authenticator.method()
        policy.enteringForeground(at: .now)
        refreshCover()
    }

    func becameActive() {
        refreshCover()
        if policy.takeAutomaticPrompt() { Task { await unlock() } }
    }

    private func refreshCover() {
        #if os(iOS)
        windows.update(covering: policy.covers, lock: self)
        #endif
    }

    #if os(iOS)
    /// The scene the app's views live in; called as soon as they join a window,
    /// so a lock enabled at launch covers the very first frame.
    func attach(to window: UIWindow) {
        windows.attach(to: window)
        refreshCover()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // UIKit notifications are delivered synchronously, before the system
        // takes the app-switcher snapshot, unlike a SwiftUI scenePhase change.
        let events: [(Foundation.Notification.Name, @MainActor (AppLock) -> Void)] = [
            (UIApplication.didEnterBackgroundNotification, { $0.enteredBackground() }),
            (UIApplication.willEnterForegroundNotification, { $0.enteringForeground() }),
            (UIApplication.didBecomeActiveNotification, { $0.becameActive() }),
        ]
        observers = events.map { name, action in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
    }
    #endif
}

#if os(iOS)
/// One lock window per scene the app's views appear in, above all of the
/// scene's other windows.
@MainActor private struct AppLockWindows {
    private struct Entry {
        weak var content: UIWindow?
        let cover: UIWindow
    }
    private var entries: [Entry] = []

    mutating func attach(to window: UIWindow) {
        entries.removeAll { $0.content == nil }
        guard let scene = window.windowScene, !entries.contains(where: { $0.content === window }) else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.isHidden = true
        entries.append(Entry(content: window, cover: cover))
    }

    func update(covering: Bool, lock: AppLock) {
        for entry in entries {
            let cover = entry.cover
            if covering {
                guard cover.isHidden else { continue }
                if cover.rootViewController == nil {
                    let host = UIHostingController(rootView: AppLockScreen(lock: lock))
                    host.view.backgroundColor = .systemBackground
                    cover.rootViewController = host
                }
                cover.makeKeyAndVisible()
                // Render now: the snapshot follows this notification directly.
                cover.layoutIfNeeded()
            } else if !cover.isHidden {
                cover.isHidden = true
                entry.content?.makeKey()
            }
        }
    }
}

/// Finds the window the app's views are in, for `AppLock.attach(to:)`.
private struct AppLockAnchor: UIViewRepresentable {
    let lock: AppLock
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.lock = lock
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        weak var lock: AppLock?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { lock?.attach(to: window) }
        }
    }
}
#endif

extension View {
    /// Covers this scene with the lock screen while `lock` requires it.
    func appLock(_ lock: AppLock) -> some View {
        #if os(iOS)
        background(AppLockAnchor(lock: lock)).environment(lock)
        #else
        environment(lock)
        #endif
    }
}

extension AppLockMethod {
    var unlockTitle: LocalizedStringKey {
        switch self {
        case .faceID: "Unlock with Face ID"
        case .touchID: "Unlock with Touch ID"
        case .opticID: "Unlock with Optic ID"
        case .passcode, .unavailable: "Unlock"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode, .unavailable: "lock.open"
        }
    }

    var settingTitle: LocalizedStringKey {
        switch self {
        case .faceID: "Lock with Face ID"
        case .touchID: "Lock with Touch ID"
        case .opticID: "Lock with Optic ID"
        case .passcode, .unavailable: "Lock with passcode"
        }
    }
}

struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: Brand.name).font(.largeTitle.bold())
            Text("Locked").foregroundStyle(.secondary)
            Spacer()
            if lock.status == .locked {
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(lock.method.unlockTitle, systemImage: lock.method.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(lock.authenticating)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-lock")
    }
}

/// The Account screen's lock settings.
struct AppLockSettings: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        @Bindable var lock = lock
        Section {
            Toggle(lock.method.settingTitle, isOn: Binding(
                get: { lock.enabled },
                set: { on in Task { await lock.setEnabled(on) } }
            ))
            .disabled(lock.authenticating || (!lock.enabled && lock.method == .unavailable))
            if lock.enabled {
                Picker("Require", selection: $lock.delay) {
                    ForEach(AppLockDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
            }
        } footer: {
            if lock.method == .unavailable && !lock.enabled {
                Text("Set a passcode on this device to lock \(Brand.name).")
            } else {
                Text("Asks to unlock when you return to \(Brand.name). You'll see the screen you left.")
            }
        }
    }
}

extension AppLockDelay {
    var title: LocalizedStringKey {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        case .oneHour: "After 1 hour"
        }
    }
}
