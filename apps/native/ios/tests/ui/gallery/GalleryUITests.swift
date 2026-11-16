import XCTest

final class GalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.simpleagentmanager.validation.gallery")
        app.terminate()
        _ = try request("reset?mode=held")
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "gallery-without-page-indicator"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        _ = try? request("release?before=70")
        _ = try? request("release?before=40")
        app.terminate()
    }

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

    private func assertImage(_ number: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["\(number).png"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.staticTexts["Finding earlier images…"].exists, file: file, line: line)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ of [0-9]+( loaded)?$")).count, 0, file: file, line: line)
    }

    func testLoadedImagesRemainSwipeableWhileOlderHistoryIsHeld() throws {
        app.launch()
        let image = app.buttons["7.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        image.tap()
        assertImage(7)
        // Exact reported case: only two images, an unfinished history request,
        // and real left/right swipes that must work before releasing it.
        app.swipeLeft(); assertImage(8)
        app.swipeRight(); assertImage(7)
        app.swipeLeft(); assertImage(8)
        let pending = try request("stats")
        XCTAssertFalse((pending["reads"] as! [String]).isEmpty)
        XCTAssertTrue((pending["completed"] as! [String]).isEmpty)

        _ = try request("release?before=70&delay=0.25")
        app.swipeRight(); assertImage(7) // Insert earlier pages during this swipe.
        var finished = false
        for _ in 0..<50 {
            if (try request("stats")["completed"] as! [String]).contains(where: { $0.hasPrefix("[70,") }) { finished = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(finished)
        assertImage(7) // Prepending must preserve the displayed file.
        app.swipeLeft(); assertImage(8)
        app.swipeRight(); assertImage(7)
        app.swipeRight(); assertImage(6)
        app.swipeRight(); assertImage(5)
        app.swipeRight(); assertImage(4) // Demand the next batch.
        app.swipeLeft(); assertImage(5)
        app.swipeLeft(); assertImage(6)
        app.swipeLeft(); assertImage(7)
        app.swipeLeft(); assertImage(8)
        let nextPending = try request("stats")
        XCTAssertTrue((nextPending["reads"] as! [String]).contains { $0.hasPrefix("[40,") })
        XCTAssertTrue((nextPending["completed"] as! [String]).allSatisfy { $0.hasPrefix("[70,") })
        _ = try request("release?before=40")
        // Existing images remain browsable while the final batch arrives.
        app.swipeRight(); assertImage(7)
        app.swipeLeft(); assertImage(8)
        for _ in 0..<2 {
            for number in stride(from: 7, through: 1, by: -1) {
                app.swipeRight(); assertImage(number)
            }
            app.swipeRight(); assertImage(1)
            for number in 2...8 { app.swipeLeft(); assertImage(number) }
            app.swipeLeft(); assertImage(8)
        }
        app.buttons["Done"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap(); assertImage(7)
        app.swipeLeft(); assertImage(8)
    }
}
