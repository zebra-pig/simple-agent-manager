// What differs between the iOS and macOS builds of the shared views.

import SwiftUI

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// macOS sizes a sheet to its content, which leaves Forms and Lists a sliver.
    func macSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 480, minHeight: 520)
        #else
        self
        #endif
    }
}
