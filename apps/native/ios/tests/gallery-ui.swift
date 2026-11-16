import XCTest

final class GalleryUITests: XCTestCase {
    func testChatWideGalleryKeepsSelectionThroughHistoryAndRepeatedSwipes() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.simpleagentmanager.validation.gallery")
        app.launch()
        let image = app.buttons["8.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        image.tap()
        XCTAssertTrue(app.staticTexts["8 of 9"].waitForExistence(timeout: 15))
        // User-uploaded images and library images from unloaded history must
        // form one chronological gallery. Real gestures drive the page binding.
        for _ in 0..<2 {
            for position in stride(from: 7, through: 1, by: -1) {
                app.swipeRight()
                XCTAssertTrue(app.staticTexts["\(position) of 9"].waitForExistence(timeout: 5))
            }
            app.swipeRight() // First-image boundary.
            XCTAssertTrue(app.staticTexts["1 of 9"].exists)
            for position in 2...9 {
                app.swipeLeft()
                XCTAssertTrue(app.staticTexts["\(position) of 9"].waitForExistence(timeout: 5))
            }
            app.swipeLeft() // Last-image boundary.
            XCTAssertTrue(app.staticTexts["9 of 9"].exists)
            app.swipeRight()
            XCTAssertTrue(app.staticTexts["8 of 9"].waitForExistence(timeout: 5))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "gallery-after-repeated-swipes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap()
        XCTAssertTrue(app.staticTexts["8 of 9"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
    }
}
