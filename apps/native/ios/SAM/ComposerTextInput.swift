import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

/// A plain text editor that routes explicitly pasted files through attachment
/// intake. Clipboard contents are read only when the user invokes Paste.
struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let files: ComposerFiles?
    var focusControl: FocusControl? = nil
    var commandKey: ((String) -> Bool)?

    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.isEditable = true
        view.isSelectable = true
        view.allowsEditingTextAttributes = false
        focusControl?.view = view
        return view
    }

    func updateUIView(_ view: AttachmentTextView, context: Context) {
        context.coordinator.parent = self
        focusControl?.view = view
        context.coordinator.updateInteraction(view, enabled: context.environment.isEnabled)
        view.commandKey = commandKey
        view.attach = files.map { files in { AttachmentIntake.add(providers: $0, to: files) } }
        // Do not reset the selection or an in-progress IME composition.
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AttachmentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(line, height), line * 6))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The send action dismisses its own editor before navigation. UIKit must
    /// not query SwiftUI's responder graph from inside updateUIView (iPad hang).
    @MainActor final class FocusControl {
        fileprivate weak var view: UITextView?
        func dismiss() { view?.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        private var editable = true
        private var interactionScheduled = false
        init(_ parent: ComposerTextInput) {
            self.parent = parent
        }

        /// Changing editability can resign the responder too, so do it after
        /// SwiftUI's graph update rather than re-entering that graph from UIKit.
        func updateInteraction(_ view: UITextView, enabled: Bool) {
            editable = enabled
            guard !interactionScheduled, view.isEditable != enabled else { return }
            interactionScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.interactionScheduled = false
                if view.isEditable != self.editable { view.isEditable = self.editable }
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil, parent.commandKey?("select") == true { return false }
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

final class AttachmentTextView: UITextView {
    var commandKey: ((String) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        guard commandKey != nil else { return super.keyCommands }
        return (super.keyCommands ?? []) + [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, "\t", "\r"].map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pickCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func pickCommand(_ command: UIKeyCommand) {
        let action = switch command.input {
        case UIKeyCommand.inputUpArrow: "previous"
        case UIKeyCommand.inputDownArrow: "next"
        case UIKeyCommand.inputEscape: "dismiss"
        default: "select"
        }
        _ = commandKey?(action)
    }

    var attach: (([NSItemProvider]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), attach != nil {
            let board = UIPasteboard.general
            // These queries inspect type availability, not clipboard contents.
            if board.hasImages || board.types.contains(where: { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .fileURL)
                    || (type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url))
            }) { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        let attachments = providers.filter(AttachmentIntake.isFile)
        guard !attachments.isEmpty, let attach else {
            super.paste(sender)
            return
        }
        attach(attachments)
        // Preserve text in a mixed clipboard payload at the current selection.
        for provider in providers where !AttachmentIntake.isFile(provider) && provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] value, _ in
                guard let value else { return }
                DispatchQueue.main.async { self?.insertText(value) }
            }
        }
    }
}
#endif
