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
/// behind the sheet. Its collection is fixed once history finishes loading, so
/// live polling cannot insert pages underneath a swipe in progress.
struct ChatGallery: View {
    let source: ChatState
    let initial: String
    @State private var reader: ChatModel
    @State private var documents: [ChatDocument]
    @State private var loading: Bool
    @State private var error: String?
    @State private var retry = 0

    init(app: App, source: ChatState, initial: String, originalCore: ChatViewModel) {
        self.originalCore = originalCore
        self.source = source; self.initial = initial
        _reader = State(initialValue: ChatModel(app: app))
        _documents = State(initialValue: source.galleryDocuments)
        _loading = State(initialValue: source.hasMore)
    }

    var body: some View {
        DocumentGallery(documents: documents, initial: initial, core: reader.core, fallbackCore: originalCore,
                        loadingHistory: loading, historyError: error, retryHistory: { retry += 1 })
            .task(id: retry) { await loadHistory() }
    }

    // The reader is seeded through its normal load before it can fetch bytes.
    // Retain the original model for images already on screen during that load.
    let originalCore: ChatViewModel

    private func loadHistory() async {
        guard source.hasMore else { return }
        loading = true; error = nil
        await reader.core.load(projectId: source.projectId, sessionId: source.sessionId)
        guard !Task.isCancelled else { return }
        if let failure = reader.core.state().error {
            error = failure.message; loading = false; return
        }
        while reader.core.state().hasMore {
            guard !Task.isCancelled else { return }
            await reader.core.loadOlder()
            if let failure = reader.core.state().historyError {
                error = failure.message; loading = false; return
            }
        }
        guard !Task.isCancelled else { return }
        // Include still-pending uploads, preserving chronological order and IDs.
        documents = (reader.core.state().galleryDocuments + source.galleryDocuments).uniqueGalleryImages
        loading = false
    }
}

extension ChatState {
    var galleryDocuments: [ChatDocument] {
        let timeline = items.flatMap { item -> [ChatDocument] in
            switch item.content {
            case let .document(document): return [document]
            case let .user(_, attachments): return attachments
            default: return []
            }
        }
        return (timeline + outbox.flatMap(\.attachments)).uniqueGalleryImages
    }
}

extension Array where Element == ChatDocument {
    var uniqueGalleryImages: [ChatDocument] {
        var seen = Set<String>()
        return filter { $0.isImage && !$0.unavailable && !$0.fileId.isEmpty && seen.insert($0.fileId).inserted }
    }
}
