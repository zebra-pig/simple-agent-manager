import AppKit
import SwiftUI

private final class SteeringCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? { Credentials(serverUrl: "http://127.0.0.1:18973", sessionCookie: "fixture=offline") }
    func save(credentials: Credentials) {}
    func clear() {}
}

/// Desktop companion to steering-ios.swift; renders the production ChatView.
@main struct SteeringMacRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let app = App(store: SteeringCredentials(), baseDomain: nil)
        let view = NavigationStack {
            ChatView(app: app, ref: SessionRef(projectId: "fixture", sessionId: "chat"))
        }.frame(width: 1000, height: 800).background(Color.white)
            .environment(\.colorScheme, .light).preferredColorScheme(.light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("STEERING_MAC_RENDER_PASS")
    }
}
