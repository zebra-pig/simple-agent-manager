import SwiftUI

/// Uses the actual production composer in both of its layouts, without a server.
@main struct PickerFixture: SwiftUI.App {
    var body: some Scene { WindowGroup { Fixture() } }
}

private struct Fixture: View {
    @State private var text = ""
    @State private var picked = ""
    @State private var project = false
    private var files: ComposerFiles {
        ComposerFiles(items: [], add: { name, _, size, source in
            picked = source.read()?.count == Int(size) ? name : "Unreadable selection"
        }, remove: { _ in })
    }
    var body: some View {
        NavigationStack {
            List {
                Toggle("New task layout", isOn: $project)
                Text(picked).accessibilityIdentifier("picked-file")
            }
            .navigationTitle("Composer check")
            .safeAreaInset(edge: .bottom) {
                if project {
                    Composer(placeholder: "Message", text: $text, busy: false, files: files, send: {}) {
                        Text("Agent profile")
                    }
                } else {
                    Composer(placeholder: "Message", text: $text, busy: false, files: files, send: {})
                }
            }
        }
        .task {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? "picker check".write(to: directory.appendingPathComponent("picker-check.txt"), atomically: true, encoding: .utf8)
        }
    }
}
