import SwiftUI

/// Nested forms and attachment controls report to their screen's floating host.
struct ErrorNotice: View {
    let message: String

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .preference(key: ErrorMessagesKey.self, value: [message])
            .accessibilityHidden(true)
    }
}
