import XCTest

/// The session tools that used to open web — Related, Automation, Comments,
/// Share, Report, Retry and Fork — driven through the production ChatView menu
/// against a loopback server. Each mutation asserts the exact request sent.
final class SessionToolsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.simpleagentmanager.validation.session-tools")
        app.terminate()
        _ = try request("reset")
        app.launch()
        XCTAssertTrue(app.staticTexts["The login session expires after an hour. Please fix the token refresh."].waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: Helpers

    private func request(_ path: String) throws -> [String: Any] {
        let done = expectation(description: path)
        var result: Result<Data, Error>!
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:SAM_TEST_PORT/test/\(path)")!) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data!)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try JSONSerialization.jsonObject(with: result.get()) as! [String: Any]
    }

    /// Mutations the app sent, as (method path, body), waiting until `count` arrived.
    private func calls(atLeast count: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [(String, [String: Any]?)] {
        let deadline = Date().addingTimeInterval(10)
        while true {
            let rows = (try request("calls")["calls"] as! [[String: Any]]).map {
                ("\($0["method"]!) \($0["path"]!)", $0["body"] as? [String: Any])
            }
            if rows.count >= count || Date() > deadline {
                XCTAssertGreaterThanOrEqual(rows.count, count, "\(rows)", file: file, line: line)
                return rows
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTool(_ title: String) {
        app.buttons["Session tools"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) is in the Session tools menu")
        item.tap()
    }

    private func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)", file: file, line: line)
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func textContaining(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    // MARK: Tests

    func testMenuOpensEveryToolNativelyWithoutWebMarkers() throws {
        app.buttons["Session tools"].tap()
        for title in ["Related", "Automation", "Comments", "Share", "Retry", "Fork", "Report"] {
            waitFor(app.buttons[title], 5)
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "(web)")).count, 0)
        screenshot("01-session-tools-menu")
    }

    func testRelatedListsIdeasFilesAndPullRequests() throws {
        openTool("Related")
        waitFor(text("Silent session renewal"))
        XCTAssertTrue(text("Working on · Edited").exists)
        XCTAssertTrue(text("auth-flow.md").exists)
        XCTAssertTrue(text("Retry token refresh after 401").exists)
        XCTAssertTrue(text("#42 · Checks failing").exists)
        XCTAssertTrue(text("Merged").exists)
        screenshot("02-related")
    }

    func testAutomationStopsAWaitAndSchedulesAReminder() throws {
        openTool("Automation")
        let ci = text("This chat is waiting for CI to finish on PR #42")
        waitFor(ci)
        XCTAssertTrue(text("This chat is waiting for a PR review on PR #42").exists)
        XCTAssertFalse(textContaining("agent-dm").exists, "SAM relays stay hidden by default")
        XCTAssertTrue(text("Check whether CI is green again").exists)
        XCTAssertTrue(text("When someone comments on an issue or PR").exists)
        screenshot("03-automation")

        ci.press(forDuration: 1.0)
        app.buttons["Stop waiting"].firstMatch.tap()
        let reason = app.alerts.textFields.firstMatch
        waitFor(reason)
        reason.typeText("PR merged")
        app.alerts.buttons["Stop waiting"].tap()
        var sent = try calls(atLeast: 1)
        XCTAssertEqual(sent[0].0, "POST /api/projects/p/event-subscriptions/w-ci/cancel")
        XCTAssertEqual(sent[0].1?["reason"] as? String, "PR merged")
        XCTAssertTrue(ci.waitForNonExistence(timeout: 10), "the stopped wait disappears after reload")

        app.buttons["Remind this chat later"].tap()
        let prompt = app.textFields["What should the agent do?"]
        waitFor(prompt)
        prompt.tap()
        prompt.typeText("Check whether the PR was reviewed")
        screenshot("04-automation-reminder")
        app.buttons["Save"].tap()
        sent = try calls(atLeast: 2)
        XCTAssertEqual(sent[1].0, "POST /api/projects/p/schedules")
        let action = sent[1].1?["action"] as? [String: Any]
        XCTAssertEqual(action?["kind"] as? String, "message_session")
        XCTAssertEqual(action?["sessionId"] as? String, "s")
        XCTAssertEqual(action?["prompt"] as? String, "Check whether the PR was reviewed")
        XCTAssertNotNil(sent[1].1?["idempotencyKey"] as? String)
        XCTAssertGreaterThan(sent[1].1?["dueAt"] as? Double ?? 0, Date().timeIntervalSince1970 * 1000)
    }

    func testCommentsInboxRepliesAndSendsToTheAgent() throws {
        openTool("Comments")
        // Opens on "Needs you": Bo's question is waiting for the viewer.
        let question = text("Should this also cover expired refresh tokens?")
        waitFor(question)
        XCTAssertFalse(text("Looks good.").exists, "resolved threads are outside the Needs you filter")
        screenshot("05-comments-inbox")
        question.tap()
        waitFor(text("Bo Lindqvist"))
        let field = app.textFields["Reply…"]
        waitFor(field)
        field.tap()
        field.typeText("Yes, please include them.")
        app.buttons["Send to agent"].firstMatch.tap()
        screenshot("06-comment-thread")
        app.buttons["Reply & send"].tap()
        let sent = try calls(atLeast: 2)
        XCTAssertEqual(sent[0].0, "POST /api/projects/p/sessions/s/comments/t-review/replies")
        XCTAssertEqual(sent[0].1?["body"] as? String, "Yes, please include them.")
        XCTAssertEqual(sent[1].0, "POST /api/projects/p/sessions/s/comments/t-review/send")
        XCTAssertEqual(sent[1].1?["body"] as? String, "Yes, please include them.")
        waitFor(text("Yes, please include them."))
    }

    func testCommentingOnAMessageFromItsMenu() throws {
        let message = text("The login session expires after an hour. Please fix the token refresh.")
        // Pressing the text selects a word; its edit menu leads with Comment.
        message.press(forDuration: 1.2)
        let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
            "Comment", XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        waitFor(comment, 5)
        // Taps during the menu's entrance animation are dropped; wait until it settles.
        var frame = comment.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if comment.frame == frame { break }
            frame = comment.frame
        }
        comment.tap()
        let field = app.textFields["Add a comment…"]
        waitFor(field)
        field.tap()
        field.typeText("Also check the mobile client.")
        screenshot("07-new-comment")
        app.buttons["Comment"].tap()
        let sent = try calls(atLeast: 1)
        XCTAssertEqual(sent[0].0, "POST /api/projects/p/sessions/s/comments")
        XCTAssertEqual(sent[0].1?["messageId"] as? String, "u1")
        XCTAssertEqual(sent[0].1?["body"] as? String, "Also check the mobile client.")
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "the composer closes once saved")
    }

    func testShareRequiresDurationAndConsent() throws {
        openTool("Share")
        waitFor(text("Bo Lindqvist"))
        XCTAssertTrue(text("Owner").exists)
        XCTAssertFalse(text("Vic Reader").exists, "project viewers cannot be added")
        screenshot("08-share")
        text("Ana Souza").tap()
        // The pushed screen's back button is also labelled "Share".
        let share = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Share' AND identifier != 'BackButton'")).firstMatch
        waitFor(share)
        XCTAssertFalse(share.isEnabled, "no duration and no acknowledgement yet")
        // The form builds rows lazily; on shorter screens the duration is below the warnings.
        let thirty = app.buttons["30 min"]
        for _ in 0..<4 where !(thirty.exists && thirty.isHittable) { app.swipeUp() }
        thirty.tap()
        XCTAssertFalse(share.isEnabled, "the acknowledgement is required")
        let consent = app.switches.firstMatch
        for _ in 0..<4 where !consent.isHittable { app.swipeUp() }
        consent.tap()
        if consent.value as? String != "1" { consent.switches.firstMatch.tap() }
        screenshot("09-share-confirm")
        XCTAssertTrue(share.isEnabled)
        share.tap()
        let sent = try calls(atLeast: 1)
        XCTAssertEqual(sent[0].0, "POST /api/projects/p/sessions/s/access/grants")
        XCTAssertEqual(sent[0].1?["userId"] as? String, "ana")
        XCTAssertEqual(sent[0].1?["durationMinutes"] as? Int, 30)
        XCTAssertEqual(sent[0].1?["acknowledgeSharedCredentials"] as? Bool, true)
        waitFor(textContaining("can use this chat until"))
    }

    func testRetryPrefillsTheOriginalPromptAndSubmitsWithTheParentTask() throws {
        openTool("Retry")
        waitFor(textContaining("Retrying: Fix login token refresh"))
        XCTAssertTrue(textContaining("sam/fix-login-refresh").exists)
        let prompt = app.textViews["Describe the task to retry…"]
        waitFor(prompt)
        let deadline = Date().addingTimeInterval(10)
        while (prompt.value as? String)?.contains("survive past one hour") != true && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(prompt.value as? String, "Fix the login token refresh so sessions survive past one hour.")
        screenshot("10-retry")
        app.buttons["Send"].tap()
        let sent = try calls(atLeast: 1)
        XCTAssertEqual(sent[0].0, "POST /api/projects/p/tasks/submit")
        XCTAssertEqual(sent[0].1?["parentTaskId"] as? String, "t")
        XCTAssertEqual(sent[0].1?["message"] as? String, "Fix the login token refresh so sessions survive past one hour.")
        XCTAssertEqual(sent[0].1?["agentProfileId"] as? String, "prof")
    }

    func testForkPrefillsTheBriefingWithParentIds() throws {
        openTool("Fork")
        waitFor(textContaining("Forking from: Fix login token refresh"))
        let prompt = app.textViews["Describe what to do next…"]
        waitFor(prompt)
        let deadline = Date().addingTimeInterval(10)
        while (prompt.value as? String)?.contains("Parent task ID: t") != true && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue((prompt.value as? String)?.contains("Previous session: \"Fix login token refresh\"\nParent project ID: p\nParent session ID: s\nParent task ID: t") == true,
                      "\(prompt.value ?? "nil")")
        screenshot("11-fork")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(try calls(atLeast: 0).count, 0, "cancelling sends nothing")
    }

    func testReportAttachesReferencesOnlyWithConsent() throws {
        openTool("Report")
        let title = app.textFields["Brief summary of the issue"]
        waitFor(title)
        title.tap()
        title.typeText("Session menu froze")
        let details = app.textFields["What happened? What did you expect?"]
        details.tap()
        details.typeText("The menu stopped responding after a retry.")
        app.switches.firstMatch.tap()
        if app.switches.firstMatch.value as? String != "1" { app.switches.firstMatch.switches.firstMatch.tap() }
        waitFor(text("Chat session"))
        screenshot("12-report")
        app.buttons["Submit"].tap()
        waitFor(text("Report submitted"))
        let sent = try calls(atLeast: 1)
        XCTAssertEqual(sent[0].0, "POST /api/report-issue")
        XCTAssertEqual(sent[0].1?["title"] as? String, "Session menu froze")
        XCTAssertEqual(sent[0].1?["consentToAttachRefs"] as? Bool, true)
        XCTAssertEqual((sent[0].1?["refs"] as? [String: Any])?["sessionId"] as? String, "s")
        screenshot("13-report-submitted")
    }
}
