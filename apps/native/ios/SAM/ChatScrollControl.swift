import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Cancels native gesture/momentum ownership before an explicit chat jump.
@MainActor final class ChatScrollControl {
    private var jumpTask: Task<Void, Never>?
    #if os(iOS)
    weak var scrollView: UIScrollView?
    #endif

    func jump(using proxy: ScrollViewProxy, to id: String) {
        jumpTask?.cancel()
        #if os(iOS)
        if let scrollView {
            let pan = scrollView.panGestureRecognizer
            if pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            // LazyVStack refines its content height as each chunk is materialized.
            // Follow that moving destination instead of animating to one estimate.
            jumpTask = Task { @MainActor [weak scrollView] in
                var settledFrames = 0
                for _ in 0..<240 {
                    guard !Task.isCancelled, let scrollView,
                          !scrollView.isDragging, !scrollView.isTracking else { return }
                    scrollView.layoutIfNeeded()
                    let bottom = max(-scrollView.adjustedContentInset.top,
                                     scrollView.contentSize.height - scrollView.bounds.height
                                     + scrollView.adjustedContentInset.bottom)
                    let distance = bottom - scrollView.contentOffset.y
                    if abs(distance) <= 0.5 {
                        settledFrames += 1
                        if settledFrames >= 4 { return }
                    } else {
                        settledFrames = 0
                        let step = UIAccessibility.isReduceMotionEnabled ? distance : distance * 0.22
                        scrollView.setContentOffset(
                            CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y + step),
                            animated: false)
                    }
                    do { try await Task.sleep(for: .milliseconds(16)) }
                    catch { return }
                }
            }
            return
        }
        #endif
        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .bottom) }
    }

}

/// Resolve only the ancestor scroll view of the chat content; never a nested image/code scroller.
struct ChatScrollProbe: View {
    let control: ChatScrollControl
    var body: some View {
        #if os(iOS)
        Probe(control: control).allowsHitTesting(false).accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct Probe: UIViewRepresentable {
    let control: ChatScrollControl
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.control = control
        return view
    }
    func updateUIView(_ view: Marker, context: Context) { view.resolveScrollView() }

    final class Marker: UIView {
        weak var control: ChatScrollControl?
        override func didMoveToWindow() { super.didMoveToWindow(); resolveScrollView() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); resolveScrollView() }
        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.control?.scrollView = scrollView
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
#endif

/// Shared floating control for agent chats and the private SAM conversation.
struct ChatJumpButton: View {
    let jump: () -> Void
    var body: some View {
        Button(action: jump) {
            Image(systemName: "arrow.down").font(.body.weight(.medium))
                .frame(width: 28, height: 28)
        }
        .glassButton()
        .buttonBorderShape(.circle)
        .tint(.primary)
        .accessibilityLabel(Text("Jump to latest"))
        .padding()
    }
}
