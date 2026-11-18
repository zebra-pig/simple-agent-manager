#if os(iOS)
import UIKit

/// A single column of self-sizing rows, oldest at the top, in a plain,
/// upright scroll view.
///
/// Rows above the visible region keep what is on screen still when they change
/// height. That happens when an older row is measured for the first time while
/// the reader scrolls up into it. The layout moves the content offset by the
/// same amount in the same layout pass, through the invalidation context's
/// `contentOffsetAdjustment`. Signal-iOS and ChatLayout use the same primitive.
/// Inserting rows (an older page) is anchored by `ChatTranscriptView`.
final class ChatTranscriptLayout: UICollectionViewLayout {
    var spacing: CGFloat = 12
    var verticalPadding: CGFloat = 16
    /// Height for a row that has never been measured at the current width.
    var estimatedHeight: CGFloat = 80
    /// Bottom pinning moves the offset itself; it must not be compensated twice.
    var compensatesAboveViewport = true
    /// The identity of the row at an index path, so measurements follow a row
    /// when rows are inserted before it.
    var identifier: (IndexPath) -> AnyHashable? = { _ in nil }

    private var measured: [AnyHashable: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        if width != measuredWidth {
            // Heights at another width are still the best estimate available.
            measuredWidth = width
        }
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(count)
        var y = verticalPadding
        for item in 0..<count {
            let path = IndexPath(item: item, section: 0)
            let height = identifier(path).flatMap { measured[$0] } ?? estimatedHeight
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + (item == count - 1 ? 0 : spacing)
        }
        contentHeight = y + verticalPadding
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // Frames are sorted by y: find the first row reaching into `rect`.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var item = low
        while item < frames.count, frames[item].minY <= rect.maxY {
            result.append(attributes(at: item))
            item += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < frames.count ? attributes(at: indexPath.item) : nil
    }

    private func attributes(at item: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
        attributes.frame = frames[item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        abs(preferred.frame.height - original.frame.height) > 0.5
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let path = original.indexPath
        guard path.item < frames.count, let id = identifier(path) else { return context }
        let old = frames[path.item].height
        let new = ceil(preferred.frame.height)
        let firstMeasurement = measured[id] == nil
        measured[id] = new
        if compensatesAboveViewport, let collectionView,
           growsUpward(path.item, firstMeasurement: firstMeasurement, in: collectionView) {
            context.contentOffsetAdjustment.y += new - old
        }
        return context
    }

    /// Whether a row's new height should push the rows above it up rather than
    /// the rows below it down.
    /// - A row starting above the visible top grows upward, off screen.
    /// - A row measured for the first time above a row the reader already
    ///   sees (the end of an earlier page) grows upward too. Rows the reader
    ///   changes (expanding a disclosure) or scrolls onto grow downward.
    private func growsUpward(_ item: Int, firstMeasurement: Bool, in collectionView: UICollectionView) -> Bool {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if frames[item].minY < top { return true }
        guard firstMeasurement else { return false }
        let bottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        var below = item + 1
        while below < frames.count, frames[below].minY < bottom {
            if let id = identifier(IndexPath(item: below, section: 0)), measured[id] != nil { return true }
            below += 1
        }
        return false
    }

    /// Drops heights for rows that no longer exist.
    func retainMeasurements(for ids: Set<AnyHashable>) {
        measured = measured.filter { ids.contains($0.key) }
    }
}
#endif
