import SwiftUI

/// Keeps the label's size stable while an action is running.
struct LoadingLabel: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    let loading: Bool

    var body: some View {
        Group {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
        }
        .opacity(loading ? 0 : 1)
        .overlay { if loading { ProgressView().controlSize(.small) } }
        .accessibilityLabel(Text(title))
        .accessibilityValue(loading ? Text("Loading") : Text(""))
    }
}

private struct InitialLoading: ViewModifier {
    let loading: Bool
    @State private var finished = false

    func body(content: Content) -> some View {
        content
            .opacity(loading && !finished ? 0 : 1)
            .allowsHitTesting(!loading || finished)
            .accessibilityHidden(loading && !finished)
            .overlay {
                if loading && !finished {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: loading) { wasLoading, isLoading in
                if wasLoading && !isLoading { finished = true }
            }
    }
}

extension View {
    /// Only the first request gates the screen, including screens whose result is empty.
    func initialLoading(_ loading: Bool) -> some View { modifier(InitialLoading(loading: loading)) }
}
