import SwiftUI

struct ChatHistoryPager: View {
    let loading: Bool
    let error: String?
    let load: () -> Void
    @State private var visible = false

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
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
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: [loading, visible]) {
                guard visible, !loading, error == nil else { return }
                load()
            }
    }
}
