import SwiftUI
import UIKit

// In an isolated copy of the iOS target, replace SAMApp.swift with this file.
// Exercises the production UIKit editor across focus dismissal and navigation.
@main struct ComposerFocusFixture: SwiftUI.App {
    var body: some Scene { WindowGroup { FocusFixture() } }
}

private struct FocusFixture: View {
    @State private var text = "Start an agent"
    @State private var focused = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ComposerTextInput(text: $text, focused: $focused, files: nil)
                .frame(height: 100)
                .navigationDestination(for: String.self) { Text($0) }
        }
        .task { await verify() }
    }

    @MainActor private func verify() async {
        func pause() async { try? await Task.sleep(for: .milliseconds(500)) }
        func editor(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func finish(_ result: String) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("focus-result.txt")
            try! result.write(to: url, atomically: true, encoding: .utf8)
        }
        await pause()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow), let input = editor(in: window)
        else { finish("FAIL: editor missing"); return }
        input.becomeFirstResponder()
        await pause()
        guard input.isFirstResponder && focused else { finish("FAIL: editor did not focus"); return }
        focused = false
        await pause()
        guard !input.isFirstResponder else { finish("FAIL: focus dismissal retained first responder"); return }
        path.append("Agent")
        await pause()
        path.removeAll()
        await pause()
        guard !focused, let returnedInput = editor(in: window), !returnedInput.isFirstResponder
        else { finish("FAIL: project keyboard restored on return"); return }
        returnedInput.becomeFirstResponder()
        await pause()
        guard focused && returnedInput.isFirstResponder else { finish("FAIL: editor cannot refocus after return"); return }
        focused = false
        await pause()
        finish("PASS: native focus dismissal, navigation return, and explicit refocus")
    }
}
