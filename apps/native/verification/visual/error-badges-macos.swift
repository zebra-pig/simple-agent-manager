import AppKit
import SwiftUI

/// Render the shared production badge at desktop width without a logged-in desktop.
@main struct ErrorBadgeMacCapture {
    @MainActor static func main() throws {
        let content = ZStack(alignment: .top) {
            Color.gray.opacity(0.08)
            VStack(alignment: .leading, spacing: 20) {
                Text("Project settings").font(.largeTitle.bold())
                Text("Your project content stays in place.")
                Spacer()
            }.padding(32)
            FloatingErrorBadge(message: "Can't reach the server. Check your connection and try again.", dismiss: {})
                .padding(.top, 88)
        }
        .frame(width: 800, height: 600)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let data = renderer.nsImage?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
