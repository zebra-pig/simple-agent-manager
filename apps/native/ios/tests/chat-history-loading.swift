import AppKit
import SwiftUI

@MainActor @Observable final class HistoryFixture {
    var loading = false
    var error: String?
    var shown = true
    var offset: CGFloat = 0
    var requests = 0
    var cancellation = 0
    var interaction = 0
    func load() { requests += 1; loading = true }
}

struct HistoryFixtureView: View {
    let fixture: HistoryFixture
    var body: some View {
        ScrollView {
          VStack {
            if fixture.shown {
                ChatHistoryPager(loading: fixture.loading, error: fixture.error, viewportHeight: 200, cancellation: fixture.cancellation, interaction: fixture.interaction, load: fixture.load)
                    .offset(y: fixture.offset)
            }
            Text("Previously loaded conversation")
          }.padding().frame(width: 375, height: 200)
        }.frame(width: 375, height: 200)
            .coordinateSpace(name: "chatViewport")
    }
}

@main struct ChatHistoryLoadingTest {
    @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
    @MainActor static func main() {
        _ = NSApplication.shared
        let fixture = HistoryFixture()
        let host = NSHostingView(rootView: HistoryFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 375, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle()
        precondition(fixture.requests == 1, "Appearing must load automatically")
        settle()
        precondition(fixture.requests == 1, "In-flight requests must not repeat")
        // Completion while still visible must not start another page.
        fixture.loading = false
        settle()
        precondition(fixture.requests == 1, "Completion must not chain another page")
        fixture.offset = -400
        settle()
        fixture.interaction += 1
        fixture.offset = 0
        settle()
        precondition(fixture.requests == 2, "Re-entering the viewport must load another page")
        // Layout-only visibility churn must not create another user intent.
        fixture.offset = -400
        settle()
        fixture.offset = 0
        fixture.loading = false
        settle()
        precondition(fixture.requests == 2, "Layout reentry must not chain a page")
        fixture.interaction += 1
        settle()
        precondition(fixture.requests == 3, "A real new drag at the top must load")
        // A new drag during a request is serviced once it finishes.
        fixture.offset = -400
        settle()
        fixture.interaction += 1
        fixture.offset = 0
        settle()
        precondition(fixture.requests == 3, "Do not overlap requests")
        fixture.loading = false
        settle()
        precondition(fixture.requests == 4, "Do not lose a viewport entry during loading")
        fixture.offset = -400
        settle()
        fixture.interaction += 1
        fixture.offset = 0
        settle()
        fixture.cancellation += 1
        fixture.loading = false
        settle()
        precondition(fixture.requests == 4, "Jump cancellation must invalidate a pending entry")
        fixture.offset = -400
        settle()
        fixture.interaction += 1
        fixture.offset = 0
        settle()
        precondition(fixture.requests == 5, "A subsequent user entry must still load")
        fixture.error = "Connection interrupted"
        fixture.loading = false
        settle()
        precondition(fixture.requests == 5, "Errors must stop automatic retries")
        fixture.shown = false
        settle()
        fixture.error = nil
        settle()
        precondition(fixture.requests == 5, "Hidden history must not load")
        fixture.shown = true
        settle()
        precondition(fixture.requests == 6, "Returning to history must resume automatic loading")
        fixture.loading = false
        settle()
        precondition(fixture.requests == 6, "Completion alone must remain idle")
        fixture.interaction += 1
        settle()
        precondition(fixture.requests == 7, "A new swipe at a continuously visible top must load")
        window.orderOut(nil)
        print("CHAT_HISTORY_LOADING_PASS: appearance, in-flight guard, no chained loads, error stop, visibility")
    }
}
