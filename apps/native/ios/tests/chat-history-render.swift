import AppKit
import SwiftUI

@main struct ChatHistoryRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [375.0, 1000.0] {
            for variant in ["ready", "loading", "retry"] {
                let error: String? = variant == "retry" ? "The connection was interrupted while loading earlier messages. Your loaded conversation is still available." : nil
                let view = VStack(alignment: .leading, spacing: 16) {
                    ChatHistoryPager(loading: variant == "loading", error: error, load: {})
                    Divider()
                    Text("Earlier in this conversation").font(.headline)
                    Text("A previously loaded message stays available while earlier history is requested.")
                    Text("A long conversation can be loaded page by page without replacing messages you have already read.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }.padding(20).frame(width: width, height: 350)
                    .background(Color.white).environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 350)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try png.write(to: directory.appendingPathComponent("\(variant)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
        print("CHAT_HISTORY_RENDER_PASS")
    }
}
