import AppKit
import SwiftUI

/// Render the production composer and jump control at phone and desktop widths.
@main struct ComposerRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [375.0, 1000.0] {
            for variant in ["empty", "expanded", "stop", "retry", "busy"] {
                let text = variant == "expanded" ? "Please help me review the work across my projects and explain what needs my attention next." : ""
                var composer = Composer(placeholder: "Ask SAM…", text: .constant(text), busy: variant == "busy", files: nil, send: {})
                composer.allowsEmpty = ["stop", "retry"].contains(variant)
                composer.inputEnabled = variant != "retry"
                composer.sendLabel = variant == "stop" ? "Stop" : variant == "retry" ? "Retry" : "Send"
                composer.sendIcon = variant == "stop" ? "stop.fill" : "arrow.up"
                composer.leadingControl = AnyView(Button {} label: { Image(systemName: "mic") }.glassButton().buttonBorderShape(.circle).tint(.primary))
                let view = VStack {
                    Text("SAM").font(.title2)
                    Spacer()
                    ChatJumpButton {}
                    composer
                }.frame(width: width, height: 350).background(Color.white).environment(\.colorScheme, .light)
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
        print("COMPOSER_RENDER_PASS: 10 renders")
    }
}
