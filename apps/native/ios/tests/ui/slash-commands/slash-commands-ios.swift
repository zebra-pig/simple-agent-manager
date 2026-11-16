import SwiftUI
import UIKit

// Replace SAMApp.swift only in an isolated copy of the production target.
// No credentials, network calls, or live submissions are used by this fixture.
@main struct SlashCommandsFixture: SwiftUI.App {
    var body: some Scene { WindowGroup { SlashCommandsScreen() } }
}

private struct SlashCommandsScreen: View {
    @State private var draft = ""
    @State private var sent = false
    @State private var dark = false
    private let commands = [
        SlashCommand(name: "compact", description: "Compact conversation context", agentType: "claude-code"),
        SlashCommand(name: "do", description: "Execute the project workflow", agentType: "codex"),
        SlashCommand(name: "release", description: "Prepare a release for review", agentType: "codex"),
        SlashCommand(name: "review", description: "Review the current code changes", agentType: "codex"),
        SlashCommand(name: "status", description: "Show session status", agentType: "claude-code"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Let’s build something.").font(.title2.bold())
                    Text("Use a project command to start the next task.")
                        .foregroundStyle(.secondary)
                    Label("Project workflow ready", systemImage: "checkmark.circle")
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 16))
                }.padding(24)
            }
            .navigationTitle("SAM")
            .safeAreaInset(edge: .bottom) {
                Composer(placeholder: "Describe a task…", text: $draft, busy: false, files: nil, commands: commands) {
                    sent = true
                } accessory: {
                    Label("Code", systemImage: "person.crop.circle").font(.subheadline)
                }
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .task { await verify() }
    }

    @MainActor private func verify() async {
        func settle() async { try? await Task.sleep(for: .milliseconds(650)) }
        func findEditor(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        func key(_ input: UITextView, _ value: String) {
            guard let command = input.keyCommands?.first(where: { $0.input == value }) else {
                preconditionFailure("Missing command key: \(value)")
            }
            _ = input.perform(command.action, with: command)
        }
        await settle()
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)!
        let input = findEditor(window)!
        input.becomeFirstResponder()
        await settle()
        input.insertText("/")
        await settle()
        await capture(window, "all-light")
        precondition(input.keyCommands?.contains(where: { $0.input == UIKeyCommand.inputDownArrow }) == true)
        draft = "/re"
        await settle()
        await capture(window, "filtered-light")
        key(input, UIKeyCommand.inputDownArrow)
        await settle()
        key(input, "\r")
        await settle()
        precondition(draft == "/review ", "Selection must insert the command and trailing space: \(draft)")
        precondition(!sent, "Choosing a command must never send")
        precondition(input.isFirstResponder, "Selection must retain editor focus")
        input.insertText("this change")
        await settle()
        precondition(draft == "/review this change")
        await capture(window, "inserted-light")
        draft = "/re"
        await settle()
        key(input, UIKeyCommand.inputEscape)
        await settle()
        precondition(draft == "/re", "Dismiss must preserve the draft")
        precondition(input.keyCommands?.contains(where: { $0.input == UIKeyCommand.inputDownArrow }) != true)
        input.resignFirstResponder()
        draft = "/"
        dark = true
        await settle()
        input.becomeFirstResponder()
        await settle()
        await capture(window, "all-dark")
        draft = "/unknown"
        await settle()
        precondition(input.keyCommands?.contains(where: { $0.input == UIKeyCommand.inputDownArrow }) != true)
        precondition(!sent)
        try! "PASS: production composer discovery, filtering, keyboard selection, trailing arguments, focus retention, dismissal, unmatched draft, and no auto-send".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        draft = "/"
    }

    private var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    @MainActor private func capture(_ window: UIWindow, _ name: String) async {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try! image.pngData()!.write(to: directory.appendingPathComponent(name + ".png"))
        if ProcessInfo.processInfo.environment["SAM_SCREENSHOT_HANDSHAKE"] == "1" {
            let ready = directory.appendingPathComponent(name + ".ready")
            let done = directory.appendingPathComponent(name + ".done")
            try! Data().write(to: ready)
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: done.path) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            preconditionFailure("Simulator screenshot timed out: \(name)")
        }
    }
}
