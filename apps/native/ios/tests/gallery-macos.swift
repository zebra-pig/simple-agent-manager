import AppKit
import SwiftUI
import Vision
import CoreML

private final class GalleryCredentials: CredentialStore, @unchecked Sendable {
    let origin: String
    init(_ origin: String) { self.origin = origin }
    func load() -> Credentials? { Credentials(serverUrl: origin, sessionCookie: "fixture=offline") }
    func save(credentials: Credentials) {}
    func clear() {}
}

/// Runs the production gallery and real Swift -> Rust -> HTTP image path.
@main struct GalleryMacTest {
    @MainActor static func pause(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = App(store: GalleryCredentials(CommandLine.arguments[1]), baseDomain: nil)
        let original = ChatModel(app: app)
        var loaded = false
        Task { await original.core.load(projectId: "p", sessionId: "s"); loaded = true }
        while !loaded { pause(0.02) }
        let source = original.core.state()
        precondition(source.galleryDocuments.count == 3)
        let initial = source.galleryDocuments[1].fileId
        let host = NSHostingView(rootView: ChatGallery(app: app, source: source, initial: initial, originalCore: original.core)
            .frame(width: 800, height: 650).background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        func capture(_ name: String, expected: Int) throws {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            if expected == 6 {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesCPUOnly = true
                try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                precondition(text.contains("Image") && text.contains("Retry"), text)
            } else {
                // Verify the decoded pixels of the image actually installed in
                // the gallery's native zoom view. Screen captures can be tone
                // mapped by a headless Mac's HDR display profile.
                func displayedImage(_ view: NSView) -> NSImage? {
                    if let imageView = view as? NSImageView, let image = imageView.image, image.size.width > 100 { return image }
                    return view.subviews.compactMap { displayedImage($0) }.first
                }
                let cg = displayedImage(host)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                let decoded = NSBitmapImageRep(cgImage: cg)
                var pixel = [Int](repeating: 0, count: 4)
                decoded.getPixel(&pixel, atX: decoded.pixelsWide / 2, y: decoded.pixelsHigh / 2)
                precondition(pixel[0] == expected * 25 && pixel[1] == 120 && pixel[2] == 220 - expected * 20,
                             "Wrong image pixels for \(expected): \(pixel)")
            }
        }
        func arrow(_ right: Bool) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: right ? "\u{F703}" : "\u{F702}", charactersIgnoringModifiers: right ? "\u{F703}" : "\u{F702}",
                isARepeat: false, keyCode: right ? 124 : 123)!
            window.sendEvent(event)
            pause(0.25)
        }
        pause(2)
        try capture("opened", expected: 8)
        precondition(original.core.state().items == source.items, "Gallery must not prepend the transcript")
        // Traverse every image in both directions, then repeat to detect resets.
        for _ in 0..<2 {
            for _ in 0..<9 { arrow(false) }
            for index in 1...9 {
                try capture("image-\(index)", expected: index)
                if index < 9 { arrow(true) }
            }
        }
        // Drive real scroll events through the production AppKit zoom view.
        for _ in 0..<9 { arrow(false) }
        func zoomView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.allowsMagnification { return scroll }
            return view.subviews.compactMap { zoomView($0) }.first
        }
        func scroll(_ horizontal: Int32, _ vertical: Int32 = 0, phase: NSEvent.Phase = .changed, momentum: Int64 = 0) {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: vertical, wheel2: horizontal, wheel3: 0)!
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            zoomView(host)!.scrollWheel(with: NSEvent(cgEvent: event)!)
            pause(0.3)
        }
        scroll(-70, phase: .began)
        try capture("swipe-next", expected: 2)
        scroll(-70) // New page, same gesture: must not advance again.
        scroll(70, momentum: 1) // Reverse bounce: must not go back.
        try capture("swipe-momentum", expected: 2)
        scroll(0, -100, phase: .began)
        try capture("vertical-scroll", expected: 2)
        zoomView(host)!.magnification = 2
        scroll(-100, phase: .began)
        try capture("zoom-pan", expected: 2)
        // The shared gesture state survives a page's zoom view being replaced.
        let swipe = GallerySwipeNavigation()
        precondition(swipe.move(delta: -60, began: true, discrete: false, momentum: false, time: 1) == 1)
        precondition(swipe.move(delta: -90, began: false, discrete: false, momentum: false, time: 1.1) == nil)
        precondition(swipe.move(delta: 100, began: false, discrete: false, momentum: true, time: 1.2) == nil)
        precondition(swipe.move(delta: 60, began: true, discrete: false, momentum: false, time: 2) == -1)
        print("GALLERY_MAC_PAGINATION_SELECTION_NAVIGATION_PASS")
        window.orderOut(nil)
    }
}
