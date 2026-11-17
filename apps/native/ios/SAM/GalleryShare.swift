import Foundation
import Observation
import UniformTypeIdentifiers

/// Original gallery image bytes, written once per file so the system share sheet
/// receives the uploaded file's name and type rather than a re-encoded preview.
/// Files live in a private temporary folder that is removed with the gallery.
@MainActor @Observable final class GalleryShareFiles {
    private(set) var urls: [String: URL] = [:]
    @ObservationIgnored let folder: URL
    @ObservationIgnored private var closed = false

    init(parent: URL = FileManager.default.temporaryDirectory) {
        folder = parent.appendingPathComponent("gallery-share-\(UUID().uuidString)", isDirectory: true)
    }

    func store(_ bytes: Data, fileId: String, filename: String, mimeType: String) async {
        guard !closed, !fileId.isEmpty, urls[fileId] == nil else { return }
        // A folder per file keeps two images with the same name distinct.
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(galleryShareFilename(filename: filename, mimeType: mimeType))
        let written = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                return true
            } catch { return false }
        }.value
        // The gallery may have closed, or another page stored it, during the write.
        guard written, !closed, urls[fileId] == nil else {
            try? FileManager.default.removeItem(at: directory); return
        }
        urls[fileId] = url
    }

    func removeAll() {
        closed = true; urls = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A safe single path component that keeps the original name and adds the
/// extension implied by the MIME type when the name has none, so receivers such
/// as Photos recognize the file as an image.
func galleryShareFilename(filename: String, mimeType: String) -> String {
    var name = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name == "." || name == ".." || name == "/" { name = String(localized: "Image") }
    if (name as NSString).pathExtension.isEmpty,
       let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension {
        name += ".\(ext)"
    }
    return name
}
