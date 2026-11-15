// Simulator regression fixture. Compiles the production ChatScrollControl and probe.
import SwiftUI
import UIKit

@main struct ChatScrollFixture: App {
    var body: some Scene { WindowGroup { Conversation() } }
}

private struct Conversation: View {
    @State private var first = 200
    @State private var control = ChatScrollControl()
    @State private var result = "Loading latest page"
    @State private var visibleMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack {
                Text(result).accessibilityIdentifier("result")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(first..<300, id: \.self) { index in
                            Text("Message \(index)\n" + String(repeating: "Conversation detail. ", count: index % 17 + 1))
                                .frame(maxWidth: .infinity, alignment: .leading).id("message-\(index)")
                        }
                        Text("Latest message").id("latest")
                    }.scrollTargetLayout().padding().background(ChatScrollProbe(control: control))
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition(id: $visibleMessage, anchor: .top)
                Button("Jump to latest") { control.jump(using: proxy, to: "latest") }
            }
            .task {
                try? await Task.sleep(for: .seconds(1))
                // Load and visit two older chunks, retaining variable-height lazy rows.
                first = 100
                try? await Task.sleep(for: .milliseconds(200))
                proxy.scrollTo("message-100", anchor: .top)
                try? await Task.sleep(for: .milliseconds(300))
                first = 0
                try? await Task.sleep(for: .milliseconds(200))
                proxy.scrollTo("message-0", anchor: .top)
                try? await Task.sleep(for: .milliseconds(500))
                guard let scroll = control.scrollView else { fatalError("Missing chat scroll view") }
                let start = scroll.contentOffset.y
                result = "Loaded three chunks; jumping"
                control.jump(using: proxy, to: "latest")
                try? await Task.sleep(for: .milliseconds(80))
                let intermediate = scroll.contentOffset.y
                precondition(intermediate > start + 10, "Jump did not move")
                let intermediateBottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                precondition(intermediate < intermediateBottom - 10, "Jump lost animation")
                try? await Task.sleep(for: .seconds(4))
                let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                precondition(abs(bottom - scroll.contentOffset.y) <= 1, "Jump stopped before the actual bottom")
                // Repeated taps must supersede the previous animation.
                proxy.scrollTo("message-0", anchor: .top)
                try? await Task.sleep(for: .milliseconds(300))
                control.jump(using: proxy, to: "latest")
                control.jump(using: proxy, to: "latest")
                try? await Task.sleep(for: .seconds(4))
                let finalBottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                precondition(abs(finalBottom - scroll.contentOffset.y) <= 1, "Repeated jump failed")
                result = "PASS: 3 chunks · animated · reached latest · repeated taps"
                try? result.write(toFile: NSHomeDirectory() + "/Documents/result.txt", atomically: true, encoding: .utf8)
                print(result)
            }
        }
    }
}
