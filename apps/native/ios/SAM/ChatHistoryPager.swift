import SwiftUI

struct ChatHistoryPager: View {
    let loading: Bool
    let error: String?
    let load: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if error != nil {
                Button("Retry earlier messages", action: load)
                    .disabled(loading)
                    .buttonStyle(.bordered)
            } else if #available(iOS 18, macOS 15, *) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            } else {
                Button("Load earlier messages", action: load).disabled(loading)
            }
        }.frame(maxWidth: .infinity)
            .modifier(HistoryVisibility(loading: loading, error: error, load: load))
    }
}

private struct HistoryVisibility: ViewModifier {
    let loading: Bool
    let error: String?
    let load: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.1) { visible in
                // One request when the pager enters the actual viewport. A lazy
                // row can stay instantiated offscreen; load completion must not
                // rearm it and recursively drain every remaining history page.
                if visible && !loading && error == nil { load() }
            }
        } else {
            content
        }
    }
}
