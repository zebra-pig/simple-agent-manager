import AppKit
import SwiftUI

// An offline desktop fixture built in an isolated copy of the production app.
@main struct SlashCommandsDesktopFixture {
    @MainActor static func main() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: DesktopCommandsScreen())
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.run()
    }
}

private struct DesktopCommandsScreen: View {
    @State private var draft = "/"
    @State private var sent = false
    private let commands = [
        SlashCommand(name: "compact", description: "Compact conversation context", agentType: "claude-code"),
        SlashCommand(name: "do", description: "Execute the project workflow", agentType: "codex"),
        SlashCommand(name: "release", description: "Prepare a release for review", agentType: "codex"),
        SlashCommand(name: "review", description: "Review the current code changes", agentType: "codex"),
        SlashCommand(name: "status", description: "Show session status", agentType: "claude-code"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("SAM").font(.largeTitle.bold()).padding(.horizontal, 24)
            Text("Let’s build something.").font(.title2).padding(.horizontal, 24)
            Text("Use a project command to start the next task.")
                .foregroundStyle(.secondary).padding(.horizontal, 24)
            Spacer()
            Composer(placeholder: "Describe a task…", text: $draft, busy: false, files: nil, commands: commands) {
                sent = true
            } accessory: { Label("Code", systemImage: "person.crop.circle").font(.subheadline) }
        }
        .padding(.top, 24)
        .frame(width: 960, height: 680)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .task { await verify() }
    }

    @MainActor private func verify() async {
        func settle() async { try? await Task.sleep(for: .milliseconds(700)) }
        func editor(_ view: NSView) -> NSView? {
            if view is NSTextView || view is NSTextField { return view }
            return view.subviews.lazy.compactMap(editor).first
        }
        func key(_ code: UInt16, _ characters: String, in window: NSWindow) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        await settle()
        let window = NSApplication.shared.windows.first(where: { $0.contentView != nil })!
        window.makeKeyAndOrderFront(nil)
        guard let input = editor(window.contentView!) else { fatalError("Composer editor missing") }
        window.makeFirstResponder(input)
        await settle()
        try! capture(window, "macos-all")
        draft = "/re"
        await settle()
        key(125, "\u{F701}", in: window)
        await settle()
        key(36, "\r", in: window)
        await settle()
        precondition(draft == "/review ", "Desktop keyboard selection failed: \(draft)")
        precondition(!sent, "Selection must not submit")
        try! "PASS: macOS production composer arrow/Return selection inserts a command without sending".write(
            to: directory.appendingPathComponent("macos-result.txt"), atomically: true, encoding: .utf8)
        draft = "/"
        await settle()
        try! capture(window, "macos-all")
        NSApplication.shared.terminate(nil)
    }

    private var directory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAM_SCREENSHOT_DIR"]!) }
    @MainActor private func capture(_ window: NSWindow, _ name: String) throws {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
