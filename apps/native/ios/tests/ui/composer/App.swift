import SwiftUI

@main struct ComposerTestApp: SwiftUI.App {
    var body: some Scene { WindowGroup { ComposerTestScreen() } }
}

private struct ComposerTestScreen: View {
    @State private var text = ""
    @State private var path: [String] = []
    @State private var submissions = 0
    private var variant: String { ProcessInfo.processInfo.arguments.first { ["empty", "busy", "stop", "retry", "navigate"].contains($0) } ?? "empty" }

    var body: some View {
        NavigationStack(path: $path) {
            VStack {
                Text("Submissions: \(submissions)").accessibilityIdentifier("submissions")
                Spacer()
                composer
            }
            .navigationTitle("Composer")
            .navigationDestination(for: String.self) { _ in
                VStack {
                    Text("Agent conversation")
                    // The iOS 27.2 bar back button is an unlabeled glass control that XCUITest
                    // cannot query reliably, so the fixture offers its own pop.
                    Button("Back to composer") { path.removeAll() }
                }
            }
        }
    }

    private var composer: some View {
        var value = Composer(placeholder: "Ask SAM…", text: $text, busy: variant == "busy", files: nil,
                             dismissFocusOnSend: variant == "navigate", send: {
            submissions += 1
            if variant == "navigate" { text = ""; path.append("agent") }
        }) { EmptyView() }
        value.allowsEmpty = ["stop", "retry"].contains(variant)
        value.inputEnabled = variant != "retry"
        value.sendLabel = variant == "stop" ? "Stop" : variant == "retry" ? "Retry" : "Send"
        value.sendIcon = variant == "stop" ? "stop.fill" : "arrow.up"
        return value
    }
}
