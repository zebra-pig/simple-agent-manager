import XCTest

final class ChatScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.simpleagentmanager.validation.scroll")
        app.terminate()
        _ = try request("reset")
    }

    override func tearDownWithError() throws {
        _ = try request("release-history")
        app.terminate()
    }

    private func request(_ path: String) throws -> [String: Any] {
        let completed = expectation(description: path)
        var result: Result<Data, Error>!
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:18874/\(path)")!) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data!)
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 5)
        return try JSONSerialization.jsonObject(with: result.get()) as! [String: Any]
    }

    private var latest: XCUIElement { app.staticTexts["LATEST MESSAGE"] }
    private var jump: XCUIElement { app.buttons["Jump to latest"] }
    private var olderRequests: Int { (try! request("stats"))["older"] as! Int }

    private func launch() {
        app.launch()
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        XCTAssertTrue(latest.isHittable)
    }

    private func reachOlderPage(_ count: Int) {
        // Real touch gestures trigger the production pager and HTTP request.
        for _ in 0..<50 {
            if olderRequests >= count { return }
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        }
        XCTFail("Did not load earlier page \(count)")
    }

    private func assertAtLatest() {
        let visible = NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return self.latest.isHittable && !self.jump.isHittable
        }
        expectation(for: visible, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(jump.isHittable)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOpeningAndPollingAtBottomDoesNotDrainHistory() throws {
        launch()
        // Two production poll cycles, including changing message height.
        Thread.sleep(forTimeInterval: 10)
        XCTAssertEqual(olderRequests, 0, "Offscreen pager started a history loop")
        assertAtLatest()
        capture("initial-bottom-after-polling")
    }

    func testActualJumpAfterMultiplePagesStaysAtBottom() throws {
        launch()
        reachOlderPage(1)
        reachOlderPage(2)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let beforeTap = Date().timeIntervalSince1970
        jump.tap()
        assertAtLatest()
        Thread.sleep(forTimeInterval: 0.3)
        let trace = try request("trace?after=\(beforeTap)")["samples"] as! [[String: Any]]
        XCTAssertGreaterThan(trace.count, 3, "Missing rendered animation samples")
        if !(trace.first?["reduceMotion"] as? Bool ?? false) {
            let offsets = trace.compactMap { $0["y"] as? Double }
            let low = offsets.min()!, high = offsets.max()!
            XCTAssertGreaterThan(high - low, 100, "Jump did not animate across the conversation")
            XCTAssertGreaterThan(Set(offsets.filter { $0 > low + 10 && $0 < high - 10 }.map { Int($0) }).count, 2,
                                 "No intermediate animation frames: jump was instantaneous")
        }
        let requests = olderRequests
        Thread.sleep(forTimeInterval: 10)
        assertAtLatest()
        XCTAssertEqual(olderRequests, requests, "Jump or polling rearmed the pager")
        capture("multiple-pages-jump-settled")
        // The user can leave the bottom again and make a second explicit jump.
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertAtLatest()
    }

    func testRepeatedTopToBottomJumps() throws {
        launch()
        for page in 1...4 {
            reachOlderPage(page)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            jump.tap()
            assertAtLatest()
            let requests = olderRequests
            Thread.sleep(forTimeInterval: 1)
            assertAtLatest()
            XCTAssertEqual(olderRequests, requests, "History kept loading after jump \(page)")
        }
        capture("four-repeated-history-jumps")
    }

    func testPollingDoesNotPullAnOlderReadingPositionToBottom() throws {
        launch()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message "))
            .allElementsBoundByIndex.first { $0.isHittable }!
        let label = row.label
        let y = row.frame.minY
        Thread.sleep(forTimeInterval: 10)
        let retained = app.staticTexts[label]
        XCTAssertTrue(retained.isHittable)
        XCTAssertEqual(retained.frame.minY, y, accuracy: 4)
        XCTAssertTrue(jump.isHittable)
        capture("older-position-after-polling")
    }

    func testScrollToTopThenTapJumpBeforeHistoryReturns() throws {
        // Hold the real older-history HTTP response until after the actual
        // button tap. This reproduces the user's top -> down-arrow sequence
        // deterministically, rather than hoping a delay overlaps the tap.
        _ = try request("reset?hold=true")
        launch()
        reachOlderPage(1)
        XCTAssertEqual(try request("stats")["inFlight"] as? Int, 1)
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertAtLatest()
        _ = try request("release-history")
        Thread.sleep(forTimeInterval: 10)
        assertAtLatest()
        let stats = try request("stats")
        XCTAssertEqual(stats["older"] as? Int, 1)
        XCTAssertEqual(stats["completedOlder"] as? Int, 1)
        XCTAssertEqual(stats["inFlight"] as? Int, 0)
        capture("top-then-jump-before-history-returns")
    }
}
