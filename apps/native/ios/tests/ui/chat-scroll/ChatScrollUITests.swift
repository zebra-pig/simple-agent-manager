import XCTest

final class ChatScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.simpleagentmanager.validation.chat-scroll")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = try request("reset")
    }

    override func tearDownWithError() throws {
        // XCTest's automatic failure artifact is a video on current Xcode.
        // Always attach a still image and the final measured state as well.
        capture("final-" + name)
        // Every frame of every scenario: rows never draw over one another.
        Thread.sleep(forTimeInterval: 0.5)
        if let defects = (try? request("defects"))?["defects"] as? [[String: Any]], !defects.isEmpty {
            XCTFail("\(defects.count) frames drew rows over one another; first: \(defects.prefix(5))")
        }
        if let stats = try? request("stats") { print("CHAT_SCROLL_FINAL_STATS \(stats)") }
        if let trace = try? request("trace"), let samples = trace["samples"] as? [[String: Any]] {
            print("CHAT_SCROLL_FINAL_OFFSETS \(Array(samples.suffix(4)))")
        }
        _ = try request("release-history")
        _ = try request("release-requests")
        app.terminate()
    }

    private func request(_ path: String) throws -> [String: Any] {
        let completed = expectation(description: path)
        var result: Result<Data, Error>!
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:SAM_TEST_PORT/\(path)")!) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data!)
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 5)
        return try JSONSerialization.jsonObject(with: result.get()) as! [String: Any]
    }

    // Wait for delivery through the end of the measured interval, not just an
    // arbitrary sleep. The fixture sends ordered batches without dropping frames.
    private func renderedSamples(after start: Double) throws -> [[String: Any]] {
        let end = Date().timeIntervalSince1970
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let samples = try request("trace?after=\(start)")["samples"] as! [[String: Any]]
            if let latest = samples.last?["time"] as? Double, latest >= end { return samples }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        XCTFail("Render probe did not deliver samples through the measured interval")
        return []
    }

    private var latest: XCUIElement { app.staticTexts["LATEST MESSAGE"] }
    /// The production transcript: an upright collection view.
    private var transcript: XCUIElement { app.collectionViews["chat-transcript"] }
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
            transcript.swipeDown(velocity: .fast)
        }
        XCTFail("Did not load earlier page \(count)")
    }

    private func assertAtLatest() {
        let visible = NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return self.latest.isHittable && !self.jump.isHittable
        }
        let expectation = XCTNSPredicateExpectation(predicate: visible, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 8)
        if result != .completed {
            print("CHAT_SCROLL_BOTTOM_FAILURE latestVisible=\(latest.isHittable) jumpVisible=\(jump.isHittable)")
            capture("bottom-detection-failure")
        }
        XCTAssertEqual(result, .completed, "Latest must be visible and the jump button must disappear")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRowsWithinScreenWidth(_ phase: String, file: StaticString = #filePath, line: UInt = #line) {
        let start = Date().timeIntervalSince1970
        Thread.sleep(forTimeInterval: 0.2)
        guard let sample = (try? renderedSamples(after: start))?.last,
              let width = sample["width"] as? Double, let content = sample["contentWidth"] as? Double,
              let offset = sample["x"] as? Double else {
            return XCTFail("\(phase): no scroll geometry sample", file: file, line: line)
        }
        let geometry = "scroll width \(width), content width \(content), horizontal offset \(offset)"
        let screen = app.windows.firstMatch.frame
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chat-message-' OR identifier BEGINSWITH 'chat-request-'"))
            .allElementsBoundByIndex
        var checked = 0
        for row in rows where row.exists {
            let frame = row.frame
            guard !frame.isEmpty, frame.maxY > screen.minY, frame.minY < screen.maxY else { continue }
            checked += 1
            if frame.minX < screen.minX - 0.5 || frame.maxX > screen.maxX + 0.5 {
                capture("too-wide-\(phase)")
                return XCTFail("\(phase): \(row.identifier) at \(frame) exceeds screen \(screen); \(geometry)", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(checked, 0, "\(phase): no rendered rows were checked", file: file, line: line)
        // The conversation itself must never become horizontally scrollable.
        XCTAssertLessThanOrEqual(content, width + 0.5, "\(phase): \(geometry)", file: file, line: line)
        XCTAssertEqual(offset, 0, accuracy: 0.5, "\(phase): chat is scrolled sideways; \(geometry)", file: file, line: line)
    }

    func testWideContentStaysWithinScreenWidthAcrossRotation() throws {
        _ = try request("reset?wide=true")
        launch()
        assertRowsWithinScreenWidth("portrait")
        for step in 1...3 {
            transcript.swipeDown()
            assertRowsWithinScreenWidth("scrolled-\(step)")
        }
        // A sideways drag must not pan the conversation.
        transcript.swipeLeft()
        assertRowsWithinScreenWidth("swiped-left")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        assertRowsWithinScreenWidth("landscape")
        transcript.swipeUp()
        assertRowsWithinScreenWidth("landscape-scrolled")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1)
        assertRowsWithinScreenWidth("portrait-after-rotation")
        for step in 1...3 {
            transcript.swipeUp()
            assertRowsWithinScreenWidth("portrait-after-rotation-\(step)")
        }
    }

    func testPendingRequestCardKeepsConversationWithinScreenWidth() throws {
        // A long agent reply between images, uploads and a pending request card
        // left the column scrolled sideways on about half of launches.
        for attempt in 1...4 {
            _ = try request("reset?attention=true")
            app.terminate()
            launch()
            XCTAssertTrue(app.buttons["Approved: merge iOS now, Android later"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            assertRowsWithinScreenWidth("launch-\(attempt)")
        }
        // Polling refreshes the card and transcript; the column must not move.
        Thread.sleep(forTimeInterval: 6)
        assertRowsWithinScreenWidth("after-polling")
        transcript.swipeDown()
        assertRowsWithinScreenWidth("scrolled")
        transcript.swipeUp(velocity: .fast)
        assertRowsWithinScreenWidth("returned")
        transcript.swipeLeft()
        assertRowsWithinScreenWidth("swiped-left")
    }

    /// An action in an edit menu (a menu item) or a context menu (a button).
    private func menuAction(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
    }

    /// Taps during a menu's entrance animation are dropped; wait until it settles.
    private func tapWhenSettled(_ element: XCUIElement) {
        var frame = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if element.frame == frame { break }
            frame = element.frame
        }
        element.tap()
    }

    private var composer: XCUIElement {
        let placeholders = ["Reply to the agent…", "Steer the agent…", "Queue next…"]
        return app.textViews.matching(NSPredicate(format: "placeholderValue IN %@ OR label IN %@",
                                                  placeholders, placeholders)).firstMatch
    }

    func testConversationDrawsBehindNavigationBarAndComposer() throws {
        launch()
        let start = Date().timeIntervalSince1970
        Thread.sleep(forTimeInterval: 0.5)
        let sample = try XCTUnwrap(try renderedSamples(after: start).last)
        let windowHeight = try XCTUnwrap(sample["windowHeight"] as? Double)
        let visibleMinY = try XCTUnwrap(sample["visibleMinY"] as? Double)
        let visibleMaxY = try XCTUnwrap(sample["visibleMaxY"] as? Double)
        let navigationBar = app.navigationBars.firstMatch.frame
        let composer = composer.frame
        // An upright scroll view runs on behind both bars, under the system's
        // scroll edge effect; nothing clips it at the navigation bar.
        XCTAssertLessThanOrEqual(visibleMinY, 1, "Chat content is clipped below the top of the window (visible from \(visibleMinY))")
        XCTAssertGreaterThanOrEqual(visibleMaxY, windowHeight - 1,
            "Chat content is clipped above the bottom edge (visible to \(visibleMaxY) of \(windowHeight))")
        // Content may pass behind the bars, but the resting latest row stays readable.
        XCTAssertLessThanOrEqual(latest.frame.maxY, composer.minY, "Latest row rests behind the composer")
        XCTAssertGreaterThanOrEqual(latest.frame.minY, navigationBar.maxY, "Latest row rests behind the navigation bar")
        capture("full-bleed-latest")
    }

    func testPressingAMessageOpensItsCommentMenu() throws {
        launch()
        // Pressing message text selects a word; its edit menu offers Comment.
        latest.press(forDuration: 1.5)
        let comment = menuAction("Comment")
        XCTAssertTrue(comment.waitForExistence(timeout: 10), "Pressing a message did not offer Comment")
        capture("message-menu")
        // Taps during the menu's entrance animation are dropped; wait until it settles.
        var frame = comment.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if comment.frame == frame { break }
            frame = comment.frame
        }
        Thread.sleep(forTimeInterval: 0.5)
        comment.tap()
        XCTAssertTrue(app.navigationBars["New comment"].waitForExistence(timeout: 10),
                      "Choosing Comment did not open the comment sheet for the message")
    }

    func testMessageTextSelectsAWordNotTheWholeMessage() throws {
        launch()
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message ")).allElementsBoundByIndex
            .last { $0.isHittable }
        let message = try XCTUnwrap(row, "No message text on screen")
        // Press the first word, "Message": a range, with the system's handles and menu.
        message.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 12, dy: 8)).press(forDuration: 1.2)
        let copy = menuAction("Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Pressing message text did not select it")
        XCTAssertTrue(menuAction("Comment").exists, "The selection menu does not offer Comment")
        capture("word-selected")
        tapWhenSettled(copy)
        // A selection must not pin, scroll or reload the conversation under it.
        XCTAssertTrue(message.isHittable)
        // Paste into the app's own composer: the copied text is only the word.
        let editor = composer
        editor.tap()
        editor.tap()
        let paste = menuAction("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "The composer offered no Paste")
        tapWhenSettled(paste)
        let pasted = NSPredicate(format: "value == %@", "Message")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pasted, object: editor)], timeout: 5), .completed,
                       "Pasted \(editor.value ?? "nothing") instead of the selected word")
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
        let trace = try renderedSamples(after: beforeTap)
        XCTAssertGreaterThan(trace.count, 3, "Missing rendered animation samples")
        if !(trace.first?["reduceMotion"] as? Bool ?? false) {
            let offsets = trace.compactMap { $0["y"] as? Double }
            let low = offsets.min()!, high = offsets.max()!
            XCTAssertGreaterThan(high - low, 100, "Jump did not animate across the conversation")
            let intermediate = offsets.filter { $0 > low + 10 && $0 < high - 10 }
            // Assert animation, not a minimum frame rate on a shared build host.
            XCTAssertFalse(intermediate.isEmpty, "Jump was instantaneous: no intermediate rendered position")
        }
        let requests = olderRequests
        Thread.sleep(forTimeInterval: 10)
        assertAtLatest()
        XCTAssertEqual(olderRequests, requests, "Jump or polling rearmed the pager")
        capture("multiple-pages-jump-settled")
        // The user can leave the bottom again and make a second explicit jump.
        transcript.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertAtLatest()
    }

    /// The drawn rows on screen, top to bottom, must not overlap.
    private func assertRowsDoNotOverlap(_ phase: String, file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chat-message-'"))
            .allElementsBoundByIndex
            .compactMap { row -> (String, CGRect)? in
                guard row.exists else { return nil }
                let frame = row.frame
                guard !frame.isEmpty, frame.maxY > screen.minY, frame.minY < screen.maxY else { return nil }
                return (row.identifier, frame)
            }
            .sorted { $0.1.minY < $1.1.minY }
        XCTAssertGreaterThan(rows.count, 1, "\(phase): fewer than two rows on screen", file: file, line: line)
        for (upper, lower) in zip(rows, rows.dropFirst()) where lower.1.minY < upper.1.maxY - 1 {
            capture("overlap-\(phase)")
            print("CHAT_SCROLL_ROWS \(phase) \(rows.map { "\($0.0)=\($0.1.minY)...\($0.1.maxY)" })")
            return XCTFail("\(phase): \(upper.0) (\(upper.1.minY)...\(upper.1.maxY)) overlaps \(lower.0) (\(lower.1.minY)...\(lower.1.maxY))",
                           file: file, line: line)
        }
    }

    /// Disclosures on screen: Activity groups, Thinking, and tool Output.
    private var disclosures: [XCUIElement] {
        let screen = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch.frame
        let composer = composer.frame
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity' OR label == 'Thinking' OR label == 'Output'"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame.minY > bar.maxY && $0.frame.maxY < min(composer.minY, screen.maxY) }
    }

    func testExpandingAndCollapsingRowsNeverOverlapsMessages() throws {
        _ = try request("reset?mixed=true")
        launch()
        assertRowsDoNotOverlap("launch")
        // Read further up, where activity, thinking and replies alternate.
        for step in 0..<6 {
            if step > 0 { transcript.swipeDown() }
            Thread.sleep(forTimeInterval: 0.5)
            for (index, _) in disclosures.prefix(3).enumerated() {
                // Expanding moves the rows below; look each one up again.
                guard let disclosure = disclosures[safe: index], disclosure.isHittable else { break }
                let label = disclosure.label
                disclosure.tap()
                Thread.sleep(forTimeInterval: 0.08)
                assertRowsDoNotOverlap("expanding-\(step)-\(label)")
                Thread.sleep(forTimeInterval: 0.6)
                assertRowsDoNotOverlap("expanded-\(step)-\(label)")
            }
            // Toggle again, quickly, while earlier changes may still animate.
            for index in 0..<3 {
                guard let disclosure = disclosures[safe: index], disclosure.isHittable else { break }
                disclosure.tap()
            }
            Thread.sleep(forTimeInterval: 0.08)
            assertRowsDoNotOverlap("collapsing-\(step)")
            Thread.sleep(forTimeInterval: 0.8)
            assertRowsDoNotOverlap("collapsed-\(step)")
        }
        // Polling keeps growing the streamed row near the bottom.
        if jump.waitForExistence(timeout: 2) { jump.tap() }
        assertAtLatest()
        for index in 0..<2 {
            guard let disclosure = disclosures[safe: index], disclosure.isHittable else { break }
            disclosure.tap()
        }
        Thread.sleep(forTimeInterval: 4)
        assertRowsDoNotOverlap("polled-at-latest")
        assertAtLatest()
    }

    func testMixedChatAcrossThreePagesAndRotation() throws {
        _ = try request("reset?mixed=true")
        launch()
        reachOlderPage(1)
        reachOlderPage(2)
        reachOlderPage(3)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertAtLatest()
        let requests = olderRequests
        XCUIDevice.shared.orientation = .landscapeLeft
        assertAtLatest()
        transcript.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertAtLatest()
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 5)
        assertAtLatest()
        XCTAssertEqual(olderRequests, requests)
        capture("mixed-markdown-tools-three-pages-and-rotation")
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
        transcript.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message "))
            .allElementsBoundByIndex.first { $0.isHittable }!
        let label = row.label
        let y = row.frame.minY
        let id = "m-" + label.components(separatedBy: "\n")[0].replacingOccurrences(of: "Message ", with: "")
        let layouts = try request("layout")["samples"] as! [[String: Any]]
        let beforeRows = layouts.last!["rows"] as! [[String: Any]]
        let offset = beforeRows.first { $0["id"] as? String == id }!["y"] as! Double
        let started = Date().timeIntervalSince1970
        capture("older-position-before-polling")
        Thread.sleep(forTimeInterval: 10)
        let retained = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(retained.isHittable)
        XCTAssertEqual(retained.frame.minY, y, accuracy: 1)
        let frames = try renderedSamples(after: started)
        XCTAssertGreaterThan(frames.count, 10)
        for frame in frames {
            let rows = frame["rows"] as! [[String: Any]]
            let reading = rows.first { $0["id"] as? String == id }
            XCTAssertNotNil(reading, "Polling displaced the displayed reading position")
            XCTAssertEqual(reading!["y"] as! Double, offset, accuracy: 1,
                           "Polling shifted a displayed frame before correcting itself")
        }
        XCTAssertTrue(jump.isHittable)
        capture("older-position-after-polling")
        let pollsBeforeJump = try request("stats")["polls"] as! Int
        XCTAssertGreaterThan(pollsBeforeJump, 2, "Live polling must continue while reading history")
        jump.tap()
        assertAtLatest()
        let stream = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming update ")).firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 5))
        let version = Int(stream.label.components(separatedBy: "\n")[0].components(separatedBy: " ").last!)!
        XCTAssertGreaterThanOrEqual(version, pollsBeforeJump - 1, "Returning to latest must flush buffered live content")
        capture("latest-caught-up-after-history-reading")
    }

    func testPrependingHistoryPreservesVisibleMessagePosition() throws {
        _ = try request("reset?hold=true")
        launch()
        reachOlderPage(1)
        Thread.sleep(forTimeInterval: 0.5)
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message "))
            .allElementsBoundByIndex.first { $0.isHittable }!
        let label = row.label
        let y = row.frame.minY
        print("CHAT_SCROLL_PREPEND_BEFORE \(try request("layout"))")
        _ = try request("release-history")
        for _ in 0..<50 {
            if try request("stats")["completedOlder"] as? Int == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let completed = try request("stats")
        XCTAssertEqual(completed["completedOlder"] as? Int, 1)
        XCTAssertEqual(completed["inFlight"] as? Int, 0)
        Thread.sleep(forTimeInterval: 1)
        let retained = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        print("CHAT_SCROLL_PREPEND_AFTER \(try request("layout"))")
        capture("history-prepend-reading-position")
        XCTAssertTrue(retained.isHittable, "Earlier-page insertion displaced the message being read")
        XCTAssertEqual(retained.frame.minY, y, accuracy: 4)
    }

    func testRepeatedPrependDoesNotMoveOrChainHistory() throws {
        try assertRepeatedPrepend(query: "hold=true")
    }

    func testMixedPrependDoesNotMoveOrChainHistory() throws {
        try assertRepeatedPrepend(query: "hold=true&mixed=true")
    }

    private func assertRepeatedPrepend(query: String) throws {
        _ = try request("reset?\(query)")
        launch()
        for page in 1...3 {
            reachOlderPage(page)
            // Allow the finger's momentum and bounce to stop while HTTP waits.
            Thread.sleep(forTimeInterval: 1)
            let beforeLayouts = try request("layout")["samples"] as! [[String: Any]]
            let beforeRows = beforeLayouts.last!["rows"] as! [[String: Any]]
            let reading = beforeRows[0]
            let id = reading["id"] as! String
            let row = app.descendants(matching: .any).matching(identifier: "chat-message-\(id)").firstMatch
            XCTAssertTrue(row.exists, "Missing the visible production message container")
            let y = row.frame.minY
            let offset = reading["y"] as! Double
            capture("page-\(page)-before-prepend")
            let released = Date().timeIntervalSince1970
            _ = try request("release-history")
            for _ in 0..<50 {
                if try request("stats")["completedOlder"] as? Int == page { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let completed = try request("stats")
            XCTAssertEqual(completed["completedOlder"] as? Int, page)
            XCTAssertEqual(completed["inFlight"] as? Int, 0)
            Thread.sleep(forTimeInterval: 1)
            let retained = app.descendants(matching: .any).matching(identifier: "chat-message-\(id)").firstMatch
            capture("page-\(page)-after-prepend")
            let rendered = try renderedSamples(after: released)
            let layouts = try request("layout?after=\(released)")["samples"] as! [[String: Any]]
            print("CHAT_SCROLL_PAGE_\(page) before=\(y) after=\(retained.frame.minY) layouts=\(layouts)")
            XCTAssertFalse(layouts.isEmpty, "No insertion layout samples were captured")
            XCTAssertGreaterThan(rendered.count, 3, "Missing display-link samples during insertion")
            for (index, sample) in rendered.enumerated() {
                let rows = sample["rows"] as! [[String: Any]]
                let reading = rows.first { $0["id"] as? String == id }
                if reading.map({ abs(($0["y"] as! Double) - offset) > 1 }) ?? true {
                    for nearby in rendered[max(0, index - 3)...min(rendered.count - 1, index + 3)] {
                        let summary = (nearby["rows"] as! [[String: Any]]).map { "\($0["id"]!)@\($0["y"]!)" }
                        print("CHAT_SCROLL_NEAR t=\(nearby["time"]!) y=\(nearby["y"]!) h=\(nearby["contentHeight"]!) rows=\(summary)")
                    }
                }
                XCTAssertNotNil(reading, "A displayed frame briefly showed a different page: \(id) at \(offset), frame \(sample)")
                XCTAssertEqual(reading!["y"] as! Double, offset, accuracy: 1,
                               "A displayed frame shifted the reading position")
            }
            XCTAssertTrue(retained.exists)
            XCTAssertEqual(retained.frame.minY, y, accuracy: 1, "Page \(page) shifted the reading position")
            XCTAssertEqual(olderRequests, page, "Insertion alone loaded another page")
            Thread.sleep(forTimeInterval: 2)
            XCTAssertEqual(retained.frame.minY, y, accuracy: 1, "Position drifted after settling")
            XCTAssertEqual(olderRequests, page, "History chained without a new swipe")
            _ = try request("hold-history")
        }
    }

    func testHistoryArrivalDuringScrollDoesNotSwitchPages() throws {
        launch()
        reachOlderPage(1)
        for _ in 0..<50 {
            if try request("stats")["completedOlder"] as? Int == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 1)
        let stats = try request("stats")
        XCTAssertEqual(stats["completedOlder"] as? Int, 1)
        let events = stats["historyEvents"] as! [[String: Any]]
        let event = events[0]
        let started = event["started"] as! Double
        let completed = event["completed"] as! Double
        let frames = try renderedSamples(after: started - 0.2)
        let aroundInsertion = frames.filter { ($0["time"] as! Double) < completed + 0.8 }
        XCTAssertGreaterThan(aroundInsertion.count, 5)
        for (before, after) in zip(aroundInsertion, aroundInsertion.dropFirst()) {
            guard (after["time"] as! Double) - (before["time"] as! Double) < 0.12 else { continue }
            let oldRows = before["rows"] as! [[String: Any]]
            let newRows = after["rows"] as! [[String: Any]]
            guard !oldRows.isEmpty, !newRows.isEmpty else { continue }
            let retained = newRows.filter { row in oldRows.contains { $0["id"] as? String == row["id"] as? String } }
            XCTAssertFalse(retained.isEmpty, "History switched to a different page between displayed frames")
            for row in retained {
                let old = oldRows.first { $0["id"] as? String == row["id"] as? String }!
                XCTAssertLessThan(abs((row["y"] as! Double) - (old["y"] as! Double)), 160,
                                  "History introduced a discontinuity during the swipe")
            }
        }
        XCTAssertEqual(olderRequests, 1, "One swipe chained another page")
        capture("history-arrival-during-real-scroll")
    }

    func testProvisioningProgressAppearsAndDisappearsWhenReady() throws {
        _ = try request("reset?provisioning=true")
        app.launch()
        let first = app.staticTexts["Provisioning VM · 1 of 4"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(first.isHittable)
        capture("provisioning-first-stage")
        for (step, title) in [("workspace_creation", "Cloning repository · 2 of 4"),
                              ("workspace_ready", "Installing dependencies · 3 of 4"),
                              ("agent_session", "Starting agent · 4 of 4")] {
            _ = try request("provisioning?step=\(step)")
            let stage = app.staticTexts[title]
            XCTAssertTrue(stage.waitForExistence(timeout: 12))
            XCTAssertTrue(stage.isHittable)
        }
        capture("provisioning-last-stage")
        _ = try request("provisioning?step=running")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.staticTexts["Starting agent · 4 of 4"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 12), .completed)
        XCTAssertEqual(olderRequests, 0)
    }

    func testRequestCardsWaitForStatusAndResolvedOnesNeverAppear() throws {
        // Hold every request read so the pre-load state stays on screen.
        _ = try request("reset?requests=true&holdRequests=true")
        launch()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat-request-'"))
        let deadline = Date().addingTimeInterval(10)
        while (try request("stats")["requestLoads"] as! Int) < 3 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThanOrEqual(try (request("stats")["requestLoads"] as! Int), 3, "Chat did not read its three requests")
        XCTAssertEqual(cards.count, 0, "A card appeared before its status was known")
        XCTAssertFalse(app.buttons["Refresh"].exists, "An empty request card was shown while loading")
        capture("requests-loading")

        _ = try request("release-requests")
        let open = app.descendants(matching: .any)["chat-request-open-1"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Question open-1"].exists)
        XCTAssertEqual(cards.count, 1, "Only the open request may be shown")
        XCTAssertFalse(app.staticTexts["Question done-1"].exists)
        XCTAssertFalse(app.staticTexts["Question done-2"].exists)
        capture("requests-loaded")
    }

    func testHistoryCompletionDuringAnimatedJumpDoesNotRestoreTop() throws {
        _ = try request("reset?hold=true")
        launch()
        reachOlderPage(1)
        // Leave and reenter the pager while its first request is held, recording
        // a pending entry. Then release it from rendered animation samples.
        transcript.swipeUp()
        for _ in 0..<4 { transcript.swipeDown(velocity: .fast) }
        XCTAssertEqual(try request("stats")["inFlight"] as? Int, 1)
        _ = try request("release-on-scroll")
        jump.tap()
        assertAtLatest()
        Thread.sleep(forTimeInterval: 10)
        assertAtLatest()
        let stats = try request("stats")
        XCTAssertEqual(stats["releasedDuringJump"] as? Bool, true)
        XCTAssertGreaterThan(stats["releaseDistance"] as? Double ?? 0, 50,
                             "History must complete during movement, before reaching the bottom")
        XCTAssertGreaterThan(stats["completionDistance"] as? Double ?? 0, 50,
                             "The response must finish before the jump settles")
        XCTAssertEqual(stats["older"] as? Int, 1, "A canceled pager entry started another request")
        XCTAssertEqual(stats["completedOlder"] as? Int, 1)
        XCTAssertEqual(stats["inFlight"] as? Int, 0)
        capture("history-completion-during-jump")
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
