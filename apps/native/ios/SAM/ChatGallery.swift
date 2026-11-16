import SwiftUI

private struct OpenChatImageKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openChatImage: ((String) -> Void)? {
        get { self[OpenChatImageKey.self] }
        set { self[OpenChatImageKey.self] = newValue }
    }
}

/// Present from the screen, never a recyclable LazyVStack message row.
struct ChatGalleryPresentation: ViewModifier {
    let chat: ChatModel
    let app: App
    @State private var image: GalleryImageReference?

    func body(content: Content) -> some View {
        content
            .environment(\.openChatImage) { image = GalleryImageReference(id: $0) }
            .sheet(item: $image) { reference in
                ChatGallery(app: app, source: chat.state, initial: reference.id, originalCore: chat.core)
            }
    }
}

private struct GalleryImageReference: Identifiable {
    let id: String
}

/// A separate history reader keeps gallery pagination from moving the transcript
/// behind the sheet. Publish each discovered batch immediately and stop as soon
/// as earlier images are found; the leading page requests the next batch.
struct ChatGallery: View {
    let source: ChatState
    let initial: String
    @State private var reader: ChatModel
    @State private var documents: [ChatDocument]
    @State private var loading = false
    @State private var initialized = false
    @State private var error: String?
    @State private var retry = 0

    init(app: App, source: ChatState, initial: String, originalCore: ChatViewModel) {
        self.originalCore = originalCore
        self.source = source; self.initial = initial
        _reader = State(initialValue: ChatModel(app: app))
        _documents = State(initialValue: source.galleryDocuments)
    }

    var body: some View {
        DocumentGallery(documents: documents, initial: initial, core: reader.core, fallbackCore: originalCore,
                        historyError: error, requestEarlier: requestEarlier)
            .task(id: retry) { await loadHistory() }
    }

    // The reader is seeded through its normal load before it can fetch bytes.
    // Retain the original model for images already on screen during that load.
    let originalCore: ChatViewModel

    private func requestEarlier() {
        guard !loading, source.hasMore, !initialized || reader.core.state().hasMore else { return }
        retry += 1
    }

    private func loadHistory() async {
        guard source.hasMore else { return }
        loading = true; error = nil
        defer { loading = false }
        if !initialized {
            await reader.core.load(projectId: source.projectId, sessionId: source.sessionId)
            guard !Task.isCancelled else { return }
            if let failure = reader.core.state().error { error = failure.message; return }
            initialized = true
        }
        let first = documents.first?.fileId
        while reader.core.state().hasMore {
            guard !Task.isCancelled else { return }
            await reader.core.loadOlder()
            guard !Task.isCancelled else { return }
            let state = reader.core.state()
            if let failure = state.historyError { error = failure.message; return }
            let discovered = state.galleryDocuments(merging: source)
            if discovered != documents { documents = discovered }
            // Stop at the next image batch, even if much older history remains.
            // Paging is never disabled while a page with no images is searched.
            if documents.first?.fileId != first { return }
        }
    }
}

extension ChatState {
    var galleryDocuments: [ChatDocument] { galleryDocuments(merging: nil) }

    func galleryDocuments(merging source: ChatState?) -> [ChatDocument] {
        // The independent reader starts at the latest page. Keep the source's
        // already-loaded older images in order until the reader catches up.
        var seen = Set<String>()
        let rows = (items + (source?.items ?? [])).filter { seen.insert($0.id).inserted }
        let ordered = rows.enumerated().sorted {
            if $0.element.createdAt != $1.element.createdAt { return $0.element.createdAt < $1.element.createdAt }
            return $0.offset < $1.offset
        }
        let timeline = ordered.flatMap { entry -> [ChatDocument] in
            switch entry.element.content {
            case let .document(document): return [document]
            case let .user(_, attachments): return attachments
            default: return []
            }
        }
        return (timeline + (source?.outbox ?? outbox).flatMap(\.attachments)).uniqueGalleryImages
    }
}

extension Array where Element == ChatDocument {
    var uniqueGalleryImages: [ChatDocument] {
        var seen = Set<String>()
        return filter { $0.isImage && !$0.unavailable && !$0.fileId.isEmpty && seen.insert($0.fileId).inserted }
    }
}
