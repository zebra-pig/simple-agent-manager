import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Cancels native gesture/momentum ownership before an explicit chat jump.
@MainActor final class ChatScrollControl {
    #if os(iOS)
    weak var scrollView: UIScrollView?
    #endif

    func jump(using proxy: ScrollViewProxy, to id: String) {
        #if os(iOS)
        if let scrollView {
            let pan = scrollView.panGestureRecognizer
            if pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        #endif
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
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
