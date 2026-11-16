import SwiftUI

/// A pre-request reading position, independent of the scroll binding SwiftUI
/// updates while prepending rows. A shared target/viewport anchor preserves the
/// row's pixel offset, including a partially clipped variable-height message.
struct ChatHistoryAnchor {
    let id: String
    let point: UnitPoint

    static func capture(frames: [String: CGRect], viewportHeight: CGFloat) -> Self? {
        guard viewportHeight > 0,
              let row = frames.filter({ $0.value.maxY > 0 && $0.value.minY < viewportHeight })
                .min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        let denominator = viewportHeight - row.value.height
        let y = abs(denominator) > 1 ? row.value.minY / denominator : 0
        return Self(id: row.key, point: UnitPoint(x: 0.5, y: y))
    }
}

struct ChatMessageFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ChatViewportHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
