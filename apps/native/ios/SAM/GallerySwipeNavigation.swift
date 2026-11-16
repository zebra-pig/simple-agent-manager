import Foundation

/// Shared across image pages so replacing the zoom view cannot consume the
/// remainder of the same trackpad swipe as a second navigation gesture.
@MainActor final class GallerySwipeNavigation {
    private var distance: CGFloat = 0
    private var consumed = false
    private var lastTime: TimeInterval = 0

    func begin() { distance = 0; consumed = false }

    func move(delta: CGFloat, began: Bool, discrete: Bool, momentum: Bool, time: TimeInterval) -> Int? {
        guard !momentum else { return nil }
        if began || (discrete && time - lastTime > 0.3) {
            begin()
        }
        lastTime = time
        guard !consumed else { return nil }
        distance += delta
        guard abs(distance) >= 50 else { return nil }
        consumed = true
        return distance < 0 ? 1 : -1
    }
}
