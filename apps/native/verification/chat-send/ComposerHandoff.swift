import SwiftUI

/// Replace SAM/SAMApp.swift in an isolated iOS copy, build and launch in a
/// simulator. Capture at launch, after 8 seconds, and after 14 seconds.
@main struct ComposerHandoffFixture: SwiftUI.App {
    var body: some Scene { WindowGroup { HandoffFixture() } }
}

private struct HandoffFixture: View {
    @ChatDraft private var draft: String
    @State private var submission = ChatSubmission()
    init() {
        _draft = ChatDraft(server: "fixture", user: "fixture", project: "p", session: "s")
    }
    var body: some View {
        VStack {
            Text("Agent reply").font(.headline)
            Spacer()
            Composer(placeholder: "Reply to the agent…", text: $draft, busy: submission.sending, files: ComposerFiles(items: [], add: { _, _, _, _ in }, remove: { _ in })) {
                send()
            }
        }.preferredColorScheme(.light)
        .task {
            draft = "Please review this change"
            try? await Task.sleep(for: .seconds(8))
            send()
        }
    }
    private func send() {
        submission.send(draft: _draft) { _ in
            try? await Task.sleep(for: .seconds(6))
            return false
        }
    }
}
