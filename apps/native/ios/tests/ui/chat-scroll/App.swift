import SwiftUI
import UIKit

private final class ScrollFixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? {
        Credentials(serverUrl: "http://127.0.0.1:SAM_TEST_PORT", sessionCookie: "fixture=scroll-only")
    }
    func save(credentials: Credentials) {}
    func clear() {}
}

// Only the app entry point is replaced in an isolated build copy. The UI tests
// navigate the production ChatView, Rust model, HTTP transport, pager and button.
@main struct SAMScrollFixture: SwiftUI.App {
    private let app = App(store: ScrollFixtureCredentials(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(app: app, ref: SessionRef(projectId: "fixture", sessionId: "fixture"))
                    .background(ScrollSamples().allowsHitTesting(false))
            }
        }
    }
}

// The display-link samples double as layout records for the `layout` endpoint.
private enum ScrollRenderedLayout {
    static var layouts: [[String: Any]] = []
    /// Frames where rows drew over one another, or a row's content did not
    /// fit its cell for several frames in a row.
    static var defects: [[String: Any]] = []
}

// Read-only instrumentation of the rendered transcript. Sampling every display
// frame lets the XCTest prove movement between frames of the real button tap.
// UIScrollView moves its own model offset each frame (no Core Animation), so
// model values are what is drawn; presentation layers lag a non-animated change;
// it never writes offsets, calls layoutIfNeeded, or changes production state.
// The defect check measures each visible cell's hosted row (a sizing query).
// Rows are the collection view's visible items, identified through its
// diffable data source; y is measured from the top of the scroll view's frame.
private struct ScrollSamples: UIViewRepresentable {
    func makeUIView(context: Context) -> SampleView { SampleView() }
    func updateUIView(_ view: SampleView, context: Context) {}

    final class SampleView: UIView {
        private var displayLink: CADisplayLink?
        private weak var chatScroll: ChatTranscriptView?
        private var samples: [[String: Any]] = []
        private var sending = false
        private var frameCount = 0
        /// Consecutive measured frames each row's content overflowed its cell.
        private var overflowing: [String: Int] = [:]

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            if window != nil {
                let link = CADisplayLink(target: self, selector: #selector(sample))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        private func findScroll(in view: UIView) -> ChatTranscriptView? {
            if let scroll = view as? ChatTranscriptView,
               scroll.bounds.height > 300, scroll.contentSize.height > scroll.bounds.height {
                return scroll
            }
            for child in view.subviews {
                if let found = findScroll(in: child) { return found }
            }
            return nil
        }

        /// The window region where the scroll view's content can actually draw:
        /// its frame intersected with every clipping ancestor.
        private func visible(_ scroll: UIScrollView) -> CGRect {
            guard let window else { return .zero }
            var rect = scroll.convert(scroll.bounds, to: window)
            var view = scroll.superview
            while let current = view, current !== window {
                if current.clipsToBounds || current.layer.masksToBounds || current.layer.mask != nil {
                    rect = rect.intersection(current.convert(current.bounds, to: window))
                }
                view = current.superview
            }
            return rect
        }

        private func visibleRows(_ scroll: ChatTranscriptView) -> [[String: Any]] {
            let source = scroll.dataSource as? UICollectionViewDiffableDataSource<Int, String>
            let offset = scroll.contentOffset.y
            return scroll.indexPathsForVisibleItems.sorted().compactMap { path in
                guard let id = source?.itemIdentifier(for: path), !id.hasPrefix("#"),
                      let cell = scroll.cellForItem(at: path) else { return nil }
                let frame = cell.frame
                let y = frame.minY - offset
                guard frame.height > 0, y + frame.height > 0, y < scroll.bounds.height else { return nil }
                return ["id": id, "y": y, "height": frame.height]
            }
        }

        /// Rows as drawn this frame, including any animation in flight: no
        /// two may overlap. Every third frame, each row's content is measured
        /// against its cell; content that stays taller than its cell draws
        /// over the next row.
        private func checkDefects(_ scroll: ChatTranscriptView, at now: TimeInterval) {
            frameCount += 1
            let source = scroll.dataSource as? UICollectionViewDiffableDataSource<Int, String>
            let cells = scroll.indexPathsForVisibleItems.sorted().compactMap { path -> (String, UICollectionViewCell)? in
                guard let id = source?.itemIdentifier(for: path), let cell = scroll.cellForItem(at: path), !cell.isHidden else { return nil }
                return (id, cell)
            }
            // A presentation layer lags a change made without animation until
            // the next commit; only an animation in flight draws elsewhere.
            let drawn: [(String, CGRect)] = cells.map { (id: String, cell: UICollectionViewCell) -> (String, CGRect) in
                let animating = !(cell.layer.animationKeys() ?? []).isEmpty
                return (id, animating ? cell.layer.presentation()?.frame ?? cell.frame : cell.frame)
            }.filter { $0.1.height > 0 }
            for (upper, lower) in zip(drawn, drawn.dropFirst()) where lower.1.minY < upper.1.maxY - 1 {
                ScrollRenderedLayout.defects.append(["time": now, "kind": "overlap", "upper": upper.0, "lower": lower.0,
                                                     "upperMaxY": upper.1.maxY, "lowerMinY": lower.1.minY])
            }
            guard frameCount % 3 == 0 else { return }
            var still: [String: Int] = [:]
            for (id, cell) in cells {
                let fitted = cell.contentView.systemLayoutSizeFitting(
                    CGSize(width: cell.bounds.width, height: 0),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
                guard fitted - cell.bounds.height > 2 else { continue }
                let count = (overflowing[id] ?? 0) + 1
                still[id] = count
                if count == 3 {
                    ScrollRenderedLayout.defects.append(["time": now, "kind": "overflow", "id": id,
                                                         "content": fitted, "cell": cell.bounds.height])
                }
            }
            overflowing = still
        }

        @objc private func sample() {
            if chatScroll == nil, let window { chatScroll = findScroll(in: window) }
            guard let scroll = chatScroll else { return }
            let now = Date().timeIntervalSince1970
            checkDefects(scroll, at: now)
            let rows = visibleRows(scroll)
            ScrollRenderedLayout.layouts.append(["time": now, "height": scroll.bounds.height,
                                                 "id": (rows.first?["id"] as? String) ?? "none", "rows": rows])
            samples.append([
                "time": now,
                "rows": rows,
                "y": scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y,
                "distanceToLatest": max(0, scroll.maxOffset
                    - scroll.contentOffset.y),
                "bottom": max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom),
                "height": scroll.bounds.height,
                "contentHeight": scroll.contentSize.height,
                "insetTop": scroll.adjustedContentInset.top,
                "insetBottom": scroll.adjustedContentInset.bottom,
                "visibleMinY": visible(scroll).minY,
                "visibleMaxY": visible(scroll).maxY,
                "windowHeight": window?.bounds.height ?? 0,
                "width": scroll.bounds.width,
                // Horizontal geometry including margins; 0 / bounds width at rest.
                "contentWidth": scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right,
                "x": scroll.contentOffset.x + scroll.adjustedContentInset.left,
                "reduceMotion": UIAccessibility.isReduceMotionEnabled
            ])
            if samples.count >= 8 && !sending {
                // One ordered batch at a time keeps instrumentation from flooding
                // URLSession's connection queue and overtaking its own samples.
                sending = true
                let batch = samples
                let layouts = ScrollRenderedLayout.layouts
                let defects = ScrollRenderedLayout.defects
                let payload: [String: Any] = ["samples": batch, "layouts": layouts, "defects": defects]
                samples.removeAll(keepingCapacity: true)
                ScrollRenderedLayout.layouts.removeAll(keepingCapacity: true)
                ScrollRenderedLayout.defects.removeAll(keepingCapacity: true)
                var request = URLRequest(url: URL(string: "http://127.0.0.1:SAM_TEST_PORT/measurements")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
                URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if error != nil || (response as? HTTPURLResponse)?.statusCode != 204 {
                            // A failed transport must not silently discard display frames.
                            self.samples.insert(contentsOf: batch, at: 0)
                            ScrollRenderedLayout.layouts.insert(contentsOf: layouts, at: 0)
                            ScrollRenderedLayout.defects.insert(contentsOf: defects, at: 0)
                        }
                        self.sending = false
                    }
                }.resume()
            }
        }
    }
}
