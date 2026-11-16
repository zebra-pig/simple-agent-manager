import XCTest

final class ErrorBadgeUITests: XCTestCase {
    private let message = "Couldn't save your changes. Try again."

    func testNestedErrorIsDeduplicatedDismissibleAndCanRecur() {
        checkBadge(inSheet: false)
    }

    func testSheetOwnsItsErrorAndClearsOnResolution() {
        checkBadge(inSheet: true)
    }

    private func checkBadge(inSheet: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        if inSheet { app.buttons["Open settings"].tap() }
        let scope = inSheet ? "sheet" : "root"
        let trigger = app.buttons[scope + "-fail"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()
        let text = app.staticTexts[message]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: message).count, 1, "Duplicate error badges")
        XCTAssertTrue(app.frame.contains(text.frame))
        XCTAssertLessThan(text.frame.maxY, trigger.frame.minY, "Error should float above the request controls")
        XCTAssertTrue(app.staticTexts[scope + "-details"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = inSheet ? "sheet-error" : "nested-error"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Dismiss error"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        app.buttons[scope + "-resolve"].tap()
        trigger.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5), "A resolved error must be able to recur")
        app.buttons[scope + "-resolve"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        if inSheet {
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["Open settings"].waitForExistence(timeout: 5))
            XCTAssertFalse(text.exists, "Sheet error leaked to the parent")
        }
    }
}
