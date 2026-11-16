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

        func capture(_ name: String) throws -> String {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            for (stage, devices) in try request.supportedComputeStageDevices {
                for device in devices {
                    if case .cpu = device { request.setComputeDevice(device, for: stage); break }
                }
            }
            try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").replacingOccurrences(of: "of g", with: "of 9")
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
        var text = try capture("opened")
        print("OPENED:", text)
        precondition(text.contains("8 of 9"), "Tapped image must survive earlier pages: \(text)")
        precondition(original.core.state().items == source.items, "Gallery must not prepend the transcript")
        // Traverse every image in both directions, then repeat to detect resets.
        for _ in 0..<2 {
            for _ in 0..<9 { arrow(false) }
            for index in 1...9 {
                text = try capture("image-\(index)")
                precondition(text.contains("\(index) of 9"), "Navigation jumped: \(text)")
                if index == 6 { precondition(text.contains("Image unavailable"), text) }
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
        text = try capture("swipe-next"); precondition(text.contains("2 of 9"), text)
        scroll(-70) // New page, same gesture: must not advance again.
        scroll(70, momentum: 1) // Reverse bounce: must not go back.
        text = try capture("swipe-momentum"); precondition(text.contains("2 of 9"), text)
        scroll(0, -100, phase: .began)
        text = try capture("vertical-scroll"); precondition(text.contains("2 of 9"), text)
        zoomView(host)!.magnification = 2
        scroll(-100, phase: .began)
        text = try capture("zoom-pan"); precondition(text.contains("2 of 9"), text)
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
