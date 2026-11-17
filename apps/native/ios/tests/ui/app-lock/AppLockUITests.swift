import XCTest
import notify

final class AppLockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app.state != .notRunning { attach("final") }
        app.terminate()
    }

    private var lockScreen: XCUIElement { app.otherElements["app-lock"] }
    private var unlockButton: XCUIElement { app.buttons["Unlock with Face ID"] }
    private var lockSwitch: XCUIElement { app.switches["Lock with Face ID"] }

    func testUnlockReturnsToTheExactScreenLeft() {
        launch(results: "success,failed,success")
        openChat(7)
        let anchor = scrollUntilHittable("message-60")
        let anchorY = anchor.frame.minY
        app.buttons["Settings"].tap()
        turnOnLock()
        let note = app.textFields["note"]
        note.tap()
        note.typeText("unsent note")
        let keyboardShown = app.keyboards.firstMatch.exists

        leaveAndReturn()
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 5), "Returning must show the lock")
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: unlockButton, enabled: true), "A cancelled prompt leaves the Unlock button")
        XCTAssertFalse(note.isHittable, "The app must be covered while locked")
        attach("locked-after-cancel")
        // A cancelled prompt does not come back by itself.
        Thread.sleep(forTimeInterval: 1.5)
        unlockButton.tap()
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 5))

        // The sheet, its field, focus and text are as they were.
        XCTAssertEqual(note.value as? String, "unsent note")
        XCTAssertEqual(app.keyboards.firstMatch.exists, keyboardShown, "Keyboard visibility changed")
        app.typeText("!")
        XCTAssertEqual(note.value as? String, "unsent note!", "Focus must return to the field")
        attach("unlocked-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(lockSwitch.waitForNonExistence(timeout: 5))

        // Beneath it: the same tab, pushed chat and scroll position.
        XCTAssertTrue(app.navigationBars["Chat 7"].exists)
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected)
        XCTAssertEqual(anchor.frame.minY, anchorY, accuracy: 1, "Scroll position moved")
        scrollUntilHittable("prompts", up: false)
        XCTAssertEqual(app.staticTexts["prompts"].label, "Prompts: 3", "Expected enable, one automatic prompt, one tap")
    }

    func testReturningWithinTheDelayShowsTheAppWithoutAsking() {
        launch(results: "success")
        openChat(2)
        app.buttons["Settings"].tap()
        turnOnLock()
        let require = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Require'")).firstMatch
        XCTAssertTrue(require.waitForExistence(timeout: 5), app.debugDescription)
        require.tap()
        let option = app.buttons["After 5 minutes"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'After 5 minutes' OR value CONTAINS 'After 5 minutes'")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].tap()
        XCTAssertTrue(lockSwitch.waitForNonExistence(timeout: 5))

        leaveAndReturn()
        XCTAssertTrue(app.navigationBars["Chat 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(lockScreen.waitForExistence(timeout: 2), "Within the delay the app must not lock")
        XCTAssertEqual(app.staticTexts["prompts"].label, "Prompts: 1")
    }

    func testLaunchWithTheLockOnStartsLocked() {
        app.launchEnvironment["SAM_LOCK_ENABLED"] = "1"
        launch(results: "failed,success")
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10), "A launch must not reveal the app")
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: unlockButton, enabled: true))
        XCTAssertFalse(app.buttons["Project 1"].isHittable)
        unlockButton.tap()
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 5))
        openChat(1)
        XCTAssertEqual(app.staticTexts["prompts"].label, "Prompts: 2")
    }

    func testCancelledConfirmationLeavesTheLockOff() {
        launch(results: "failed")
        openChat(3)
        app.buttons["Settings"].tap()
        XCTAssertTrue(lockSwitch.waitForExistence(timeout: 5))
        flip(lockSwitch)
        XCTAssertTrue(wait(for: lockSwitch, enabled: true))
        XCTAssertEqual(lockSwitch.value as? String, "0")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Require'")).firstMatch.exists)
        leaveAndReturn()
        XCTAssertFalse(lockScreen.waitForExistence(timeout: 2))
        XCTAssertTrue(lockSwitch.exists)
    }

    /// The production LocalAuthentication path with the simulator's Face ID:
    /// the runner shares the simulator's notification center with BiometricKit.
    func testRealFaceIDUnlocksToTheSameScreen() {
        setFaceIDEnrolled(true)
        defer { setFaceIDEnrolled(false) }
        app.launchEnvironment["SAM_LOCK_DEVICE"] = "1"
        app.launch()
        openChat(9)
        let anchor = scrollUntilHittable("message-80")
        let anchorY = anchor.frame.minY
        app.buttons["Settings"].tap()
        XCTAssertTrue(lockSwitch.waitForExistence(timeout: 5), "Face ID must be offered: \(app.debugDescription)")
        flip(lockSwitch)
        allowFaceIDIfAsked()
        matchFace()
        let on = NSPredicate(format: "value == '1'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: on, object: lockSwitch)], timeout: 10), .completed)
        app.buttons["Done"].tap()
        XCTAssertTrue(lockSwitch.waitForNonExistence(timeout: 5))

        leaveAndReturn()
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 5))
        attach("face-id-locked")
        Thread.sleep(forTimeInterval: 1)
        matchFace()
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 10), "A matched face must unlock")
        XCTAssertTrue(app.navigationBars["Chat 9"].exists)
        XCTAssertEqual(anchor.frame.minY, anchorY, accuracy: 1, "Scroll position moved")
        attach("face-id-unlocked")
        // Unlocked by the match, not released for lack of a passcode.
        app.buttons["Settings"].tap()
        XCTAssertTrue(lockSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(lockSwitch.value as? String, "1")
    }

    private func setFaceIDEnrolled(_ enrolled: Bool) {
        var token: Int32 = 0
        notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token)
        notify_set_state(token, enrolled ? 1 : 0)
        notify_post("com.apple.BiometricKit.enrollmentChanged")
        notify_cancel(token)
    }

    private func matchFace() {
        notify_post("com.apple.BiometricKit_Sim.pearl.match")
    }

    /// The first use asks permission (NSFaceIDUsageDescription).
    private func allowFaceIDIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for allow in [springboard.buttons["Allow"], springboard.buttons["OK"], app.buttons["Allow"], app.buttons["OK"]] {
            if allow.waitForExistence(timeout: 2) { allow.tap(); Thread.sleep(forTimeInterval: 1); return }
        }
    }

    // MARK: Helpers

    private func launch(results: String) {
        app.launchEnvironment["SAM_LOCK_RESULTS"] = results
        app.launch()
    }

    private func openChat(_ number: Int) {
        let row = app.buttons["Project \(number)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Chat \(number)"].waitForExistence(timeout: 5))
    }

    private func turnOnLock() {
        XCTAssertTrue(lockSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(lockSwitch.value as? String, "0")
        flip(lockSwitch)
        let on = NSPredicate(format: "value == '1'")
        let expectation = XCTNSPredicateExpectation(predicate: on, object: lockSwitch)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "Turning the lock on failed")
    }

    private func leaveAndReturn() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @discardableResult
    private func scrollUntilHittable(_ identifier: String, up: Bool = true) -> XCUIElement {
        let element = app.staticTexts[identifier]
        for _ in 0..<15 where !(element.exists && element.isHittable) {
            if up { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(element.isHittable, "\(identifier) never became visible")
        return element
    }

    /// Tap the switch itself; tapping a Form toggle's label does nothing.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func wait(for element: XCUIElement, enabled: Bool) -> Bool {
        let predicate = NSPredicate(format: "enabled == %@", NSNumber(value: enabled))
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
