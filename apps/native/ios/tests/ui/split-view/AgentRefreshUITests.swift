import XCTest

/// Mutate the server after the real project list has loaded; no direct model
/// calls or navigation changes may refresh the on-screen list for the test.
final class AgentRefreshUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        fixture("reset")
    }

    override func tearDown() { fixture("reset") }

    func testSpawnedAgentAppearsBesideOpenConversation() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.frame.width < 600, "iPad agent-list coverage")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let project = app.descendants(matching: .any).matching(identifier: "project-atlas").firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let parent = app.descendants(matching: .any).matching(identifier: "session-atlas-session").firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        parent.tap()
        let conversation = app.staticTexts["The dashboard layout is ready for review."]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        XCTAssertTrue(parent.isHittable)
        let child = app.descendants(matching: .any).matching(identifier: "session-atlas-child").firstMatch
        XCTAssertFalse(child.exists)

        fixture("spawn")

        XCTAssertTrue(child.waitForExistence(timeout: 15), "A server-side spawn must update the mounted agent list")
        XCTAssertTrue(child.isHittable)
        XCTAssertTrue(parent.isHittable)
        XCTAssertTrue(conversation.isHittable, "Refreshing the list must preserve the selected conversation")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ipad-live-agent-list"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPollingPausesInBackgroundAndCatchesUpOnForeground() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        try XCTSkipIf(app.frame.width < 600, "iPad lifecycle coverage")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let project = app.descendants(matching: .any).matching(identifier: "project-atlas").firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let parent = app.descendants(matching: .any).matching(identifier: "session-atlas-session").firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        XCTAssertTrue(parent.isHittable)

        XCUIDevice.shared.press(.home)
        // Allow an already-sent request to settle, then observe longer than a poll interval.
        pause(1)
        fixture("freeze")
        fixture("spawn")
        pause(6)
        fixture("assert-frozen")

        app.activate()
        let child = app.descendants(matching: .any).matching(identifier: "session-atlas-child").firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        XCTAssertTrue(child.isHittable)
    }

    private func pause(_ seconds: TimeInterval) {
        let deadline = expectation(description: "Observe the lifecycle interval")
        XCTAssertEqual(XCTWaiter.wait(for: [deadline], timeout: seconds), .timedOut)
    }

    private func fixture(_ action: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:SAM_TEST_PORT/fixture/\(action)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let done = expectation(description: "Fixture \(action)")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error)
            XCTAssertTrue([200, 202].contains((response as? HTTPURLResponse)?.statusCode ?? 0))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }
}
