import XCTest

final class SplitViewUITests: XCTestCase {
    private func launch(push: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        if push { app.launchArguments.append("-fixture-push") }
        app.launch()
        return app
    }

    func testIPadNavigation() throws {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        try XCTSkipIf(app.frame.width < 600, "iPad coverage")
        XCTAssertTrue(app.staticTexts["Select a project"].waitForExistence(timeout: 15))
        XCTAssertTrue(project("atlas", in: app).waitForExistence(timeout: 15))
        capture("ipad-projects")
        project("atlas", in: app).tap()
        XCTAssertTrue(app.staticTexts["Build the dashboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(project("orchard", in: app).isHittable)
        capture("ipad-project-sessions")
        app.staticTexts["Build the dashboard"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["The dashboard layout is ready for review."].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.frame.width, app.frame.height)
        capture("ipad-chat-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.staticTexts["The dashboard layout is ready for review."].exists)
        XCTAssertTrue(project("orchard", in: app).isHittable)
        capture("ipad-chat-landscape")
        project("orchard", in: app).tap()
        XCTAssertTrue(app.staticTexts["Improve onboarding"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["The dashboard layout is ready for review."].exists)
        capture("ipad-switched-project")
        app.staticTexts["Improve onboarding"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["The onboarding flow now explains each step."].waitForExistence(timeout: 10))
        project("research", in: app).tap()
        XCTAssertTrue(app.staticTexts["No sessions yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["The onboarding flow now explains each step."].exists)
        capture("ipad-empty-project")
    }

    func testPushBeforeProjectsLoad() {
        let app = launch(push: true)
        XCTAssertTrue(app.staticTexts["The onboarding flow now explains each step."].waitForExistence(timeout: 15))
        if app.frame.width > 600 {
            // The sidebar is only on screen beside the conversation in regular width.
            XCTAssertTrue(project("orchard", in: app).waitForExistence(timeout: 15))
        }
        XCTAssertTrue(app.staticTexts["The onboarding flow now explains each step."].isHittable)
        XCTAssertFalse(app.staticTexts["The dashboard layout is ready for review."].exists)
        capture("ipad-notification-route")
    }

    func testCompactNavigation() throws {
        let app = launch()
        try XCTSkipIf(app.frame.width > 600, "iPhone coverage")
        XCTAssertTrue(project("atlas", in: app).waitForExistence(timeout: 15))
        project("atlas", in: app).tap()
        XCTAssertTrue(app.staticTexts["Build the dashboard"].waitForExistence(timeout: 10))
        app.staticTexts["Build the dashboard"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["The dashboard layout is ready for review."].waitForExistence(timeout: 10))
        capture("iphone-chat")
        goBack(in: app)
        XCTAssertTrue(waitHittable(app.staticTexts["Build the dashboard"].firstMatch))
        goBack(in: app)
        XCTAssertTrue(waitHittable(project("orchard", in: app)))
        project("atlas", in: app).tap()
        XCTAssertTrue(app.staticTexts["Build the dashboard"].waitForExistence(timeout: 5))
        capture("iphone-project-reselected")
    }

    private func project(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "project-\(id)").firstMatch
    }

    /// The iOS 27.2 bar back button is an unlabeled glass control outside any NavigationBar
    /// element, so prefer the system BackButton when it is exposed and otherwise use the
    /// interactive edge-swipe pop that NavigationStack supports on every version.
    private func goBack(in app: XCUIApplication) {
        // A collapsed split view keeps hidden bars from other columns; tap the visible one.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let buttons = app.descendants(matching: .any).matching(identifier: "BackButton").allElementsBoundByIndex
            if let back = buttons.first(where: { $0.exists && $0.isHittable }) { back.tap(); return }
            usleep(200_000)
        } while Date() < deadline
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
