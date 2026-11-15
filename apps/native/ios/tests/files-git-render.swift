import AppKit
import SwiftUI

// Offline transport fixtures only. The app build also checks the views against
// the real generated core types. No credentials or live workspace are accessed.
struct FileEntry { var name: String; var kind: String; var size: UInt64 }
struct GitChange { var path: String; var status: String; var oldPath: String?; var staged: Bool; var untracked: Bool }
enum CodeKind { case context, added, removed, header }
struct CodeLine { var text: String; var oldNumber: UInt32?; var newNumber: UInt32?; var kind: CodeKind }
struct FixtureError { var message: String }
struct ChatToolsState {
    var entries: [FileEntry] = []
    var changes: [GitChange] = []
    var lines: [CodeLine] = []
    var error: FixtureError? = nil
    var loading = false
}
@MainActor final class FixtureCore {
    func browse(path: String) async {}
    func gitStatus() async {}
    func openFile(path: String, diff: Bool, staged: Bool) async {}
}
@MainActor final class ChatToolsModel {
    let state: ChatToolsState
    let core = FixtureCore()
    init(_ state: ChatToolsState) { self.state = state }
    func navigationModel() -> ChatToolsModel { ChatToolsModel(state) }
}
extension View { func inlineTitle() -> some View { self } }

@main struct FilesGitRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var files = ChatToolsState()
        files.entries = [FileEntry(name: "Sources", kind: "dir", size: 0),
                         FileEntry(name: "Tests", kind: "dir", size: 0),
                         FileEntry(name: "A very long internationalized filename — 日本語 — layout regression.swift", kind: "file", size: 123456),
                         FileEntry(name: "README.md", kind: "file", size: 4096)]
        var git = ChatToolsState()
        git.changes = [GitChange(path: "Sources/Chat/FileBrowserView.swift", status: "M", staged: true, untracked: false),
                       GitChange(path: "Sources/New file with a long renamed filename.swift", status: "R", oldPath: "Sources/Old file.swift", staged: false, untracked: false),
                       GitChange(path: "tests/new-fixture.md", status: "?", staged: false, untracked: true)]
        var code = ChatToolsState()
        code.lines = [CodeLine(text: "@@ -1,2 +1,2 @@", kind: .header),
                      CodeLine(text: "- old content", oldNumber: 1, kind: .removed),
                      CodeLine(text: "+ new content", newNumber: 1, kind: .added),
                      CodeLine(text: "  unchanged content with a very long line that should scroll horizontally without wrapping or clipping source text", oldNumber: 2, newNumber: 2, kind: .context)]
        var error = ChatToolsState()
        error.error = FixtureError(message: "Workspace unavailable. Try again when the session reconnects.")
        let samples: [(String, AnyView)] = [
            ("files", AnyView(FileBrowserView(source: ChatToolsModel(files)))),
            ("git", AnyView(GitChangesView(source: ChatToolsModel(git)))),
            ("diff", AnyView(SourceFileView(source: ChatToolsModel(code), path: "Sources/Chat/FileBrowserView.swift", diff: true))),
            ("empty", AnyView(FileBrowserView(source: ChatToolsModel(ChatToolsState())))),
            ("error", AnyView(FileBrowserView(source: ChatToolsModel(error))))
        ]
        for (name, content) in samples {
            for width in [375.0, 1000.0] {
                let view = NavigationStack { content }.frame(width: width, height: 600)
                    .environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try png.write(to: output.appendingPathComponent("\(name)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
        print("FILES_GIT_FIXTURE_RENDER_PASS")
    }
}
