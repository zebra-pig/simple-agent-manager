import Foundation
import ImageIO

// Real generated Swift -> Rust -> HTTP -> ImageIO path, with offline server data.
private final class PreviewCredentials: CredentialStore, @unchecked Sendable {
    let credentials: Credentials
    init(origin: String) { credentials = Credentials(serverUrl: origin, sessionCookie: "preview=fixture") }
    func load() -> Credentials? { credentials }
    func save(credentials: Credentials) {}
    func clear() {}
}
@main struct UploadedPreviewTest {
    static func main() async throws {
        let origin = CommandLine.arguments[1]
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let app = App(store: PreviewCredentials(origin: origin), baseDomain: nil)
        let chat = ChatViewModel(app: app)
        await chat.load(projectId: "p", sessionId: "s")
        let state = chat.state()
        guard let first = state.items.first, case let .user(_, attachments) = first.content,
              let image = attachments.first,
              let bytes = await chat.documentBytes(fileId: image.fileId) else {
            fatalError("Uploaded image did not load through the workspace fallback")
        }
        let data = Data(bytes)
        precondition(data == expected, "Preview must preserve original uploaded bytes")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("ImageIO could not decode the recovered PNG")
        }
        precondition(decoded.width > 0 && decoded.height > 0)
        print("UPLOADED_PREVIEW_SWIFT_RUST_IMAGEIO_PASS")
    }
}
