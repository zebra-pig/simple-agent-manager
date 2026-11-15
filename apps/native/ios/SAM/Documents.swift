import SwiftUI
import QuickLook
import ImageIO
import UniformTypeIdentifiers

extension ChatDocument {
    var isImage: Bool { mimeType != "image/svg+xml" && (filename as NSString).pathExtension.lowercased() != "svg" && (UTType(mimeType: mimeType)?.conforms(to: .image) == true || UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: .image) == true) }
    var label: String { filename.isEmpty ? String(localized: "File") : filename }
}

struct DocumentCard: View {
    let document: ChatDocument
    let documents: [ChatDocument]
    let core: ChatViewModel
    @State private var image: Image?
    @State private var gallery = false
    @State private var preview: URL?
    @State private var folder: URL?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button {
            if document.isImage { gallery = true }
            else { Task { await openFile() } }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if document.isImage, let image {
                    image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: document.isImage ? "photo.on.rectangle" : "doc") }
                    Text(verbatim: document.label).lineLimit(2)
                }.font(.callout)
                if !document.caption.isEmpty { Text(verbatim: document.caption).font(.caption).foregroundStyle(.secondary) }
                if let size = document.sizeBytes { Text(verbatim: fileSize(size)).font(.caption2).foregroundStyle(.secondary) }
                if document.unavailable { Text("File no longer available").font(.caption).foregroundStyle(.secondary) }
                else if document.fileId.isEmpty { Text("Preparing file…").font(.caption).foregroundStyle(.secondary) }
                else if failed { Text("File unavailable. Tap to retry.").font(.caption).foregroundStyle(.secondary) }
                else { Text(document.isImage ? String(localized: "Open gallery") : String(localized: "Open file")).font(.caption2).foregroundStyle(.secondary) }
            }.padding(10).frame(maxWidth: 260, alignment: .leading)
                .glass(in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(document.unavailable || document.fileId.isEmpty || loading)
        .accessibilityHint(Text(document.isImage ? "Open gallery" : "Open file"))
        .task(id: document.fileId) {
            if document.isImage && !document.unavailable, let bytes = await core.documentBytes(fileId: document.fileId) { image = platformImage(bytes, maxPixelSize: 440) }
        }
        .sheet(isPresented: $gallery) { DocumentGallery(documents: documents.filter { $0.isImage && !$0.unavailable && !$0.fileId.isEmpty }, initial: document.fileId, core: core) }
        .quickLookPreview($preview)
        .onChange(of: preview) { if preview == nil { cleanUp() } }
        .onDisappear { cleanUp() }
    }

    private func cleanUp() { if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil }
    @MainActor private func openFile() async {
        loading = true; failed = false
        defer { loading = false }
        guard let bytes = await core.documentBytes(fileId: document.fileId) else { failed = true; return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = (document.label as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name == "." || name == ".." ? "File" : name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: url)
            cleanUp(); folder = dir; preview = url
        } catch { try? FileManager.default.removeItem(at: dir); failed = true }
    }
}

struct DocumentGallery: View {
    let documents: [ChatDocument]
    let initial: String
    let core: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var image: Image?
    @State private var failed = false
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            if !documents.isEmpty {
                let selected = min(index, documents.count - 1)
                let document = documents[selected]
                VStack(spacing: 12) {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Group {
                                if let image {
                                    image.resizable().scaledToFit()
                                        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                                        .gesture(MagnificationGesture().onChanged { scale = min(max($0, 1), 4) })
                                        .onTapGesture(count: 2) { scale = scale == 1 ? 2 : 1 }
                                } else if failed {
                                    Button("Retry") { Task { await load(document) } }
                                } else { ProgressView() }
                            }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !document.caption.isEmpty { Text(verbatim: document.caption).font(.caption) }
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { index = selected - 1 }.disabled(selected == 0)
                        Spacer()
                        Text("\(selected + 1) of \(documents.count)").font(.caption)
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { index = selected + 1 }.disabled(selected + 1 == documents.count)
                    }.padding()
                }
                .navigationTitle(document.label)
                .toolbar { Button("Done") { dismiss() } }
                .task(id: document.fileId) { await load(document) }
            } else {
                Text("File no longer available")
                    .toolbar { Button("Done") { dismiss() } }
            }
        }.onAppear { index = documents.firstIndex { $0.fileId == initial } ?? 0 }
    }
    @MainActor private func load(_ document: ChatDocument) async {
        image = nil; failed = false; scale = 1
        let bytes = await core.documentBytes(fileId: document.fileId)
        guard !Task.isCancelled else { return }
        image = bytes.flatMap { platformImage($0) }; failed = image == nil
    }
}

private func platformImage(_ data: Data, maxPixelSize: Int = 2048) -> Image? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
          ] as CFDictionary) else { return nil }
    return Image(decorative: cgImage, scale: 1)
}
