// When the app lock covers the app and when it asks to authenticate.
// Pure state, so the rules are testable without UIKit or LocalAuthentication.

import Foundation

/// How long the app may stay in the background before it needs unlocking.
enum AppLockDelay: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var id: Int { rawValue }
    var duration: Duration { .seconds(rawValue) }
}

struct AppLockPolicy: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// The app is visible.
        case unlocked
        /// Backgrounded: covered (so the app switcher shows no content), but
        /// still within the delay, so returning shows the app without asking.
        case covered
        /// Authentication is required before the app shows again.
        case locked
    }

    private(set) var enabled: Bool
    var delay: AppLockDelay
    private(set) var status: Status
    private var backgroundedAt: ContinuousClock.Instant?
    /// One automatic prompt per return to the app. Cancelling the prompt then
    /// leaves the lock screen with its Unlock button instead of re-prompting.
    private var promptPending: Bool

    /// A launch with the lock enabled starts locked.
    init(enabled: Bool, delay: AppLockDelay) {
        self.enabled = enabled
        self.delay = delay
        status = enabled ? .locked : .unlocked
        promptPending = enabled
    }

    var covers: Bool { status != .unlocked }

    /// Turning the lock on or off happens while the app is in use, so it
    /// never covers the app on its own.
    mutating func setEnabled(_ on: Bool) {
        enabled = on
        status = .unlocked
        backgroundedAt = nil
        promptPending = false
    }

    mutating func enteredBackground(at now: ContinuousClock.Instant) {
        guard enabled else { return }
        if status == .unlocked {
            status = .covered
            backgroundedAt = now
        }
    }

    mutating func enteringForeground(at now: ContinuousClock.Instant) {
        guard enabled else { return }
        if status == .covered, let since = backgroundedAt, now - since < delay.duration {
            status = .unlocked
        } else if status != .unlocked {
            status = .locked
            promptPending = true
        }
        backgroundedAt = nil
    }

    /// Called when the app becomes active; true once per return while locked.
    mutating func takeAutomaticPrompt() -> Bool {
        guard status == .locked, promptPending else { return false }
        promptPending = false
        return true
    }

    mutating func authenticated() {
        guard status == .locked else { return }
        status = .unlocked
        promptPending = false
    }
}
