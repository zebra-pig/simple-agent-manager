import XCTest

final class FirstTaskUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        reset()
    }

    override func tearDown() { reset() }

    private func reset(_ options: [String: Bool] = [:]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:SAM_TEST_PORT/fixture/reset")!)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: options)
        let done = expectation(description: "Reset the offline API")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }

    private func openProject(_ app: XCUIApplication, id: String = "research") {
        let project = app.descendants(matching: .any).matching(identifier: "project-\(id)").firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
    }

    func testUnsentTaskSurvivesSwitchingProjectAndRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.frame.width < 600, "iPad first-task coverage")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        openProject(app)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let prompt = "Keep my first task draft, including spacing."
        replaceText(editor, with: prompt)
        openProject(app, id: "atlas")
        openProject(app)
        XCTAssertEqual(editor.value as? String, prompt)
        app.terminate(); app.launch()
        openProject(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, prompt)
        capture(app, name: "ipad-restored-project-draft")
        editor.tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prompt.count))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replaceText(_ editor: XCUIElement, with text: String) {
        editor.tap()
        let count = (editor.value as? String)?.count ?? 0
        if count > 0 { editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
        editor.typeText(text)
    }

    func testFailedFirstSendKeepsDraftThroughRelaunchAndRetry() throws {
        reset(["rejectNext": true])
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.frame.width < 600, "iPad first-task coverage")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        openProject(app)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let prompt = "Retry this first task without losing my text."
        replaceText(editor, with: prompt)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Please retry the task."].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, prompt)
        app.terminate(); app.launch()
        openProject(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, prompt)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["The first task was received."].waitForExistence(timeout: 10))
        openProject(app, id: "atlas")
        openProject(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "")
        capture(app, name: "ipad-first-task-retry-clears-draft")
    }

    func testSendFirstTaskFromEmptyProject() throws {
        reset(["slowRefresh": true])
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.frame.width < 600, "iPad first-task coverage")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let project = app.descendants(matching: .any).matching(identifier: "project-research").firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        XCTAssertTrue(app.staticTexts["No sessions yet"].waitForExistence(timeout: 10))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let prompt = "Prepare the first research task from iPad."
        replaceText(editor, with: prompt)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["The first task was received."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[prompt].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-research-session").firstMatch.waitForExistence(timeout: 15))
        capture(app, name: "ipad-first-task-sent")
    }
}
