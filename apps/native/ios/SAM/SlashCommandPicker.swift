import SwiftUI

/// A separate glass island keeps commands readable above the editor while
/// preserving the editor's identity and keyboard focus.
struct SlashCommandPicker: View {
    let commands: [SlashCommand]
    let selected: String?
    let select: (SlashCommand) -> Void
    let dismiss: () -> Void
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 260
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Commands", systemImage: "slash.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss commands", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            Divider().padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(commands, id: \.name) { command in
                            Button { select(command) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: "/" + command.name).font(.body.monospaced().bold())
                                    if !command.description.isEmpty {
                                        Text(verbatim: command.description)
                                            .font(.subheadline).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(selected == command.name ? Color.primary.opacity(0.08) : .clear,
                                            in: .rect(cornerRadius: 12))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Insert into the message. Send when ready.")
                            .accessibilityAddTraits(selected == command.name ? .isSelected : [])
                            .id(command.name)
                        }
                    }
                    .padding(8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, maximumHeight))
                .onChange(of: selected) { _, name in
                    if let name { proxy.scrollTo(name, anchor: .center) }
                }
            }
        }
        .glass(in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }
}
