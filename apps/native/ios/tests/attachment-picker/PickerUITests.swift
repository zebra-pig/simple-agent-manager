import XCTest

final class PickerUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRepeatedPickerPresentation() {
        let app = XCUIApplication()
        app.launch()
        for project in [false, true] {
            if project { app.switches["New task layout"].tap() }
            for keyboard in [false, true] {
                for round in 0..<3 {
                    for source in ["Photo Library", "Choose Files…"] {
                        if keyboard { app.textViews.firstMatch.tap() }
                        app.buttons["Attach files"].tap()
                        let choice = app.buttons[source]
                        XCTAssertTrue(choice.waitForExistence(timeout: 3), "Source chooser missing")
                        if round == 0 {
                            let chooser = XCTAttachment(screenshot: app.screenshot())
                            chooser.name = "source-chooser"
                            chooser.lifetime = .keepAlways
                            add(chooser)
                        }
                        choice.tap()
                        // System picker controls appear in the app accessibility tree.
                        let cancel = app.buttons["Cancel"].firstMatch
                        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "\(source) did not open (project=\(project), keyboard=\(keyboard), round=\(round))")
                        if source == "Photo Library" {
                            XCTAssertTrue(photo(in: app).waitForExistence(timeout: 30))
                        } else {
                            XCTAssertTrue(app.buttons["Browse"].waitForExistence(timeout: 15))
                        }
                        let shot = XCTAttachment(screenshot: app.screenshot())
                        shot.name = "\(project ? "task" : "chat")-\(keyboard)-\(round)-\(source)"
                        shot.lifetime = .keepAlways
                        add(shot)
                        cancel.tap()
                        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
                        XCTAssertTrue(app.buttons["Attach files"].waitForExistence(timeout: 3))
                    }
                }
            }
        }
    }

    private func photo(in app: XCUIApplication) -> XCUIElement {
        app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
    }

    func testFileSelection() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Attach files"].tap()
        app.buttons["Choose Files…"].tap()
        let browse = app.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15))
        browse.tap()
        let phone = app.staticTexts["On My iPhone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        app.staticTexts["PickerFixture"].tap()
        app.staticTexts["picker-check"].tap()
        app.buttons["Open"].tap()
        let picked = app.staticTexts["picked-file"]
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        XCTAssertEqual(picked.label, "picker-check.txt")
    }

    func testPhotoSelection() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Attach files"].tap()
        app.buttons["Photo Library"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15))
        let selectedPhoto = photo(in: app)
        XCTAssertTrue(selectedPhoto.waitForExistence(timeout: 30))
        selectedPhoto.tap()
        app.buttons["Add"].tap()
        let picked = app.staticTexts["picked-file"]
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        XCTAssertTrue(picked.label.hasPrefix("Photo-"))
    }

    func testDismissSourceChooserDoesNotOpenPicker() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Attach files"].tap()
        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 3))
        let row = app.buttons["Photo Library"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Attach files"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Cancel"].exists)
        app.buttons["Attach files"].tap()
        app.buttons["Choose Files…"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15))
    }
}
