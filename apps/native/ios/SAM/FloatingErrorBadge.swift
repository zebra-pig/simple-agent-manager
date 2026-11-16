import SwiftUI

struct FloatingErrorBadge: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 12)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss error", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error")
    }
}
