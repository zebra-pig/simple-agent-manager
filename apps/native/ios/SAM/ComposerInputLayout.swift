import SwiftUI

/// Keeps the editor's identity and keyboard focus while its controls move below a wrapped draft.
///
/// Subviews, in order: the text input, the attachment control, the send control.
/// SwiftUI can lay this out with fewer subviews than that, for example while
/// a conditional control is between states. A missing subview is skipped
/// instead of indexed: indexing past `subviews` traps (TestFlight crashes in
/// build 120).
struct ComposerInputLayout: Layout {
    var lineHeight: CGFloat

    private func metrics(width: CGFloat, subviews: Subviews) -> (expanded: Bool, field: CGSize, height: CGFloat) {
        guard let input = subviews.first else { return (false, .zero, 56) }
        let collapsed = input.sizeThatFits(ProposedViewSize(width: max(1, width - 112), height: nil))
        let expanded = collapsed.height > lineHeight * 1.5
        let field = expanded ? input.sizeThatFits(ProposedViewSize(width: max(1, width - 32), height: nil)) : collapsed
        return (expanded, field, expanded ? 16 + field.height + 8 + 44 + 8 : max(56, field.height + 16))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let y = bounds.minY + (m.expanded ? bounds.height - 52 : (bounds.height - 44) / 2)
        let control = ProposedViewSize(width: 44, height: 44)
        for (index, subview) in subviews.enumerated() {
            switch index {
            case 0:
                subview.place(at: CGPoint(x: bounds.minX + (m.expanded ? 16 : 56),
                                          y: bounds.minY + (m.expanded ? 16 : (bounds.height - m.field.height) / 2)),
                              proposal: ProposedViewSize(width: max(1, bounds.width - (m.expanded ? 32 : 112)), height: m.field.height))
            case 1: subview.place(at: CGPoint(x: bounds.minX + 8, y: y), proposal: control)
            case 2: subview.place(at: CGPoint(x: bounds.maxX - 52, y: y), proposal: control)
            // Unexpected extra subviews stay out of sight rather than overlapping the input.
            default: subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
            }
        }
    }
}
