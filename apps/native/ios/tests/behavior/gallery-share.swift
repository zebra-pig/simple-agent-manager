import XCTest

// Run on a macOS host with GalleryShare.swift. Uses a private temporary folder.
final class GalleryShareTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testShareFilenameKeepsNameAndAddsMissingImageExtension() {
        XCTAssertEqual(galleryShareFilename(filename: "diagram.png", mimeType: "image/png"), "diagram.png")
        XCTAssertEqual(galleryShareFilename(filename: "photo", mimeType: "image/jpeg"), "photo.jpeg")
        XCTAssertEqual(galleryShareFilename(filename: "../../etc/screenshot.webp", mimeType: "image/webp"), "screenshot.webp")
        XCTAssertEqual(galleryShareFilename(filename: "  ", mimeType: "image/png"), "Image.png")
        XCTAssertEqual(galleryShareFilename(filename: "..", mimeType: "image/gif"), "Image.gif")
        XCTAssertEqual(galleryShareFilename(filename: "notes", mimeType: ""), "notes")
    }

    @MainActor func testStoresOriginalBytesOncePerFileAndRemovesThemWithGallery() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = GalleryShareFiles(parent: parent)
        let original = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        await files.store(original, fileId: "a", filename: "same.png", mimeType: "image/png")
        await files.store(Data([9]), fileId: "a", filename: "same.png", mimeType: "image/png")
        await files.store(Data([7]), fileId: "b", filename: "same.png", mimeType: "image/png")
        let a = try XCTUnwrap(files.urls["a"]), b = try XCTUnwrap(files.urls["b"])
        XCTAssertEqual(a.lastPathComponent, "same.png")
        XCTAssertNotEqual(a, b, "Images with the same name must not overwrite each other")
        XCTAssertEqual(try Data(contentsOf: a), original, "The first stored bytes must be shared unchanged")
        XCTAssertEqual(try Data(contentsOf: b), Data([7]))
        XCTAssertTrue(a.path.hasPrefix(files.folder.path))

        files.removeAll()
        XCTAssertTrue(files.urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path))
        await files.store(original, fileId: "c", filename: "late.png", mimeType: "image/png")
        XCTAssertNil(files.urls["c"], "A closed gallery must not publish new files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path), "A closed gallery must not leave files behind")
    }
}
