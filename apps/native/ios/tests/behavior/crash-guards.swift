import XCTest
import AppKit
import SwiftUI

/// Regression tests for TestFlight crash reports.
@MainActor final class CrashGuardTests: XCTestCase {
    private struct Row: Identifiable, Equatable { let id: String; let text: String }

    /// A repeated id in a diffable snapshot terminates the app; the first row wins.
    func testTranscriptRowsDropRepeatedIDsAndKeepOrder() {
        let rows = [Row(id: "a", text: "1"), Row(id: "#request-s-r", text: "2"), Row(id: "b", text: "3"),
                    Row(id: "#request-s-r", text: "4"), Row(id: "a", text: "5")]
        XCTAssertEqual(rows.uniquedByID(), [Row(id: "a", text: "1"), Row(id: "#request-s-r", text: "2"), Row(id: "b", text: "3")])
        XCTAssertEqual([Row]().uniquedByID(), [])
    }

    private final class Frames { var values: [String: CGRect] = [:] }

    private func host(_ view: some View, width: CGFloat) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func tracked(_ name: String, in frames: Frames) -> some View {
        Color.red.background(GeometryReader { geometry in
            Color.clear.onAppear { frames.values[name] = geometry.frame(in: .global) }
        })
    }

    /// Build 120 trapped in `placeSubviews` with "Index out of range" when the
    /// layout had fewer than three subviews. It now lays out what it has.
    func testComposerLayoutWithMissingControlsDoesNotTrap() {
        let frames = Frames()
        let hosting = host(ComposerInputLayout(lineHeight: 22) {
            tracked("input", in: frames).frame(height: 22)
            tracked("attach", in: frames)
        }, width: 400)
        XCTAssertEqual(hosting.fittingSize.height, 56, accuracy: 0.5)
        XCTAssertEqual(frames.values["input"]?.minX ?? -1, 56, accuracy: 0.5)
        XCTAssertEqual(frames.values["attach"]?.minX ?? -1, 8, accuracy: 0.5)

        let empty = host(ComposerInputLayout(lineHeight: 22) { EmptyView() }, width: 400)
        XCTAssertEqual(empty.fittingSize.height, 56, accuracy: 0.5)
    }

    func testComposerLayoutPlacesControlsBesideAndBelowTheInput() {
        let frames = Frames()
        _ = host(ComposerInputLayout(lineHeight: 22) {
            tracked("input", in: frames).frame(height: 22)
            tracked("attach", in: frames).frame(width: 44, height: 44)
            tracked("send", in: frames).frame(width: 44, height: 44)
        }, width: 400)
        XCTAssertEqual(frames.values["input"]?.width ?? -1, 400 - 112, accuracy: 0.5)
        XCTAssertEqual(frames.values["send"]?.minX ?? -1, 400 - 52, accuracy: 0.5)
        XCTAssertEqual(frames.values["attach"]?.midY ?? -1, frames.values["input"]?.midY ?? -2, accuracy: 0.5)

        // A wrapped draft spans the full width with the controls on a row below it.
        let wrapped = Frames()
        let hosting = host(ComposerInputLayout(lineHeight: 22) {
            tracked("input", in: wrapped).frame(height: 66)
            tracked("attach", in: wrapped).frame(width: 44, height: 44)
            tracked("send", in: wrapped).frame(width: 44, height: 44)
        }, width: 400)
        XCTAssertEqual(hosting.fittingSize.height, 16 + 66 + 8 + 44 + 8, accuracy: 0.5)
        XCTAssertEqual(wrapped.values["input"]?.width ?? -1, 400 - 32, accuracy: 0.5)
        XCTAssertGreaterThan(wrapped.values["send"]?.minY ?? -1, wrapped.values["input"]?.maxY ?? 0)
    }
}
