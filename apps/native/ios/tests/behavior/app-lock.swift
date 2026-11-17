import XCTest

// Run on a macOS host with AppLockPolicy.swift and AppLock.swift. The scene
// windows are iOS-only; these cover the rules and the controller around a
// scripted authenticator, with real UserDefaults suites.

/// Core.swift (generated bindings) isn't part of the host bundle.
enum Brand { static let name = "SAM" }

private final class ScriptedAuthenticator: AppAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AppAuthenticationResult]
    private var available: AppLockMethod
    private(set) var prompts = 0

    init(_ results: [AppAuthenticationResult], method: AppLockMethod = .faceID) {
        self.results = results
        available = method
    }

    func method() -> AppLockMethod { lock.withLock { available } }

    func authenticate(reason: String) async -> AppAuthenticationResult {
        lock.withLock {
            prompts += 1
            return results.isEmpty ? .failed : results.removeFirst()
        }
    }
}

final class AppLockPolicyTests: XCTestCase {
    private let start = ContinuousClock.now

    func testDisabledLockNeverCovers() {
        var policy = AppLockPolicy(enabled: false, delay: .immediately)
        XCTAssertEqual(policy.status, .unlocked)
        policy.enteredBackground(at: start)
        XCTAssertEqual(policy.status, .unlocked)
        policy.enteringForeground(at: start + .seconds(7200))
        XCTAssertEqual(policy.status, .unlocked)
        XCTAssertFalse(policy.takeAutomaticPrompt())
    }

    func testLaunchWithLockEnabledStartsLockedAndPromptsOnce() {
        var policy = AppLockPolicy(enabled: true, delay: .fiveMinutes)
        XCTAssertEqual(policy.status, .locked)
        XCTAssertTrue(policy.takeAutomaticPrompt())
        XCTAssertFalse(policy.takeAutomaticPrompt(), "A cancelled prompt must not reopen by itself")
        policy.authenticated()
        XCTAssertEqual(policy.status, .unlocked)
    }

    func testBackgroundCoversImmediatelyEvenWithinTheDelay() {
        var policy = AppLockPolicy(enabled: true, delay: .oneHour)
        policy.authenticated()
        _ = policy.takeAutomaticPrompt()
        policy.enteredBackground(at: start)
        XCTAssertEqual(policy.status, .covered, "The app switcher snapshot must not show content")
        XCTAssertTrue(policy.covers)
    }

    func testReturningWithinTheDelayDoesNotAsk() {
        var policy = unlocked(delay: .oneMinute)
        policy.enteredBackground(at: start)
        policy.enteringForeground(at: start + .seconds(59))
        XCTAssertEqual(policy.status, .unlocked)
        XCTAssertFalse(policy.takeAutomaticPrompt())
    }

    func testReturningAfterTheDelayLocksAndPromptsOncePerReturn() {
        var policy = unlocked(delay: .oneMinute)
        policy.enteredBackground(at: start)
        policy.enteringForeground(at: start + .seconds(60))
        XCTAssertEqual(policy.status, .locked)
        XCTAssertTrue(policy.takeAutomaticPrompt())
        // The system prompt deactivates and reactivates the app.
        XCTAssertFalse(policy.takeAutomaticPrompt())
        // Leaving while still locked, then returning, prompts again.
        policy.enteredBackground(at: start + .seconds(70))
        XCTAssertEqual(policy.status, .locked, "Leaving a locked app must not restart the delay")
        policy.enteringForeground(at: start + .seconds(71))
        XCTAssertEqual(policy.status, .locked)
        XCTAssertTrue(policy.takeAutomaticPrompt())
    }

    func testImmediateDelayLocksOnAnyReturn() {
        var policy = unlocked(delay: .immediately)
        policy.enteredBackground(at: start)
        policy.enteringForeground(at: start)
        XCTAssertEqual(policy.status, .locked)
    }

    func testTogglingTheLockNeverCoversTheAppInUse() {
        var policy = AppLockPolicy(enabled: false, delay: .immediately)
        policy.setEnabled(true)
        XCTAssertEqual(policy.status, .unlocked)
        XCTAssertFalse(policy.takeAutomaticPrompt())
        policy.enteredBackground(at: start)
        policy.setEnabled(false)
        XCTAssertEqual(policy.status, .unlocked)
    }

    private func unlocked(delay: AppLockDelay) -> AppLockPolicy {
        var policy = AppLockPolicy(enabled: true, delay: delay)
        _ = policy.takeAutomaticPrompt()
        policy.authenticated()
        return policy
    }
}

final class AppLockControllerTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        continueAfterFailure = false
        suite = "sam-app-lock-tests-" + UUID().uuidString
        store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { store.removePersistentDomain(forName: suite) }

    @MainActor func testTurningOnRequiresAuthenticationAndPersists() async {
        let auth = ScriptedAuthenticator([.failed, .success])
        let lock = AppLock(authenticator: auth, store: store)
        let changedAfterCancel = await lock.setEnabled(true)
        XCTAssertFalse(changedAfterCancel)
        XCTAssertFalse(lock.enabled, "A cancelled confirmation must leave the lock off")
        let changed = await lock.setEnabled(true)
        XCTAssertTrue(changed)
        XCTAssertTrue(lock.enabled)
        XCTAssertEqual(lock.status, .unlocked)
        lock.delay = .fifteenMinutes
        let relaunched = AppLock(authenticator: ScriptedAuthenticator([]), store: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(relaunched.enabled)
        XCTAssertEqual(relaunched.delay, .fifteenMinutes)
        XCTAssertEqual(relaunched.status, .locked, "A relaunch with the lock on must start locked")
        XCTAssertEqual(auth.prompts, 2)
    }

    @MainActor func testTurningOnIsRefusedWithoutADevicePasscode() async {
        let auth = ScriptedAuthenticator([.success], method: .unavailable)
        let lock = AppLock(authenticator: auth, store: store)
        let changed = await lock.setEnabled(true)
        XCTAssertFalse(changed)
        XCTAssertFalse(lock.enabled)
        XCTAssertEqual(auth.prompts, 0)
    }

    @MainActor func testFailedUnlockStaysLockedAndSuccessUnlocks() async {
        store.set(true, forKey: "appLock.enabled")
        let auth = ScriptedAuthenticator([.failed, .success])
        let lock = AppLock(authenticator: auth, store: store)
        XCTAssertEqual(lock.status, .locked)
        await lock.unlock()
        XCTAssertEqual(lock.status, .locked)
        await lock.unlock()
        XCTAssertEqual(lock.status, .unlocked)
        await lock.unlock()
        XCTAssertEqual(auth.prompts, 2, "Unlocking an unlocked app must not prompt")
    }

    @MainActor func testRemovedDevicePasscodeReleasesTheLock() async {
        store.set(true, forKey: "appLock.enabled")
        let lock = AppLock(authenticator: ScriptedAuthenticator([.unavailable]), store: store)
        await lock.unlock()
        XCTAssertEqual(lock.status, .unlocked)
        XCTAssertFalse(lock.enabled)
        XCTAssertFalse(store.bool(forKey: "appLock.enabled"))
    }

    @MainActor func testTurningOffTakesEffectWithoutPrompting() async {
        let auth = ScriptedAuthenticator([.success])
        let lock = AppLock(authenticator: auth, store: store)
        await lock.setEnabled(true)
        let changed = await lock.setEnabled(false)
        XCTAssertTrue(changed)
        XCTAssertFalse(lock.enabled)
        XCTAssertEqual(auth.prompts, 1)
    }
}
