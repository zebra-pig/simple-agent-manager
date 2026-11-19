import SwiftUI

/// Which sections of the transcript's rows the reader opened, by row.
///
/// Transcript rows are recycled as they scroll. Kept in the row's own state,
/// an open section would close when its row scrolls away, or reappear open in
/// another row that reuses the cell. Kept here, a row is the same height
/// whenever it is shown, which keeps its measured height valid.
@MainActor @Observable final class RowDisclosures {
    private var open: Set<String> = []

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.open.contains(key) },
                set: { expanded in
                    if expanded { self.open.insert(key) } else { self.open.remove(key) }
                })
    }
}

extension EnvironmentValues {
    /// Where the rows of a transcript keep their open sections.
    @Entry var rowDisclosures: RowDisclosures? = nil
    /// The transcript row a view is in.
    @Entry var disclosureRow: String = ""
}

/// A disclosure group whose state belongs to its transcript row, when it is in
/// one, and to the view otherwise.
struct RowDisclosureGroup<Label: View, Content: View>: View {
    let key: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @Environment(\.rowDisclosures) private var disclosures
    @Environment(\.disclosureRow) private var row
    @State private var expanded = false

    init(key: String, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        self.key = key
        self.content = content
        self.label = label
    }

    var body: some View {
        DisclosureGroup(isExpanded: disclosures?.binding(row + "/" + key) ?? $expanded, content: content, label: label)
    }
}

extension RowDisclosureGroup where Label == Text {
    init(_ title: LocalizedStringKey, key: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(key: key, content: content) { Text(title) }
    }
}
