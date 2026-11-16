import SwiftUI

/// Keeps error presentation outside scrolling content and above screen controls.
/// Errors stay readable until dismissed or resolved. A resolved error may recur.
private struct FloatingErrors: ViewModifier {
    let messages: [String?]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nestedMessages: [String] = []
    @State private var dismissed: Set<String> = []

    private var active: [String] {
        var result: [String] = []
        for message in messages.compactMap({ $0 }) + nestedMessages
        where !message.isEmpty && !result.contains(message) {
            result.append(message)
        }
        return result
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ErrorMessagesKey.self) { nestedMessages = $0 }
            // A nested screen owns its own errors; don't repeat them in a parent.
            .transformPreference(ErrorMessagesKey.self) { $0 = [] }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    ForEach(active.filter { !dismissed.contains($0) }, id: \.self) { message in
                        FloatingErrorBadge(message: message) { dismissed.insert(message) }
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                           value: active.filter { !dismissed.contains($0) })
            }
            .onChange(of: active) { activeBeforeChange, current in
                dismissed.formIntersection(current)
                if let message = current.first(where: { !activeBeforeChange.contains($0) }) {
                    AccessibilityNotification.Announcement(message).post()
                }
            }
    }
}

extension View {
    func floatingErrors(_ messages: [String?] = []) -> some View {
        modifier(FloatingErrors(messages: messages))
    }
}
