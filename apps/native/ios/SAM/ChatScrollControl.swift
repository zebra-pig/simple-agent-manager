import SwiftUI

/// Requests destinations; SwiftUI owns both animation and lazy-layout correction.
/// Never drive the underlying UIScrollView while a scrollPosition binding owns it.
@MainActor @Observable final class ChatScrollControl {
    let inverted: Bool
    @ObservationIgnored var messageFrames: [String: CGRect] = [:]
    @ObservationIgnored var viewportHeight: CGFloat = 0
    @ObservationIgnored private var followsDestination = false
    @ObservationIgnored fileprivate var preservePosition: ((String, UnitPoint) -> Void)?

    init(inverted: Bool = false) { self.inverted = inverted }

    fileprivate struct Request: Equatable {
        let token = UUID()
        let destination: String?
        var anchor: UnitPoint = .top
        let animated: Bool
    }
    fileprivate var request: Request?

    func readManually() { followsDestination = false }

    func preserveReadingPosition(using proxy: ScrollViewProxy) {
        guard !followsDestination,
              let anchor = ChatHistoryAnchor.capture(frames: messageFrames, viewportHeight: viewportHeight) else { return }
        let point = inverted ? UnitPoint(x: 0.5, y: 1 - anchor.point.y) : anchor.point
        if let preservePosition { preservePosition(anchor.id, point) }
        else { proxy.scrollTo(anchor.id, anchor: point) }
    }

    func jump(using proxy: ScrollViewProxy, to id: String, animated: Bool = true) {
        followsDestination = true
        if #available(iOS 18, macOS 15, *) {
            request = Request(destination: nil, animated: animated)
        } else {
            withAnimation(animated ? .easeInOut(duration: 0.35) : nil) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    func restore(using proxy: ScrollViewProxy, to id: String, anchor: UnitPoint = .top) {
        if #available(iOS 18, macOS 15, *) {
            request = Request(destination: id, anchor: anchor, animated: false)
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

struct ChatScrollTracking: ViewModifier {
    let control: ChatScrollControl
    let followsLatest: Bool
    @Binding var visibleMessage: String?
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *), control.inverted {
            content.modifier(InvertedChatScrollTracking(control: control,
                visibleMessage: $visibleMessage))
        } else if #available(iOS 18, macOS 15, *) {
            content.modifier(SemanticChatScrollTracking(control: control,
                visibleMessage: $visibleMessage, followsLatest: followsLatest))
        } else {
            content.defaultScrollAnchor(control.inverted ? .top : .bottom)
                .scrollPosition(id: $visibleMessage, anchor: control.inverted ? .bottom : .top)
        }
    }
}

/// The newest row is at the scroll view's logical origin. Loading older rows
/// extends its far end without changing any existing row's content coordinates.
@available(iOS 18, macOS 15, *)
private struct InvertedChatScrollTracking: ViewModifier {
    let control: ChatScrollControl
    @Binding var visibleMessage: String?
    @State private var position = ScrollPosition(idType: String.self)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        edges(content)
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition($position)
            .onAppear {
                control.preservePosition = { id, anchor in
                    var transaction = Transaction(animation: nil)
                    transaction.scrollPositionUpdatePreservesVelocity = true
                    withTransaction(transaction) { position.scrollTo(id: id, anchor: anchor) }
                }
            }
            .onDisappear { control.preservePosition = nil }
            .onChange(of: position.viewID(type: String.self)) { _, id in visibleMessage = id }
            .onChange(of: control.request) { _, request in
                guard let request else { return }
                withAnimation(request.animated && !reduceMotion ? .easeInOut(duration: 0.35) : nil) {
                    if let id = request.destination { position.scrollTo(id: id, anchor: request.anchor) }
                    else { position.scrollTo(edge: .top) }
                }
            }
    }

    @ViewBuilder private func edges(_ content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            // The system's directional edge blur assumes an upright view.
            content.scrollEdgeEffectHidden()
        } else { content }
    }
}

@available(iOS 18, macOS 15, *)
private struct SemanticChatScrollTracking: ViewModifier {
    let control: ChatScrollControl
    @Binding var visibleMessage: String?
    let followsLatest: Bool
    @State private var position = ScrollPosition(idType: String.self)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { old, new in
                // Rotation/resizing is separate from content-height changes.
                // Retain the explicit bottom destination without anchoring
                // every lazy-layout refinement or interrupting its animation.
                guard old.width > 0, old.height > 0, old != new,
                      position.edge == .bottom || followsLatest else { return }
                withAnimation(nil) { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: position.viewID(type: String.self)) { _, id in
                visibleMessage = id
            }
            .onChange(of: control.request) { _, request in
                guard let request else { return }
                withAnimation(request.animated && !reduceMotion ? .easeInOut(duration: 0.35) : nil) {
                    if let id = request.destination {
                        position.scrollTo(id: id, anchor: request.anchor)
                    } else {
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
    }
}

/// Lifecycle of a lazy row is not evidence that it is actually on screen.
/// Only older OS versions without viewport callbacks use the lifecycle fallback.
struct ChatBottomTracking: ViewModifier {
    @Binding var followsLatest: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.1) { followsLatest = $0 }
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
