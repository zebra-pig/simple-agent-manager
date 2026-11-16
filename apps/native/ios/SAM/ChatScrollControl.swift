import SwiftUI

/// Requests destinations; SwiftUI owns both animation and lazy-layout correction.
/// Never drive the underlying UIScrollView while a scrollPosition binding owns it.
@MainActor @Observable final class ChatScrollControl {
    fileprivate struct Request: Equatable {
        let token = UUID()
        let destination: String?
        let animated: Bool
    }
    fileprivate var request: Request?

    func jump(using proxy: ScrollViewProxy, to id: String, animated: Bool = true) {
        if #available(iOS 18, macOS 15, *) {
            request = Request(destination: nil, animated: animated)
        } else {
            withAnimation(animated ? .easeInOut(duration: 0.35) : nil) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    func restore(using proxy: ScrollViewProxy, to id: String) {
        if #available(iOS 18, macOS 15, *) {
            request = Request(destination: id, animated: false)
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

struct ChatScrollTracking: ViewModifier {
    let control: ChatScrollControl
    @Binding var visibleMessage: String?
    @Binding var followsLatest: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.modifier(SemanticChatScrollTracking(control: control,
                visibleMessage: $visibleMessage, followsLatest: $followsLatest))
        } else {
            content.scrollPosition(id: $visibleMessage, anchor: .top)
        }
    }
}

@available(iOS 18, macOS 15, *)
private struct SemanticChatScrollTracking: ViewModifier {
    let control: ChatScrollControl
    @Binding var visibleMessage: String?
    @Binding var followsLatest: Bool
    @State private var position = ScrollPosition(idType: String.self)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: position.viewID(type: String.self)) { _, id in
                visibleMessage = id
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    - geometry.contentInsets.bottom >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                followsLatest = atBottom
            }
            .onChange(of: control.request) { _, request in
                guard let request else { return }
                withAnimation(request.animated && !reduceMotion ? .easeInOut(duration: 0.35) : nil) {
                    if let id = request.destination {
                        position.scrollTo(id: id, anchor: .top)
                    } else {
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
    }
}

/// Lifecycle of a lazy row is not evidence that it is actually on screen.
/// Only older OS versions without scroll geometry use this legacy fallback.
struct ChatBottomTracking: ViewModifier {
    @Binding var followsLatest: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
        } else {
            content.onAppear { followsLatest = true }.onDisappear { followsLatest = false }
        }
    }
}
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
