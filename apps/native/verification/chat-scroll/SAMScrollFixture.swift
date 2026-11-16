import SwiftUI
import UIKit

private final class ScrollFixtureCredentials: CredentialStore, @unchecked Sendable {
    func load() -> Credentials? {
        Credentials(serverUrl: "http://127.0.0.1:18874", sessionCookie: "fixture=scroll-only")
    }
    func save(credentials: Credentials) {}
    func clear() {}
}

// Only the app entry point is replaced in an isolated build copy. The UI tests
// navigate the production ChatView, Rust model, HTTP transport, pager and button.
@main struct SAMScrollFixture: SwiftUI.App {
    @State private var viewportHeight: CGFloat = 0
    private let app = App(store: ScrollFixtureCredentials(), baseDomain: nil)
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(app: app, ref: SessionRef(projectId: "fixture", sessionId: "fixture"))
                    .background(ScrollSamples().allowsHitTesting(false))
                    .onPreferenceChange(ChatViewportHeight.self) { viewportHeight = $0 }
                    .onPreferenceChange(ChatMessageFrames.self) { frames in
                        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
                            .sorted { $0.value.minY < $1.value.minY }
                        ScrollRenderedLayout.rows = visible.map {
                            ["id": $0.key, "y": $0.value.minY, "height": $0.value.height] as [String: Any]
                        }
                        let anchor = ChatHistoryAnchor.capture(frames: frames, viewportHeight: viewportHeight)
                        let payload: [String: Any] = ["time": Date().timeIntervalSince1970,
                            "height": viewportHeight, "id": anchor?.id ?? "none", "point": anchor?.point.y ?? 0,
                            "rows": visible.map { ["id": $0.key, "y": $0.value.minY, "height": $0.value.height] as [String: Any] }]
                        var request = URLRequest(url: URL(string: "http://127.0.0.1:18874/layout-samples")!)
                        request.httpMethod = "POST"
                        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
                        URLSession.shared.dataTask(with: request).resume()
                    }
            }
        }
    }
}

// Preference callbacks can describe intermediate layout passes that never reach
// the display. Sample the latest completed layout at display-link cadence too.
private enum ScrollRenderedLayout {
    static var rows: [[String: Any]] = []
}

// Read-only instrumentation of the rendered scroll view. Sampling presentation
// offsets lets the XCTest prove movement between frames of the real button tap;
// it never writes offsets, calls layoutIfNeeded, or changes production state.
private struct ScrollSamples: UIViewRepresentable {
    func makeUIView(context: Context) -> SampleView { SampleView() }
    func updateUIView(_ view: SampleView, context: Context) {}

    final class SampleView: UIView {
        private var displayLink: CADisplayLink?
        private weak var chatScroll: UIScrollView?
        private var samples: [[String: Any]] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            if window != nil {
                let link = CADisplayLink(target: self, selector: #selector(sample))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        private func findScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               scroll.bounds.height > 300, scroll.contentSize.height > scroll.bounds.height {
                return scroll
            }
            for child in view.subviews {
                if let found = findScroll(in: child) { return found }
            }
            return nil
        }

        @objc private func sample() {
            if chatScroll == nil, let window { chatScroll = findScroll(in: window) }
            guard let scroll = chatScroll else { return }
            samples.append([
                "time": Date().timeIntervalSince1970,
                "rows": ScrollRenderedLayout.rows,
                "y": scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y,
                "distanceToLatest": max(0,
                    (scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y) + scroll.adjustedContentInset.top),
                "bottom": max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom),
                "height": scroll.bounds.height,
                "contentHeight": scroll.contentSize.height,
                "insetTop": scroll.adjustedContentInset.top,
                "insetBottom": scroll.adjustedContentInset.bottom,
                "reduceMotion": UIAccessibility.isReduceMotionEnabled
            ])
            if samples.count >= 8 {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:18874/scroll-samples")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: samples)
                URLSession.shared.dataTask(with: request).resume()
                samples.removeAll(keepingCapacity: true)
            }
        }
    }
}
