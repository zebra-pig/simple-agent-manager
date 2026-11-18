import SwiftUI

/// Read-only text the reader can select a range of, not just copy whole.
///
/// SwiftUI's `textSelection(.enabled)` selects text in place on macOS, but on
/// iOS it only offers a "Copy" of the entire string. On iOS this wraps a
/// non-editable, non-scrolling `UITextView`, which provides real selection with
/// handles, the loupe, and the system edit menu. macOS keeps SwiftUI `Text`.
struct SelectableText: View {
    enum Style { case body, callout, caption, footnote, headline, title2, title3, code }

    let runs: [SelectableRun]
    var style: Style = .body
    var secondary = false

    init(verbatim text: String, style: Style = .body, secondary: Bool = false) {
        self.runs = [SelectableRun(text: text)]
        self.style = style
        self.secondary = secondary
    }

    init(spans: [Span], style: Style = .body, secondary: Bool = false) {
        self.runs = spans.map {
            SelectableRun(text: $0.text, bold: $0.bold, italic: $0.italic, code: $0.code,
                          strike: $0.strike, link: $0.link.flatMap(URL.init(string:)))
        }
        self.style = style
        self.secondary = secondary
    }

    /// Inline Markdown (emphasis, code and links), without block structure.
    init(inlineMarkdown text: String, style: Style = .body, secondary: Bool = false) {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        self.runs = parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return SelectableRun(text: String(parsed[run.range].characters),
                                 bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                 code: intent.contains(.code), strike: intent.contains(.strikethrough), link: run.link)
        }
        self.style = style
        self.secondary = secondary
    }

    var body: some View {
        #if os(iOS)
        SelectableTextView(runs: runs, style: style, secondary: secondary)
        #else
        Text(swiftUIText).foregroundStyle(secondary ? .secondary : .primary).textSelection(.enabled)
        #endif
    }

    #if os(macOS)
    private var swiftUIText: AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var text = AttributedString(run.text)
            var font: Font = run.code || style == .code ? .system(style.font, design: .monospaced) : .system(style.font)
            if style == .headline || style == .title2 || style == .title3 || run.bold { font = font.weight(.semibold) }
            if run.italic { font = font.italic() }
            text.font = font
            if run.strike { text.strikethroughStyle = .single }
            if run.code && style != .code { text.backgroundColor = Color.secondary.opacity(0.1) }
            if let link = run.link { text.link = link }
            result.append(text)
        }
    }
    #endif
}

extension EnvironmentValues {
    /// Adds "Comment" to the edit menu of selected text, for the message it is in.
    @Entry var selectionComment: (() -> Void)? = nil
}

struct SelectableRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: URL?
}

private extension SelectableText.Style {
    var font: Font.TextStyle {
        switch self {
        case .body: .body
        case .callout, .code: .callout
        case .caption: .caption
        case .footnote: .footnote
        case .headline: .headline
        case .title2: .title2
        case .title3: .title3
        }
    }
}

#if os(iOS)
import UIKit

private struct SelectableTextView: UIViewRepresentable {
    let runs: [SelectableRun]
    let style: SelectableText.Style
    let secondary: Bool
    @Environment(\.selectionComment) private var comment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ReadOnlyTextView {
        let view = ReadOnlyTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ReadOnlyTextView, context: Context) {
        context.coordinator.comment = comment
        context.coordinator.openURL = openURL
        let text = attributed(for: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
        // Reassigning identical text would clear the reader's selection
        // whenever the row re-renders, for example on a poll.
        if !view.attributedText.isEqual(to: text) {
            view.attributedText = text
            view.accessibilityLabel = text.string
            view.measured.removeAll()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReadOnlyTextView, context: Context) -> CGSize? {
        uiView.size(fitting: proposal.width)
    }

    private func attributed(for traits: UITraitCollection) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: style.textStyle, compatibleWith: traits)
        let result = NSMutableAttributedString()
        for run in runs {
            var font = base
            if style == .code || run.code {
                let weight: UIFont.Weight = run.bold || style.semibold ? .semibold : .regular
                font = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
            }
            var traitsToAdd: UIFontDescriptor.SymbolicTraits = []
            if (run.bold || style.semibold) && !(style == .code || run.code) { traitsToAdd.insert(.traitBold) }
            if run.italic { traitsToAdd.insert(.traitItalic) }
            if !traitsToAdd.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traitsToAdd)) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: secondary ? UIColor.secondaryLabel : UIColor.label,
            ]
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.code && style != .code { attributes[.backgroundColor] = UIColor.secondaryLabel.withAlphaComponent(0.1) }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var comment: (() -> Void)?
        var openURL: OpenURLAction?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let comment else { return nil }
            let action = UIAction(title: String(localized: "Comment"), image: UIImage(systemName: "text.bubble")) { _ in comment() }
            // First, so it is not hidden behind the menu's overflow chevron.
            return UIMenu(children: [action] + suggestedActions)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            // Links go through SwiftUI's openURL, like the rest of the app.
            guard case let .link(url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }
    }
}

private extension SelectableText.Style {
    var textStyle: UIFont.TextStyle {
        switch self {
        case .body: .body
        case .callout, .code: .callout
        case .caption: .caption1
        case .footnote: .footnote
        case .headline: .headline
        case .title2: .title2
        case .title3: .title3
        }
    }
    var semibold: Bool { self == .headline || self == .title2 || self == .title3 }
}

final class ReadOnlyTextView: UITextView {
    fileprivate var measured: [CGFloat: CGSize] = [:]

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        // Dragging text out of a chat row would fight the transcript's scrolling.
        textDragInteraction?.isEnabled = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        adjustsFontForContentSizeCategory = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // Read as plain text by VoiceOver; the text stays selectable by touch.
    override var accessibilityTraits: UIAccessibilityTraits {
        get { .staticText }
        set {}
    }
    override var accessibilityValue: String? {
        get { nil }
        set {}
    }

    /// The text's own width up to `width`, so a short message hugs its bubble.
    fileprivate func size(fitting width: CGFloat?) -> CGSize {
        let limit = width.map { $0.isFinite ? max($0, 1) : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        if let size = measured[limit] { return size }
        let bounds = attributedText.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let fitted = sizeThatFits(CGSize(width: limit, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(ceil(bounds.width), limit), height: ceil(fitted.height))
        measured[limit] = size
        return size
    }
}
#endif
