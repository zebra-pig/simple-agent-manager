// Liquid Glass (iOS/macOS 26) for the app's own floating controls. System bars,
// toolbars and sheets get glass from the SDK; these helpers cover custom pieces
// and fall back to materials on iOS 17-18 / macOS 14-15.

import SwiftUI

extension View {
    /// A glass surface in `shape`, optionally tinted; `interactive` for controls
    /// that react to touch (the composer island).
    @ViewBuilder
    func glass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .background(tint?.opacity(0.25) ?? .clear, in: shape)
        }
    }

    /// The prominent (filled) glass button style, `.borderedProminent` before 26.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The regular glass button style, `.bordered` before 26.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Groups neighbouring glass shapes so they blend and morph together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
