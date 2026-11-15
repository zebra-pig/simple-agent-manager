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
            Button(action: load) {
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    Text(error == nil ? "Load earlier messages" : "Retry earlier messages")
                }
            }
            .disabled(loading)
            .buttonStyle(.bordered)
        }.frame(maxWidth: .infinity)
    }
}
