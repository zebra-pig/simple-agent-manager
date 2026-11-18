import SwiftUI

/// The earlier-history row at the top of a transcript.
struct ChatTranscriptEarlier: Equatable {
    var loading: Bool
    var failed: Bool
}

#if os(iOS)
import UIKit

/// Requests destinations from the transcript the screen shows.
@MainActor final class ChatTranscriptControl {
    fileprivate weak var view: ChatTranscriptView?

    /// Scrolls to the newest row and keeps following it.
    func jumpToLatest(animated: Bool = true) { view?.jumpToLatest(animated: animated) }
}

/// A chat transcript in an upright `UICollectionView`: oldest row at the top,
/// newest at the bottom, rows hosted with `UIHostingConfiguration`.
///
/// Three rules keep what the reader looks at still, without mirroring the
/// scroll view:
/// - While following the latest row, every layout pass pins the bottom.
/// - Otherwise, a data change (an earlier page, a resolved card) keeps the
///   first visible row at the same distance from the top of the viewport.
/// - A row above the viewport that changes height compensates the offset in
///   the same layout pass (`ChatTranscriptLayout`).
struct ChatTranscript<Row: Identifiable & Equatable, Content: View>: UIViewRepresentable where Row.ID == String {
    let rows: [Row]
    let earlier: ChatTranscriptEarlier?
    let control: ChatTranscriptControl
    /// The bars' heights: the transcript runs on behind them.
    let insets: EdgeInsets
    @Binding var followsLatest: Bool
    /// The reader started scrolling: hold live changes still.
    let browse: () -> Void
    let loadEarlier: () -> Void
    let comment: (Row) -> (() -> Void)?
    @ViewBuilder let content: (Row) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatTranscriptView {
        let layout = ChatTranscriptLayout()
        let view = ChatTranscriptView(frame: .zero, collectionViewLayout: layout)
        let coordinator = context.coordinator
        view.transcript = coordinator
        view.delegate = coordinator
        layout.identifier = { [weak coordinator] path in coordinator?.ids[safe: path.item] }
        let registration = UICollectionView.CellRegistration<ChatTranscriptCell, String> { [weak coordinator] cell, _, id in
            guard let coordinator else { return }
            cell.contentConfiguration = coordinator.configuration(for: id)
            cell.backgroundConfiguration = .clear()
        }
        coordinator.dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: view) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }
        coordinator.view = view
        control.view = view
        return view
    }

    func updateUIView(_ view: ChatTranscriptView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.environment = context.environment
        control.view = view
        view.reduceMotion = context.environment.accessibilityReduceMotion
        view.setInsets(top: insets.top, bottom: insets.bottom)
        coordinator.apply(rows: rows, earlier: earlier)
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDelegate {
        static var pagerID: String { "#earlier" }

        var parent: ChatTranscript?
        var environment = EnvironmentValues()
        var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        weak var view: ChatTranscriptView?
        fileprivate(set) var ids: [String] = []
        private var rows: [String: Row] = [:]
        private var earlier: ChatTranscriptEarlier?
        /// One page per scroll gesture: inserting rows can bring the pager
        /// back into view without the reader asking for more.
        private var interaction = 0
        private var admittedInteraction = -1

        func configuration(for id: String) -> UIContentConfiguration {
            let environment = environment
            if id == Self.pagerID {
                let earlier = earlier ?? ChatTranscriptEarlier(loading: true, failed: false)
                return UIHostingConfiguration {
                    ChatTranscriptPager(earlier: earlier) { [weak self] in self?.parent?.loadEarlier() }
                }.margins(.all, 0)
            }
            guard let row = rows[id], let parent else { return UIListContentConfiguration.cell() }
            return UIHostingConfiguration {
                // Hosted rows are a separate SwiftUI graph: forward what rows read.
                parent.content(row)
                    // While a cell's height catches up with its content, keep
                    // the row at the top of the cell rather than centered.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .environment(\.openURL, environment.openURL)
                    .environment(\.openChatImage, environment.openChatImage)
            }.margins(.horizontal, 16).margins(.vertical, 0)
        }

        func apply(rows incoming: [Row], earlier newEarlier: ChatTranscriptEarlier?) {
            guard let view, let dataSource else { return }
            let newRows = incoming.uniquedByID()
            let newIDs = (newEarlier == nil ? [] : [Self.pagerID]) + newRows.map(\.id)
            var changed = newRows.filter { row in rows[row.id].map { $0 != row } ?? false }.map(\.id)
            if newEarlier != nil, earlier != nil, newEarlier != earlier { changed.append(Self.pagerID) }
            let identical = newIDs == ids && changed.isEmpty && (newEarlier == nil) == (earlier == nil)
            rows = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
            earlier = newEarlier
            if identical {
                checkEarlier()
                return
            }
            let initial = ids.isEmpty
            let anchor = view.captureAnchor()
            ids = newIDs
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs)
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(changed.filter(existing.contains))
            view.applying(restoring: anchor) {
                if initial {
                    dataSource.applySnapshotUsingReloadData(snapshot)
                } else {
                    dataSource.apply(snapshot, animatingDifferences: false)
                }
            }
            (view.collectionViewLayout as? ChatTranscriptLayout)?.retainMeasurements(for: Set(newIDs))
            checkEarlier()
        }

        /// Loads the earlier page when the reader scrolls it into view, or when
        /// the whole conversation fits without scrolling.
        func checkEarlier() {
            guard let view, let earlier, !earlier.loading, !earlier.failed,
                  ids.first == Self.pagerID, interaction != admittedInteraction,
                  let pager = view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else { return }
            let visibleTop = view.contentOffset.y + view.adjustedContentInset.top
            guard pager.frame.maxY > visibleTop else { return }
            let scrolled = view.isDragging || view.isDecelerating
            guard scrolled || view.contentFits, !view.jumping else { return }
            admittedInteraction = interaction
            parent?.loadEarlier()
        }

        func id(at path: IndexPath) -> String? { ids[safe: path.item] }

        // MARK: Scrolling

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            interaction += 1
            view?.cancelJump()
            parent?.browse()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view else { return }
            if view.isTracking || view.isDecelerating { view.setFollowing(view.atBottom) }
            checkEarlier()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { view?.settle() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { view?.settle() }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            view?.cancelJump()
            return true
        }

        /// Always reaches the screen, unchanged values too: the screen catches
        /// up on live changes it held while the reader was scrolling.
        func followingChanged(_ following: Bool) {
            parent?.followsLatest = following
        }

        // MARK: Comment menu

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt paths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard paths.count == 1, let id = ids[safe: paths[0].item], let row = rows[id],
                  let comment = parent?.comment(row) else { return nil }
            // Pressing text selects it, with Comment in the edit menu. The row
            // menu is for presses beside the text (padding, attachments).
            var hit = collectionView.hitTest(point, with: nil)
            while let view = hit {
                if view is ReadOnlyTextView { return nil }
                if view is UICollectionViewCell { break }
                hit = view.superview
            }
            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(children: [UIAction(title: String(localized: "Comment"), image: UIImage(systemName: "text.bubble")) { _ in comment() }])
            })
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                            highlightPreviewForItemAt path: IndexPath) -> UITargetedPreview? {
            preview(collectionView, path)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                            dismissalPreviewForItemAt path: IndexPath) -> UITargetedPreview? {
            preview(collectionView, path)
        }

        /// Lifts the row as drawn, not on the cell's full-width backing.
        private func preview(_ collectionView: UICollectionView, _ path: IndexPath) -> UITargetedPreview? {
            guard let cell = collectionView.cellForItem(at: path) else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: cell.contentView.bounds, cornerRadius: 18)
            return UITargetedPreview(view: cell.contentView, parameters: parameters)
        }
    }
}

/// Spinner while an earlier page loads, and a retry button when it failed.
private struct ChatTranscriptPager: View {
    let earlier: ChatTranscriptEarlier
    let retry: () -> Void

    var body: some View {
        VStack {
            if earlier.failed {
                Button("Retry earlier messages", action: retry)
                    .disabled(earlier.loading)
                    .buttonStyle(.bordered)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .accessibilityAction(named: Text("Load earlier messages")) {
            if !earlier.loading { retry() }
        }
    }
}

/// Measures its hosted row at the width the layout gives it.
final class ChatTranscriptCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let preferred = super.preferredLayoutAttributesFitting(attributes)
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        preferred.frame.size = CGSize(width: attributes.size.width, height: ceil(size.height))
        return preferred
    }
}

/// The scroll view. Its layout pass applies the pinning and anchoring rules.
final class ChatTranscriptView: UICollectionView {
    fileprivate weak var transcript: (any ChatTranscriptCoordinating)?
    fileprivate(set) var following = true
    /// The jump to the latest row, while it animates.
    private var jump: Jump?
    var jumping: Bool { jump != nil }
    fileprivate var reduceMotion = false
    private var laidOutWidth: CGFloat = 0

    /// A row and its distance from the top of the scroll view's bounds.
    struct Anchor {
        let id: String
        let offset: CGFloat
    }

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        backgroundColor = .clear
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        // The insets come from SwiftUI: the navigation bar and the composer.
        contentInsetAdjustmentBehavior = .never
        selfSizingInvalidation = .enabledIncludingConstraints
        accessibilityIdentifier = "chat-transcript"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var minOffset: CGFloat { -adjustedContentInset.top }
    var maxOffset: CGFloat {
        max(minOffset, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }
    var atBottom: Bool { maxOffset - contentOffset.y <= 4 }
    var contentFits: Bool { contentSize.height <= bounds.height - adjustedContentInset.top - adjustedContentInset.bottom }

    fileprivate func setInsets(top: CGFloat, bottom: CGFloat) {
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard contentInset != insets else { return }
        let anchor = captureAnchor()
        contentInset = insets
        verticalScrollIndicatorInsets = insets
        restore(anchor)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        // A new width (rotation, split view) remeasures every row.
        let resized = laidOutWidth != 0 && laidOutWidth != bounds.width
        let anchor = resized ? captureAnchor() : nil
        laidOutWidth = bounds.width
        super.layoutSubviews()
        if let anchor { restore(anchor) }
        if following && !jumping && !isTracking && !isDecelerating { pinToBottom() }
    }

    fileprivate func pinToBottom() {
        let bottom = maxOffset
        if abs(contentOffset.y - bottom) > 0.5 { contentOffset.y = bottom }
    }

    /// The first row reaching below the top bar, unless following the latest.
    func captureAnchor() -> Anchor? {
        guard !following || jumping, let transcript else { return nil }
        let top = contentOffset.y + adjustedContentInset.top
        let visible = indexPathsForVisibleItems.sorted()
        for path in visible {
            guard let id = transcript.id(at: path), !id.hasPrefix("#"),
                  let frame = layoutAttributesForItem(at: path)?.frame, frame.maxY > top else { continue }
            return Anchor(id: id, offset: frame.minY - contentOffset.y)
        }
        return nil
    }

    fileprivate func restore(_ anchor: Anchor?) {
        guard let anchor, let transcript,
              let item = transcript.ids.firstIndex(of: anchor.id),
              let frame = collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else { return }
        var target = frame.minY - anchor.offset
        if !isTracking { target = max(minOffset, min(target, max(maxOffset, contentOffset.y))) }
        if abs(contentOffset.y - target) > 0.25 {
            // A jump continues from the same rows, wherever they moved.
            jump?.start += target - contentOffset.y
            contentOffset.y = target
        }
    }

    /// Applies a data change while keeping `anchor` in place.
    fileprivate func applying(restoring saved: Anchor?, _ change: () -> Void) {
        let layout = collectionViewLayout as? ChatTranscriptLayout
        // The anchor restores the offset; don't also compensate per row.
        layout?.compensatesAboveViewport = false
        UIView.performWithoutAnimation {
            change()
            layoutIfNeeded()
            restore(saved)
            // Rows that just appeared measure themselves in this pass.
            layoutIfNeeded()
            restore(saved)
        }
        layout?.compensatesAboveViewport = true
    }

    fileprivate func setFollowing(_ value: Bool) {
        guard following != value else { return }
        following = value
        transcript?.followingChanged(value)
    }

    /// The reader let go: report following again, even if it did not change,
    /// so live changes held for the gesture catch up.
    fileprivate func settle() {
        following = atBottom
        transcript?.followingChanged(following)
        transcript?.checkEarlier()
    }

    fileprivate func jumpToLatest(animated: Bool) {
        cancelJump()
        layoutIfNeeded()
        guard animated, !reduceMotion, window != nil, maxOffset - contentOffset.y > 0.5 else {
            setFollowing(true)
            pinToBottom()
            return
        }
        // Driven per frame rather than by setContentOffset(_:animated:), so
        // the destination follows the bottom as rows measure themselves on
        // the way down, and an earlier page arriving mid-jump shifts the start
        // instead of restarting the animation.
        let link = CADisplayLink(target: JumpTarget(self), selector: #selector(JumpTarget.step))
        jump = Jump(start: contentOffset.y, began: CACurrentMediaTime(), link: link)
        link.add(to: .main, forMode: .common)
    }

    fileprivate func cancelJump() {
        jump?.link.invalidate()
        jump = nil
    }

    fileprivate func stepJump() {
        guard let jump else { return }
        let progress = min(1, (CACurrentMediaTime() - jump.began) / Jump.duration)
        // Ease in and out (cubic).
        let eased = progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(-2 * progress + 2, 3) / 2
        contentOffset.y = jump.start + (maxOffset - jump.start) * eased
        if progress >= 1 {
            cancelJump()
            setFollowing(true)
            pinToBottom()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelJump() }
    }

    private struct Jump {
        static let duration: CFTimeInterval = 0.5
        var start: CGFloat
        let began: CFTimeInterval
        let link: CADisplayLink
    }

    /// The display link retains its target; this one doesn't retain the view.
    private final class JumpTarget: NSObject {
        weak var view: ChatTranscriptView?
        init(_ view: ChatTranscriptView) { self.view = view }
        @MainActor @objc func step() { view?.stepJump() }
    }
}

@MainActor private protocol ChatTranscriptCoordinating: AnyObject {
    var ids: [String] { get }
    func id(at path: IndexPath) -> String?
    func followingChanged(_ following: Bool)
    func checkEarlier()
}

extension ChatTranscript.Coordinator: ChatTranscriptCoordinating {}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
