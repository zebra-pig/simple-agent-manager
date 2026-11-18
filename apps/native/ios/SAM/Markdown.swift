import SwiftUI

struct MarkdownView: View {
    let blocks: [Block]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(spans): SelectableText(spans: spans)
                case let .heading(level, spans):
                    SelectableText(spans: spans, style: level == 1 ? .title2 : level == 2 ? .title3 : .headline).padding(.top, 6)
                case let .listItem(depth, marker, spans):
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: markerText(marker)).frame(minWidth: 20, alignment: .leading).foregroundStyle(.secondary)
                        SelectableText(spans: spans)
                    }.padding(.leading, CGFloat(depth) * 20)
                case let .quote(spans):
                    HStack { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 3); SelectableText(spans: spans, secondary: true) }.fixedSize(horizontal: false, vertical: true)
                case let .code(language, code): CodeView(code: code, language: language)
                case let .table(header, rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                            tableRow(header, heading: true)
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in tableRow(row, heading: false) }
                        }.padding(12)
                    }.background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                case .rule: Divider().padding(.vertical, 6)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(_ row: TableRow, heading: Bool) -> some View {
        GridRow {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                Text(styled(cell, baseFont: heading ? .body.weight(.semibold) : .body)).frame(minWidth: 48, maxWidth: 260, alignment: .leading).textSelection(.enabled)
            }
        }
    }

    private func markerText(_ marker: ListMarker) -> String {
        switch marker {
        case .bullet: return "•"
        case let .number(value): return "\(value)."
        case let .task(done): return done ? "☑" : "☐"
        case .continuation: return ""
        }
    }

    private func styled(_ spans: [Span], baseFont: Font = .body) -> AttributedString {
        spans.reduce(into: AttributedString()) { result, span in
            var text = AttributedString(span.text)
            var font: Font = span.code ? .system(.body, design: .monospaced) : baseFont
            if span.bold { font = font.weight(.semibold) }
            if span.italic { font = font.italic() }
            text.font = font
            if span.strike { text.strikethroughStyle = .single }
            if span.code { text.backgroundColor = Color.secondary.opacity(0.1) }
            if let link = span.link, let url = URL(string: link) { text.link = url }
            result.append(text)
        }
    }
}

struct CodeView: View {
    let code: String
    let language: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty { Text(verbatim: language).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) { SelectableText(verbatim: code, style: .code).fixedSize(horizontal: true, vertical: false) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Keep reasoning readable without exposing inline Markdown delimiters.
struct ThinkingView: View {
    let text: String
    var style: SelectableText.Style = .callout

    var body: some View {
        DisclosureGroup("Thinking") {
            SelectableText(inlineMarkdown: text, style: style, secondary: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
