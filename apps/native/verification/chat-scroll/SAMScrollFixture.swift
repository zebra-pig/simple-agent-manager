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
                "y": scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y,
                "bottom": max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom),
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
