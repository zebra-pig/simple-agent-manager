import SwiftUI
import QuickLook
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension ChatDocument {
    var isImage: Bool { mimeType != "image/svg+xml" && (filename as NSString).pathExtension.lowercased() != "svg" && (UTType(mimeType: mimeType)?.conforms(to: .image) == true || UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: .image) == true) }
    var label: String { filename.isEmpty ? String(localized: "File") : filename }
}

struct DocumentCard: View {
    let document: ChatDocument
    let documents: [ChatDocument]
    let core: ChatViewModel
    var compactImage = false
    @State private var image: Image?
    @Environment(\.openChatImage) private var openChatImage
    @State private var gallery = false
    @State private var preview: URL?
    @State private var folder: URL?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button {
            if document.isImage {
                if let openChatImage { openChatImage(document.fileId) }
                else { gallery = true }
            }
            else { Task { await openFile() } }
        } label: {
            if compactImage && document.isImage {
                ImageTile(image: image, side: 120)
            } else {
            VStack(alignment: .leading, spacing: 6) {
                if document.isImage {
                    ImageTile(image: image, side: 160)
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
        }
        .buttonStyle(.plain)
        .disabled(document.unavailable || document.fileId.isEmpty || loading)
        .accessibilityLabel(Text(verbatim: document.label))
        .accessibilityHint(Text(document.isImage ? "Open gallery" : "Open file"))
        .task(id: document.fileId) {
            if document.isImage && !document.unavailable, let bytes = await core.documentBytes(fileId: document.fileId) { let decoded = await decodeImage(bytes, maxPixelSize: 440)
                guard !Task.isCancelled else { return }
                image = decoded.map { Image(decorative: $0, scale: 1) } }
        }
        .sheet(isPresented: $gallery) { DocumentGallery(documents: documents.uniqueGalleryImages, initial: document.fileId, core: core) }
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
    @State private var selection: String
    @State private var swipe = GallerySwipeNavigation()
    var fallbackCore: ChatViewModel?
    var loadingHistory = false
    var historyError: String?
    var retryHistory: (() -> Void)?

    init(documents: [ChatDocument], initial: String, core: ChatViewModel,
         fallbackCore: ChatViewModel? = nil, loadingHistory: Bool = false, historyError: String? = nil, retryHistory: (() -> Void)? = nil) {
        self.documents = documents; self.initial = initial; self.core = core
        self.fallbackCore = fallbackCore
        self.loadingHistory = loadingHistory; self.historyError = historyError; self.retryHistory = retryHistory
        _selection = State(initialValue: initial)
    }

    private var index: Int? { documents.firstIndex { $0.fileId == selection } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let index {
                    #if os(iOS)
                    if loadingHistory {
                        GalleryPage(document: documents[index], core: core, fallbackCore: fallbackCore, active: true)
                    } else {
                        TabView(selection: $selection) {
                            ForEach(Array(documents.enumerated()), id: \.element.fileId) { offset, document in
                                GalleryPage(document: document, core: core, fallbackCore: fallbackCore, active: abs(offset - index) <= 1)
                                    .tag(document.fileId)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                    #else
                    GalleryPage(document: documents[index], core: core, fallbackCore: fallbackCore, active: true, swipe: swipe, onNavigate: move)
                        .id(selection)
                    #endif
                    HStack(spacing: 24) {
                        Button("Previous image", systemImage: "chevron.left") { move(-1) }
                            .labelStyle(.iconOnly).disabled(loadingHistory || index == 0)
                            #if os(macOS)
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            #endif
                        Text(loadingHistory || historyError != nil ? "\(index + 1) of \(documents.count) loaded" : "\(index + 1) of \(documents.count)")
                            .font(.subheadline.monospacedDigit())
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: move(1)
                                case .decrement: move(-1)
                                @unknown default: break
                                }
                            }
                        Button("Next image", systemImage: "chevron.right") { move(1) }
                            .labelStyle(.iconOnly).disabled(loadingHistory || index == documents.count - 1)
                            #if os(macOS)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            #endif
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.thinMaterial, in: Capsule())
                } else { ContentUnavailableView("File no longer available", systemImage: "photo") }
                if loadingHistory {
                    HStack { ProgressView().controlSize(.small); Text("Finding earlier images…").font(.caption) }
                } else if let historyError {
                    VStack(spacing: 4) {
                        Text(historyError).font(.caption).foregroundStyle(.secondary)
                        Button("Retry earlier images") { retryHistory?() }
                    }.padding(.horizontal)
                }
            }.padding(.bottom, 12)
            .navigationTitle(index.map { documents[$0].label } ?? String(localized: "Images"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 360)
        #endif
    }

    private func move(_ delta: Int) {
        guard !loadingHistory, let index, documents.indices.contains(index + delta) else { return }
        selection = documents[index + delta].fileId
    }
}

private struct GalleryPage: View {
    let document: ChatDocument
    let core: ChatViewModel
    var fallbackCore: ChatViewModel?
    let active: Bool
    var swipe: GallerySwipeNavigation?
    var onNavigate: ((Int) -> Void)?
    @State private var image: CGImage?
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image {
                    #if os(iOS)
                    GalleryZoomImage(image: image)
                    #else
                    GalleryMacZoomImage(image: image, swipe: swipe, onNavigate: onNavigate)
                    #endif
                } else if failed {
                    ContentUnavailableView {
                        Label("Image unavailable", systemImage: "photo")
                    } actions: { Button("Retry") { retry += 1 } }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !document.caption.isEmpty {
                Text(verbatim: document.caption).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).padding(.horizontal)
            }
        }
        .task(id: "\(active)-\(retry)") {
            guard active else { image = nil; return }
            guard image == nil else { return }
            failed = false
            var bytes = await core.documentBytes(fileId: document.fileId)
            if bytes == nil, let fallbackCore { bytes = await fallbackCore.documentBytes(fileId: document.fileId) }
            let decoded: CGImage?
            if let bytes { decoded = await decodeImage(bytes) } else { decoded = nil }
            guard !Task.isCancelled else { return }
            image = decoded; failed = decoded == nil
        }
    }
}

#if os(iOS)
/// UIKit owns zoom/pan without relaying every gesture frame through SwiftUI layout.
private struct GalleryZoomImage: UIViewRepresentable {
    let image: CGImage
    func makeUIView(context: Context) -> GalleryImageScrollView { GalleryImageScrollView() }
    func updateUIView(_ view: GalleryImageScrollView, context: Context) {
        if view.imageView.image?.cgImage !== image {
            view.setZoomScale(1, animated: false)
            view.imageView.image = UIImage(cgImage: image)
        }
    }
}

private final class GalleryImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var viewport = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 4
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if viewport != bounds.size {
            viewport = bounds.size
            setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: viewport)
            contentSize = viewport
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2, height: bounds.height / 2)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
#endif

#if os(macOS)
private struct GalleryMacZoomImage: NSViewRepresentable {
    let image: CGImage
    var swipe: GallerySwipeNavigation?
    var onNavigate: ((Int) -> Void)?
    func makeNSView(context: Context) -> GalleryMacScrollView { GalleryMacScrollView() }
    func updateNSView(_ view: GalleryMacScrollView, context: Context) {
        view.swipe = swipe
        view.onNavigate = onNavigate
        if view.sourceImage !== image {
            view.sourceImage = image
            view.imageView.image = NSImage(cgImage: image, size: .zero)
        }
    }
}

private final class GalleryMacScrollView: NSScrollView {
    let imageView = NSImageView()
    var sourceImage: CGImage?
    var onNavigate: ((Int) -> Void)?
    var swipe: GallerySwipeNavigation?
    private var viewport = CGSize.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        allowsMagnification = true; minMagnification = 1; maxMagnification = 4
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func scrollWheel(with event: NSEvent) {
        // A single unzoomed horizontal trackpad gesture advances one image.
        // Ignore its momentum, which otherwise advances again or bounces back.
        if event.phase.contains(.began) { swipe?.begin() }
        guard magnification <= 1, let onNavigate,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event); return
        }
        if let direction = swipe?.move(delta: event.scrollingDeltaX,
                                       began: event.phase.contains(.began),
                                       discrete: event.phase.isEmpty,
                                       momentum: !event.momentumPhase.isEmpty,
                                       time: event.timestamp) {
            onNavigate(direction)
        }
    }
    override func layout() {
        super.layout()
        if viewport != bounds.size {
            viewport = bounds.size; magnification = 1
            imageView.frame = CGRect(origin: .zero, size: viewport)
        }
    }
}
#endif

// Force decoding away from the UI thread, including the first rendered frame.
private func decodeImage(_ data: Data, maxPixelSize: Int = 2048) async -> CGImage? {
    await Task.detached(priority: .userInitiated) { decodedCGImage(data, maxPixelSize: maxPixelSize) }.value
}

private func decodedCGImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ] as CFDictionary)
}

func platformImage(_ data: Data, maxPixelSize: Int = 2048) -> Image? {
    decodedCGImage(data, maxPixelSize: maxPixelSize).map { Image(decorative: $0, scale: 1) }
}

/// A fixed footprint while loading, after decoding and on failure.
struct ImageTile: View {
    let image: Image?
    let side: CGFloat
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image { image.resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: side, height: side)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

func attachmentThumbnail(_ source: CGImageSource?) -> Data? {
    guard let source,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
          ] as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
