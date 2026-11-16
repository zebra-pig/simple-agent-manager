import AppKit
import SwiftUI

// Fixture transport shape. Xcode Cloud also compiles the production view against
// the real generated UniFFI record; this isolated render needs no Rust runtime.
struct ResourcePoint: Equatable {
    let time: Int64
    let cpuCores: Double?
    let memoryBytes: Double?
    let readBytes: Double?
    let writeBytes: Double?
    let runId: String
}

@main
struct ResourceHistoryRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var points: [ResourcePoint] = []
        for minute in 0..<90 {
            let time: Int64 = 1_794_737_400_000 + Int64(minute) * 60_000
            let cpu: Double? = minute == 35 ? nil : 0.3 + abs(sin(Double(minute) / 8.0)) * 1.8
            let memory: Double = Double(450 + minute * 3) * 1_048_576.0
            let read: Double = Double(minute % 12) * 1_048_576.0
            let write: Double = Double(minute % 4) * 524_288.0
            points.append(ResourcePoint(time: time, cpuCores: cpu, memoryBytes: memory,
                                        readBytes: read, writeBytes: write,
                                        runId: minute < 60 ? "first" : "restarted"))
        }
        let sparse = [
            ResourcePoint(time: 0, cpuCores: 0, memoryBytes: nil, readBytes: 0, writeBytes: nil, runId: "a"),
            ResourcePoint(time: 180_000, cpuCores: 2, memoryBytes: nil, readBytes: 1_048_576, writeBytes: nil, runId: "a"),
            ResourcePoint(time: 240_000, cpuCores: .nan, memoryBytes: nil, readBytes: nil, writeBytes: nil, runId: "a")
        ]

        for (name, width, metric, data, collection, dark) in [
            ("cpu-narrow", 375.0, ResourceMetric.cpu, points, "complete", false),
            ("memory-wide", 1000.0, .memory, points, "complete", true),
            ("read-narrow", 375.0, .read, points, "complete", false),
            ("write-wide", 1000.0, .write, points, "complete", true),
            ("empty-narrow", 375.0, .cpu, [], "pending", false),
            ("sparse-narrow", 375.0, .cpu, sparse, "complete", false)
        ] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApplication.shared.appearance = appearance
            let view = ResourceHistoryView(points: data, collection: collection, omittedChunks: data.isEmpty ? 0 : 1,
                                           loading: false, metric: metric)
                .padding(20).frame(width: width)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let measured = renderer.cgImage else { fatalError("Chart measurement failed") }
            // ImageRenderer substitutes a warning symbol for AppKit-backed
            // controls. Snapshot a real hosting view to include the native picker.
            let size = NSSize(width: CGFloat(width), height: CGFloat(measured.height) / renderer.scale)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance
            window.backgroundColor = dark ? .black : .white
            window.contentView = host
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fatalError("Native chart bitmap allocation failed: \(name)")
            }
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Native chart render failed: \(name)")
            }
            try png.write(to: output.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
        print("Wrote six chart images (manual visual review required)")
    }
}
