import XCTest

final class ComposerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    private func launch(_ variant: String) {
        app.launchArguments = [variant]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Attach files"].exists)
        XCTAssertFalse(app.buttons["Record audio"].exists)
        XCTAssertFalse(app.buttons["Microphone"].exists)
    }

    private func assertContained(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(element.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(element.frame.height, 0, file: file, line: line)
        XCTAssertTrue(app.frame.contains(element.frame), "Control clipped outside the window", file: file, line: line)
    }

    func testEmptyAndExpandedDraftLayoutAndSend() {
        launch("empty")
        let editor = app.textViews.firstMatch
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        assertContained(editor); assertContained(send)
        let emptyHeight = editor.frame.height
        editor.tap()
        editor.typeText(String(repeating: "Review the project and explain what needs attention. ", count: 6))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.isHittable)
        XCTAssertGreaterThan(editor.frame.height, emptyHeight)
        assertContained(editor); assertContained(send)
        XCTAssertLessThanOrEqual(editor.frame.maxY, send.frame.maxY + 1)
        send.tap()
        XCTAssertTrue(app.staticTexts["Submissions: 1"].waitForExistence(timeout: 5))
    }

    func testStopAndRetryInvokeActionWithoutText() {
        for variant in ["stop", "retry"] {
            launch(variant)
            let action = app.buttons[variant == "stop" ? "Stop" : "Retry"]
            XCTAssertTrue(action.isEnabled)
            XCTAssertTrue(action.isHittable)
            assertContained(action)
            action.tap()
            XCTAssertTrue(app.staticTexts["Submissions: 1"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testBusyReplacesSendAndKeepsEditorInBounds() {
        launch("busy")
        XCTAssertFalse(app.buttons["Send"].exists)
        let progress = app.progressIndicators.firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        assertContained(progress)
        assertContained(app.textViews.firstMatch)
        XCTAssertEqual(app.staticTexts["submissions"].label, "Submissions: 0")
    }

    func testNavigationHandoffDismissesKeyboardAndAllowsRefocus() {
        launch("navigate")
        let editor = app.textViews.firstMatch
        editor.tap(); editor.typeText("Start an agent")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Agent conversation"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
}
