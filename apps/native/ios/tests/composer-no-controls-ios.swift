import SwiftUI
import UIKit

/// Offline regression: the production SAM composer must lay out without a mic or attachments.
@main struct ComposerNoControlsRegression: SwiftUI.App {
    var body: some Scene {
        WindowGroup { ComposerNoControlsScreen() }
    }
}

private struct ComposerNoControlsScreen: View {
    @State private var text = ""
    @State private var variant = "empty"

    var body: some View {
        VStack {
            Text("SAM composer regression")
            Spacer()
            composer
        }
        .task {
            for state in ["empty", "expanded", "stop", "retry", "busy"] {
                variant = state
                text = state == "expanded" ? String(repeating: "Review the project and explain what needs attention. ", count: 4) : ""
                // Allow real SwiftUI measurement and placement to complete in every state.
                try? await Task.sleep(for: .milliseconds(500))
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? "PASS: production composer rendered empty, expanded, stop, retry and busy without controls".write(
                to: documents.appendingPathComponent("composer-result.txt"), atomically: true, encoding: .utf8)
        }
    }

    private var composer: some View {
        var value = Composer(placeholder: "Ask SAM…", text: $text, busy: variant == "busy", files: nil, send: {})
        value.allowsEmpty = ["stop", "retry"].contains(variant)
        value.inputEnabled = variant != "retry"
        value.sendLabel = variant == "stop" ? "Stop" : variant == "retry" ? "Retry" : "Send"
        value.sendIcon = variant == "stop" ? "stop.fill" : "arrow.up"
        return value
    }
}
