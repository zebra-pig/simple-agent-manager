// Files for the next message: picked with the composer's attach button (Files,
// Photos) or dropped onto the composer. The shell only turns each into a name,
// a type, a size and an AttachmentSource; the core checks the limits, reads the
// file off the main thread, uploads it and reports progress in its state.

import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the composer needs to show and change a view model's attachments.
struct ComposerFiles {
    let items: [Attachment]
    let add: (_ filename: String, _ contentType: String, _ size: UInt64, _ source: AttachmentSource) -> Void
    let remove: (_ id: String) -> Void

    var ready: Bool { items.allSatisfy { if case .ready = $0.status { true } else { false } } }
}

// MARK: - Sources

/// A file on disk. `scoped` for URLs from the file importer (security-scoped);
/// `temporary` for our own copies, deleted once read.
final class FileSource: AttachmentSource, @unchecked Sendable {
    private let url: URL
    private let scoped: Bool
    private let temporary: Bool

    init(url: URL, scoped: Bool, temporary: Bool = false) {
        self.url = url
        self.scoped = scoped
        self.temporary = temporary
    }

    func read() -> Data? {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        return try? Data(contentsOf: url)
    }
}

/// Bytes already in memory (a photo).
final class DataSource: AttachmentSource, @unchecked Sendable {
    private let data: Data
    init(_ data: Data) { self.data = data }
    func read() -> Data? { data }
}

// MARK: - Turning picks and drops into attachments

enum AttachmentIntake {
    /// Files from the file importer.
    static func add(urls: [URL], to files: ComposerFiles) {
        for url in urls { add(url: url, scoped: true, to: files) }
    }

    static func add(url: URL, scoped: Bool, temporary: Bool = false, name: String? = nil, to files: ComposerFiles) {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if accessing { url.stopAccessingSecurityScopedResource() }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        files.add(
            name ?? url.lastPathComponent,
            type?.preferredMIMEType ?? "",
            UInt64(max(values?.fileSize ?? 0, 0)),
            FileSource(url: url, scoped: scoped, temporary: temporary)
        )
    }

    /// Photos from the photo picker. HEIC goes out as JPEG, which agents can read.
    static func add(photos: [PhotosPickerItem], to files: ComposerFiles) async {
        let stamp = photoStamp.string(from: .now)
        for (index, item) in photos.enumerated() {
            guard var data = try? await item.loadTransferable(type: Data.self) else { continue }
            var type = item.supportedContentTypes.first ?? .data
            if type.conforms(to: .heic) || type.conforms(to: .heif), let jpeg = jpegData(from: data) {
                data = jpeg
                type = .jpeg
            }
            let ext = type.preferredFilenameExtension ?? "bin"
            let suffix = photos.count > 1 ? "-\(index + 1)" : ""
            files.add("Photo-\(stamp)\(suffix).\(ext)", type.preferredMIMEType ?? "", UInt64(data.count), DataSource(data))
        }
    }

    private static let photoStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Whether a dragged item is a file (and not, say, selected text, which the
    /// text field takes).
    static func isFile(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.suggestedName != nil
            || provider.registeredContentTypes.contains { type in
                [UTType.image, .audiovisualContent, .pdf, .archive].contains { type.conforms(to: $0) }
            }
    }

    /// Items dropped on the composer.
    static func add(providers: [NSItemProvider], to files: ComposerFiles) {
        for provider in providers where isFile(provider) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Finder and the Files app: a URL the drop gives us access to.
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { AttachmentIntake.add(url: url, scoped: true, to: files) }
                }
                continue
            }
            // Anything else (a photo from Photos, an image from Safari): its file
            // representation, copied before the provider deletes it.
            // HEIC last: agents read JPEG and PNG.
            let types = provider.registeredContentTypes.filter { $0.conforms(to: .data) || $0.conforms(to: .content) }
            let type = types.first { !$0.conforms(to: .heic) && !$0.conforms(to: .heif) } ?? types.first
            guard let type else { continue }
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let copy = AttachmentIntake.temporaryCopy(of: url) else { return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension ?? url.pathExtension.nonEmpty {
                    name += ".\(ext)"
                }
                DispatchQueue.main.async { AttachmentIntake.add(url: copy, scoped: false, temporary: true, name: name, to: files) }
            }
        }
    }

    /// `url` copied into a folder of its own in the temporary directory.
    private static func temporaryCopy(of url: URL) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        options[kCGImagePropertyOrientation] = properties[kCGImagePropertyOrientation]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Views

/// The paperclip in the composer: a file, or a photo from the library.
struct AttachButton: View {
    let files: ComposerFiles
    @State private var importing = false
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        // Keep both pickers on a persistent host outside Menu so dismissing
        // the transient menu does not remove their presentation context.
        HStack(spacing: 0) {
            Menu {
                Button("Choose Files…", systemImage: "folder") { importing = true }
                Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            } label: {
                Image(systemName: "paperclip")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .menuIndicator(.hidden)
            .glassButton()
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Attach files"))
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { AttachmentIntake.add(urls: urls, to: files) }
        }
        .onChange(of: photos) {
            let picked = photos
            guard !picked.isEmpty else { return }
            photos = []
            Task { await AttachmentIntake.add(photos: picked, to: files) }
        }
    }
}

/// The attached files, above the text field.
struct AttachmentStrip: View {
    let files: ComposerFiles

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files.items, id: \.id) { attachment in
                    AttachmentChip(attachment: attachment) { files.remove(attachment.id) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch attachment.status {
                case .uploading: ProgressView().controlSize(.small)
                case .ready: Image(systemName: icon).foregroundStyle(.secondary)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case let .failed(error) = attachment.status {
                    Text(error.message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(verbatim: fileSize(attachment.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 180, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(attachment.filename)"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var icon: String {
        let type = UTType(mimeType: attachment.contentType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .audiovisualContent) == true { return "film" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }
}

/// Files dropped anywhere on the composer are attached; text keeps going to
/// the text field.
struct AttachmentDrop: DropDelegate {
    let files: ComposerFiles
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [.item]).contains(where: AttachmentIntake.isFile)
    }

    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        AttachmentIntake.add(providers: info.itemProviders(for: [.item]), to: files)
        return true
    }
}
