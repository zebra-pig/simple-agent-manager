import XCTest
import AppKit
import SwiftUI

@MainActor @Observable private final class HistoryPositionFixture {
    var first = 100
    var frames: [String: CGRect] = [:]
    var height: CGFloat = 0
    var visible: String?
    var prepend: (() -> Void)?
    var visit: (() -> Void)?
    var saved: ChatHistoryAnchor?
    var before: CGFloat = 0
}

private struct HistoryPositionView: View {
    let fixture: HistoryPositionFixture
    var body: some View {
        @Bindable var fixture = fixture
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Earlier messages").id("history")
                    ForEach(fixture.first..<160, id: \.self) { index in
                        Text("Message \(index)\n" + String(repeating: "Conversation detail. ", count: index % 17 + 1))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("message-\(index)")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatMessageFrames.self,
                                    value: ["message-\(index)": geometry.frame(in: .named("chatViewport"))])
                            })
                    }
                }.scrollTargetLayout().padding()
            }
            .coordinateSpace(name: "chatViewport")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ChatViewportHeight.self, value: geometry.size.height)
            })
            .onPreferenceChange(ChatMessageFrames.self) { fixture.frames = $0 }
            .onPreferenceChange(ChatViewportHeight.self) { fixture.height = $0 }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $fixture.visible, anchor: .top)
            .onAppear {
                fixture.visit = { proxy.scrollTo("message-100", anchor: UnitPoint(x: 0.5, y: 0.17)) }
                fixture.prepend = {
                    fixture.saved = ChatHistoryAnchor.capture(frames: fixture.frames, viewportHeight: fixture.height)
                    fixture.before = fixture.saved.flatMap { fixture.frames[$0.id]?.minY } ?? .nan
                    fixture.first -= 50
                }
            }
            .onChange(of: fixture.first) {
                if let anchor = fixture.saved {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo(anchor.id, anchor: anchor.point) }
                }
            }
        }
    }
}

final class ChatHistoryPositionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    @MainActor func testPrependingPreservesPartiallyVisibleRow() {
        _ = NSApplication.shared
        let fixture = HistoryPositionFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 375, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: HistoryPositionView(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        settle()
        fixture.visit?()
        settle()
        for _ in 0..<2 {
            fixture.prepend?()
            settle()
            guard let saved = fixture.saved, let after = fixture.frames[saved.id]?.minY else {
                XCTFail("Lost the previously visible row"); return
            }
            XCTAssertTrue(abs(after - fixture.before) <= 1, "Reading offset jumped: \(fixture.before) -> \(after)")
        }
        window.orderOut(nil)
    }
}
