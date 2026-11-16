import SwiftUI

struct ChatHistoryPager: View {
    let loading: Bool
    let error: String?
    var viewportHeight: CGFloat? = nil
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
            .background(GeometryReader { geometry in
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
            .onDisappear { visible = false }
            .task(id: visible) {
                guard visible, !loading, error == nil else { return }
                load()
            }
    }
}
