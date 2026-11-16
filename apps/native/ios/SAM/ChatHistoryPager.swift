import SwiftUI

struct ChatHistoryPager: View {
    let loading: Bool
    let error: String?
    var viewportHeight: CGFloat? = nil
    var cancellation: Int = 0
    var interaction: Int = 0
    let load: () -> Void
    @State private var visible = false
    @State private var pendingEntry: Int?
    @State private var admittedInteraction = -1

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                ErrorNotice(message: error)
            }
            if error != nil {
                Button("Retry earlier messages", action: load)
                    .disabled(loading)
                    .buttonStyle(.bordered)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            }
        }.frame(maxWidth: .infinity)
            .modifier(HistoryViewportVisibility(viewportHeight: viewportHeight, visible: $visible))
            .onDisappear { visible = false }
            .onChange(of: visible) { _, visible in
                pendingEntry = visible ? cancellation : nil
                requestIfReady()
            }
            .onChange(of: loading) { _, _ in requestIfReady() }
            .onChange(of: interaction) { _, _ in
                // A new swipe at the already-visible top is a new user intent,
                // even when a prepend did not take the pager out of view.
                if visible && admittedInteraction != interaction {
                    pendingEntry = cancellation
                    requestIfReady()
                }
            }
    }

    private func requestIfReady() {
        // An entry during the previous request must not be dropped. Consume it
        // once; completion alone never creates another entry or starts a loop.
        guard pendingEntry == cancellation, visible, !loading, error == nil else { return }
        pendingEntry = nil
        admittedInteraction = interaction
        load()
    }
}

private struct HistoryViewportVisibility: ViewModifier {
    let viewportHeight: CGFloat?
    @Binding var visible: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        } else {
            content.background(GeometryReader { geometry in
                let frame = geometry.frame(in: .named("chatViewport"))
                Color.clear
                    .onChange(of: frame, initial: true) { _, frame in
                        if let viewportHeight {
                            visible = viewportHeight > 0 && frame.maxY > 0 && frame.minY < viewportHeight
                        }
                    }
                    .onChange(of: viewportHeight) { _, height in
                        if let height { visible = height > 0 && frame.maxY > 0 && frame.minY < height }
                    }
            })
            .onAppear { if viewportHeight == nil { visible = true } }
        }
    }
}
