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
        backButton("Atlas", in: app).tap()
        XCTAssertTrue(app.staticTexts["Build the dashboard"].firstMatch.isHittable)
        backButton("Projects", in: app).tap()
        XCTAssertTrue(project("orchard", in: app).isHittable)
        project("atlas", in: app).tap()
        XCTAssertTrue(app.staticTexts["Build the dashboard"].waitForExistence(timeout: 5))
        capture("iphone-project-reselected")
    }

    private func project(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "project-\(id)").firstMatch
    }

    /// iOS 27.2 reports bar back buttons as type Other, so match them at any type.
    private func backButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'BackButton' OR label == %@", title)).firstMatch
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
