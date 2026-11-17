// What differs between the iOS and macOS builds of the shared views.

import SwiftUI

extension EnvironmentValues {
    /// Whether a project or chat screen hides the tab bar. Only a pushed (compact)
    /// screen should: beside other columns on iPad it would strand the other tabs.
    @Entry var hidesTabBar = true
}

extension View {
    /// Hides the tab bar on a pushed screen, unless it sits in a split view column.
    func hidesTabBarWhenPushed() -> some View {
        modifier(TabBarHiding())
    }

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

    func numberKeyboard(decimal: Bool) -> some View {
        #if os(iOS)
        keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }

    /// Messages-style: dragging the content down pulls the keyboard away with
    /// the finger (the composer, and its profile selector, follow it).
    func interactiveKeyboardDismiss() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
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

private struct TabBarHiding: ViewModifier {
    @Environment(\.hidesTabBar) private var hides

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar(hides ? .hidden : .automatic, for: .tabBar)
        #else
        content
        #endif
    }
}
