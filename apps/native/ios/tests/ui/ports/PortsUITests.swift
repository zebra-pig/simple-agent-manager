import XCTest

final class PortsUITests: XCTestCase {
    func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
    func testLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.switches["Expose to public"].waitForExistence(timeout: 20))
        capture(app, "iphone-large-text")
        app.swipeUp()
        XCTAssertTrue(app.buttons["Open site"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "iphone-large-text-ports")
    }
    func testPrivatePublicAndBrowserOpening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Port 3000"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Private"].exists)
        XCTAssertFalse(app.buttons["Share link"].firstMatch.exists)
        capture(app, "iphone-private")
        app.switches["Expose to public"].switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Expose all workspace ports?"].waitForExistence(timeout: 3))
        capture(app, "iphone-confirm-public")
        // iOS 27 presents an anchored confirmation popover; dismiss outside it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.staticTexts["Expose all workspace ports?"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Private"].exists)
        XCTAssertEqual(app.switches["Expose to public"].value as? String, "0")
        app.switches["Expose to public"].switches.firstMatch.tap()
        app.buttons.matching(identifier: "Expose to public").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts["Public"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Expose to public"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["Public"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Share link").count, 2)
        capture(app, "iphone-public")
        app.switches["Expose to public"].switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Private"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Expose to public"].value as? String, "0")
        XCTAssertFalse(app.buttons["Share link"].firstMatch.exists)
        app.buttons["Open site"].firstMatch.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
    }
}
